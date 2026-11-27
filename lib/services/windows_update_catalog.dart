import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

enum WindowsReleaseSource { release, workflowArtifact }

class WindowsVersionRecord {
  const WindowsVersionRecord({
    required this.tag,
    required this.isPrerelease,
    required this.source,
    required this.actionUri,
    this.downloadUri,
    this.sha256,
    this.checksumUri,
    this.size,
  });

  final String tag;
  final bool isPrerelease;
  final WindowsReleaseSource source;
  final Uri actionUri;
  final Uri? downloadUri;
  final String? sha256;
  final Uri? checksumUri;
  final int? size;

  bool get available =>
      downloadUri != null && (sha256 != null || checksumUri != null);
}

class WindowsUpdateCatalog {
  WindowsUpdateCatalog({http.Client? client, Uri? apiBase})
    : _client = client ?? http.Client(),
      _ownsClient = client == null,
      _apiBase = apiBase ?? Uri.https('api.github.com');

  static const _official = 'nanguaguag/yibubang';
  static const _fork = 'JMK712/yibubang';
  static final _stableTag = RegExp(r'^v?\d+(?:\.\d+){1,2}$');
  static final _previewTag = RegExp(r'^dev-v\d+\.\d+\.\d+-\d{8}\.\d+$');
  static final _buildTag = RegExp(r'^dev-build-v\d+\.\d+\.\d+-(\d+)\.(\d+)$');
  static final _hash = RegExp(r'^[0-9a-f]{64}$');
  static const _timeout = Duration(seconds: 8);

  final http.Client _client;
  final bool _ownsClient;
  final Uri _apiBase;

  void close() {
    if (_ownsClient) _client.close();
  }

  Future<List<WindowsVersionRecord>> fetch({bool dev = false}) async {
    final responses = await Future.wait([
      _getReleases(_official),
      if (dev)
        _getReleases(_fork).catchError((Object _) => <WindowsVersionRecord>[]),
    ]);
    final results = [...responses.expand((records) => records)];
    if (dev) {
      final published = <String>{
        for (final record in responses.last)
          if (record.available && _buildTag.hasMatch(record.tag))
            _buildTag.firstMatch(record.tag)!.group(1)!,
      };
      results.addAll(await _historicalBuilds(published));
    }
    return results;
  }

  Future<List<WindowsVersionRecord>> _getReleases(String repository) async {
    final data = await _getJson('/repos/$repository/releases?per_page=100');
    if (data is! List) throw const FormatException('GitHub 版本列表无效。');
    return [
      for (final release in data.whereType<Map<String, dynamic>>())
        if (_parseRelease(repository, release) case final record?) record,
    ];
  }

  WindowsVersionRecord? _parseRelease(
    String repository,
    Map<String, dynamic> release,
  ) {
    final tag = release['tag_name'];
    if (tag is! String || release['draft'] == true) return null;
    final prerelease = release['prerelease'] == true;
    final build = _buildTag.firstMatch(tag);
    if (repository == _official
        ? prerelease || !_stableTag.hasMatch(tag)
        : !prerelease || (build == null && !_previewTag.hasMatch(tag))) {
      return null;
    }

    final windowsName = 'yibubang-$tag-windows-x64.zip';
    final assets = release['assets'];
    if (assets is! List) return null;
    final asset = assets
        .whereType<Map<String, dynamic>>()
        .where((asset) => asset['name'] == windowsName)
        .firstOrNull;
    final download = _assetUri(repository, tag, windowsName, asset);
    if (download == null) return null;
    final digest = asset?['digest'];
    final hash = digest is String && digest.startsWith('sha256:')
        ? digest.substring('sha256:'.length).toLowerCase()
        : '';
    final checksumName = '$windowsName.sha256';
    final sidecar = assets
        .whereType<Map<String, dynamic>>()
        .where((asset) => asset['name'] == checksumName)
        .firstOrNull;
    final size = asset?['size'];
    return WindowsVersionRecord(
      tag: tag,
      isPrerelease: prerelease,
      source: build == null
          ? WindowsReleaseSource.release
          : WindowsReleaseSource.workflowArtifact,
      actionUri: build == null
          ? Uri.https('github.com', '/$repository/releases/tag/$tag')
          : Uri.https(
              'github.com',
              '/$repository/actions/runs/${build.group(1)}/attempts/${build.group(2)}',
            ),
      downloadUri: download,
      sha256: _hash.hasMatch(hash) ? hash : null,
      checksumUri: _assetUri(repository, tag, checksumName, sidecar),
      size: size is int && size > 0 ? size : null,
    );
  }

