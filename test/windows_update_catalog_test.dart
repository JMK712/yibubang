import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:yibubang/services/windows_update_catalog.dart';

const _official = 'nanguaguag/yibubang';
const _fork = 'JMK712/yibubang';
String _zip(String tag) => 'yibubang-$tag-windows-x64.zip';
String _asset(String repo, String tag, String name) =>
    'https://github.com/$repo/releases/download/$tag/$name';

Map<String, Object> _release(
  String repo,
  String tag, {
  bool dev = false,
  bool hash = true,
}) {
  final zip = _zip(tag);
  return {
    'tag_name': tag,
    'prerelease': dev,
    'assets': [
      {
        'name': zip,
        'browser_download_url': _asset(repo, tag, zip),
        'size': 1234,
        if (hash) 'digest': 'sha256:${'a' * 64}',
      },
      if (!hash)
        {
          'name': '$zip.sha256',
          'browser_download_url': _asset(repo, tag, '$zip.sha256'),
        },
    ],
  };
}

http.Response _json(Object value) => http.Response(
  jsonEncode(value),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

void main() {
  test('only official Windows ZIP releases are shown by default', () async {
    final wrongPath = _release(_official, 'v2.0.0');
    (wrongPath['assets'] as List).first['browser_download_url'] = _asset(
      _official,
      'v9.0.0',
      _zip('v2.0.0'),
    );
    final catalog = WindowsUpdateCatalog(
      client: MockClient((request) async {
        expect(request.url.path, '/repos/$_official/releases');
        return _json([
          _release(_official, 'v2.2.5'),
          _release(_official, 'v2.2.4'),
          _release(_official, 'v2.3.0', dev: true),
          wrongPath,
        ]);
      }),
    );
    final versions = await catalog.fetch();
    expect(versions.map((item) => item.tag), ['v2.2.5', 'v2.2.4']);
    expect(versions.first.sha256, 'a' * 64);
    expect(versions.first.size, 1234);
  });

  test(
    'Dev mode lists fork previews and downloadable Actions releases',
    () async {
      const published = 'dev-build-v2.2.5-10.1';
      final catalog = WindowsUpdateCatalog(
        client: MockClient((request) async {
          return switch (request.url.path) {
            '/repos/$_official/releases' => _json([
              _release(_official, 'v2.2.5'),
            ]),
            '/repos/$_fork/releases' => _json([
              _release(_fork, published, dev: true),
              _release(_fork, 'dev-v2.2.5-20261126.3', dev: true),
            ]),
            '/repos/$_fork/actions/workflows/windows.yml/runs' => _json({
              'workflow_runs': [
                {'id': 10, 'head_branch': 'dev', 'conclusion': 'success'},
                {'id': 9, 'head_branch': 'dev', 'conclusion': 'success'},
              ],
            }),
            '/repos/$_fork/actions/runs/9/artifacts' => _json({
              'artifacts': [
                {'name': 'yibubang-windows-release', 'expired': false},
              ],
            }),
            _ => throw StateError('Unexpected request: ${request.url}'),
          };
        }),
      );
      final versions = await catalog.fetch(dev: true);
      expect(versions.map((item) => item.tag), [
        'v2.2.5',
        published,
        'dev-v2.2.5-20261126.3',
        'Actions #9',
      ]);
      expect(versions[1].source, WindowsReleaseSource.workflowArtifact);
      expect(versions[1].available, isTrue);
      expect(versions[1].actionUri.path, '/$_fork/actions/runs/10/attempts/1');
      expect(versions.last.available, isFalse);
    },
  );

  test('checksum sidecars must identify the selected ZIP', () async {
    const tag = 'v2.2.5';
    var checksum = "${'b' * 64}  ${_zip(tag)}\n";
    final catalog = WindowsUpdateCatalog(
      client: MockClient((request) async {
        if (request.url.path.endsWith('.zip.sha256')) {
          return http.Response(checksum, 200);
        }
        return _json([_release(_official, tag, hash: false)]);
      }),
    );
    final record = (await catalog.fetch()).single;
    expect(await catalog.resolveSha256(record), 'b' * 64);
    checksum = "${'b' * 64}  other-release.zip";
    await expectLater(catalog.resolveSha256(record), throwsFormatException);
  });
}