  /// Older run-only artifacts are browser links. Public release assets can
  /// be installed directly without a GitHub login or an access token.
  Future<List<WindowsVersionRecord>> _historicalBuilds(
    Set<String> published,
  ) async {
    try {
      final data = await _getJson(
        '/repos/$_fork/actions/workflows/windows.yml/runs?branch=dev&status=success&per_page=8',
      );
      final runs = data is Map ? data['workflow_runs'] : null;
      if (runs is! List) return [];
      final versions = await Future.wait([
        for (final run in runs.whereType<Map<String, dynamic>>())
          if (run['head_branch'] == 'dev' &&
              run['conclusion'] == 'success' &&
              run['id'] is int &&
              !published.contains(run['id'].toString()))
            _historicalBuild(run['id'] as int),
      ]);
      return versions.whereType<WindowsVersionRecord>().toList();
    } catch (_) {
      return [];
    }
  }

  Future<WindowsVersionRecord?> _historicalBuild(int id) async {
    try {
      final data = await _getJson('/repos/$_fork/actions/runs/$id/artifacts');
      final artifacts = data is Map ? data['artifacts'] : null;
      const windowsArtifacts = {
        'dev-windows-catalog',
        'yibubang-windows-release',
      };
      if (artifacts is! List ||
          !artifacts.whereType<Map>().any(
            (artifact) =>
                artifact['expired'] == false &&
                windowsArtifacts.contains(artifact['name']),
          )) {
        return null;
      }
      return WindowsVersionRecord(
        tag: 'Actions #$id',
        isPrerelease: true,
        source: WindowsReleaseSource.workflowArtifact,
        actionUri: Uri.https('github.com', '/$_fork/actions/runs/$id'),
      );
    } catch (_) {
      return null;
    }
  }

  Future<String> resolveSha256(WindowsVersionRecord record) async {
    if (record.sha256 case final digest?) return digest;
    final uri = record.checksumUri;
    if (uri != null) {
      final response = await _client.get(uri).timeout(_timeout);
      final body = response.body.trim();
      if (response.statusCode == 200 && body.length <= 512) {
        final name = RegExp.escape(record.downloadUri!.pathSegments.last);
        final digest = RegExp(
          '^([0-9a-fA-F]{64})(?:[ \\t]+\\*?$name)?\$',
        ).firstMatch(body)?.group(1);
        if (digest != null) return digest.toLowerCase();
      }
    }
    throw const FormatException('找不到此安装包的有效 SHA-256。');
  }

  Future<Object?> _getJson(String path) async {
    final response = await _client
        .get(
          _apiBase.resolve(path),
          headers: const {
            'Accept': 'application/vnd.github+json',
            'User-Agent': 'yibubang-windows-updater',
          },
        )
        .timeout(_timeout);
    if (response.statusCode != 200) {
      throw HttpException('GitHub HTTP ${response.statusCode}');
    }
    return jsonDecode(utf8.decode(response.bodyBytes));
  }

  Uri? _assetUri(String repository, String tag, String name, Map? asset) {
    final expected = Uri.https(
      'github.com',
      '/$repository/releases/download/$tag/$name',
    );
    return asset?['browser_download_url'] == expected.toString()
        ? expected
        : null;
  }
}
