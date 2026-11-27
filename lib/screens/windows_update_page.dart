import 'dart:ffi';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../common/platform_adaptive.dart';
import '../common/version_utils.dart';
import '../services/windows_update_catalog.dart';
import '../services/windows_update_installer.dart';

class WindowsUpdatePage extends StatefulWidget {
  const WindowsUpdatePage({super.key});

  static bool get isSupported =>
      Platform.isWindows && Abi.current() == Abi.windowsX64;

  static Future<void> open(BuildContext context) async {
    await pushAdaptiveModalPage(
      context,
      desktopConstraints: const BoxConstraints(maxWidth: 640, maxHeight: 720),
      builder: (_) => const WindowsUpdatePage(),
    );
  }

  @override
  State<WindowsUpdatePage> createState() => _WindowsUpdatePageState();
}

class _WindowsUpdatePageState extends State<WindowsUpdatePage> {
  static const _devKey = 'windows_update_show_dev';
  static const _buildTag = String.fromEnvironment(
    'YIBUBANG_WINDOWS_RELEASE_TAG',
  );
  final _catalog = WindowsUpdateCatalog();

  List<WindowsVersionRecord> _versions = [];
  String _installedVersion = '';
  String? _loadError;
  String? _installStatus;
  double? _progress;
  bool _loading = true;
  bool _showDev = false;
  bool _installing = false;
  int _loadRequest = 0;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  @override
  void dispose() {
    _catalog.close();
    super.dispose();
  }

  Future<void> _initialize() async {
    final prefs = await SharedPreferences.getInstance();
    final package = await PackageInfo.fromPlatform();
    if (!mounted) return;
    _installedVersion = package.version;
    _showDev = prefs.getBool(_devKey) ?? false;
    await _load();
  }

  Future<void> _load() async {
    final request = ++_loadRequest;
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final versions = await _catalog.fetch(dev: _showDev);
      if (!mounted || request != _loadRequest) return;
      setState(() => _versions = versions);
    } catch (error) {
      debugPrint('[windows-update] 检查版本失败: $error');
      if (!mounted || request != _loadRequest) return;
      setState(() => _loadError = '无法获取 Windows 版本，请刷新重试。');
    } finally {
      if (mounted && request == _loadRequest) setState(() => _loading = false);
    }
  }

  Future<void> _toggleDev() async {
    setState(() {
      _showDev = !_showDev;
      _versions = _versions.where((version) => !version.isPrerelease).toList();
    });
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    await prefs.setBool(_devKey, _showDev);
    if (mounted) await _load();
  }

  bool _isInstalled(WindowsVersionRecord version) => _buildTag.isNotEmpty
      ? version.tag == _buildTag
      : !version.isPrerelease &&
            VersionUtils.cleanVersion(version.tag) == _installedVersion;

  WindowsVersionRecord? get _latestStable {
    WindowsVersionRecord? latest;
    for (final version in _versions) {
      if (!version.available || version.isPrerelease) continue;
      if (latest == null ||
          VersionUtils.hasNewerVersion(version.tag, latest.tag)) {
        latest = version;
      }
    }
    return latest;
  }

  Future<void> _updateLatest() async {
    final latest = _latestStable;
    if (latest != null &&
        VersionUtils.hasNewerVersion(latest.tag, _installedVersion)) {
      await _install(latest);
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(latest == null ? '暂时没有可校验的正式包。' : '当前已是最新正式版本。')),
    );
  }

  Future<void> _install(WindowsVersionRecord version) async {
    final uri = version.downloadUri;
    if (uri == null || !version.available || _installing) return;
    final older =
        !version.isPrerelease &&
        VersionUtils.compareVersions(version.tag, _installedVersion) < 0;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(older ? '切换到较早版本？' : '安装 ${version.tag}？'),
        content: Text(
          older ? '更早的版本可能无法读取新版的数据格式。安装后会重启应用。' : '下载并校验通过后，应用会自动重启。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('下载安装'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() {
      _installing = true;
      _installStatus = '获取 SHA-256 校验值…';
      _progress = null;
    });
    int? lastPercent;
    try {
      final sha256 = await _catalog.resolveSha256(version);
      await WindowsUpdateInstaller().install(
        uri,
        sha256: sha256,
        expectedSize: version.size,
        onProgress: (received, total) {
          if (!mounted) return;
          final percent = total == null || total == 0
              ? null
              : (received * 100 ~/ total).clamp(0, 100);
          if (percent == lastPercent && received != 0) return;
          lastPercent = percent;
          setState(() {
            _progress = percent == null || percent == 100
                ? null
                : percent / 100;
            _installStatus = percent == 100
                ? '正在校验并准备安装…'
                : percent == null
                ? '正在下载…'
                : '正在下载 $percent%';
          });
        },
      );
      if (mounted) setState(() => _installStatus = '正在重启…');
      exit(0);
    } catch (error) {
      debugPrint('[windows-update] 安装失败: $error');
      if (!mounted) return;
      setState(() {
        _installing = false;
        _installStatus = '更新未安装。$error';
        _progress = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final shown = _versions
        .where((version) => _showDev || !version.isPrerelease)
        .toList();
    final currentTag = _buildTag.isEmpty ? _installedVersion : _buildTag;
    return PopScope(
      canPop: !_installing,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Windows 更新'),
          actions: [
            IconButton(
              tooltip: '刷新版本',
              onPressed: _loading || _installing ? null : _load,
              icon: const Icon(Icons.refresh),
            ),
            PopupMenuButton<bool>(
              tooltip: '更新选项',
              enabled: !_loading && !_installing,
              onSelected: (_) => _toggleDev(),
              itemBuilder: (_) => [
                CheckedPopupMenuItem(
                  value: true,
                  checked: _showDev,
                  child: const Text('显示 Dev 版本'),
                ),
              ],
            ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
          children: [
            if (currentTag.isNotEmpty) Text('当前版本  $currentTag'),
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.icon(
                onPressed: _loading || _installing || _loadError != null
                    ? null
                    : _updateLatest,
                icon: const Icon(Icons.system_update_alt),
                label: const Text('自动更新至最新正式版'),
              ),
            ),
            if (_loading || _installing) ...[
              const SizedBox(height: 12),
              LinearProgressIndicator(value: _progress),
            ],
            if (_installStatus != null) ...[
              const SizedBox(height: 8),
              Text(
                _installStatus!,
                maxLines: 5,
                overflow: TextOverflow.ellipsis,
              ),
            ],
            if (_loadError != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(_loadError!),
              ),
            if (shown.isNotEmpty) ...[
              const SizedBox(height: 18),
              Text('切换版本', style: Theme.of(context).textTheme.titleMedium),
              for (final version in shown) _versionTile(version),
            ] else if (!_loading && _loadError == null)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text('暂无可用的 Windows 版本。'),
              ),
          ],
        ),
      ),
    );
  }

  Widget _versionTile(WindowsVersionRecord version) {
    final installed = _isInstalled(version);
    final workflow = version.source == WindowsReleaseSource.workflowArtifact;
    final description = installed
        ? '当前版本'
        : !version.available
        ? (workflow ? '在 GitHub Actions 查看此构建' : '缺少可验证的安装包')
        : workflow
        ? 'GitHub Actions 构建'
        : version.isPrerelease
        ? 'Dev 预览版'
        : '正式版';
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(version.tag),
      subtitle: Text(description),
      trailing: version.available
          ? TextButton(
              onPressed: installed || _installing || _loading
                  ? null
                  : () => _install(version),
              child: Text(installed ? '已安装' : '切换'),
            )
          : IconButton(
              tooltip: '在 GitHub 查看',
              onPressed: _installing
                  ? null
                  : () => launchUrl(
                      version.actionUri,
                      mode: LaunchMode.externalApplication,
                    ),
              icon: const Icon(Icons.open_in_new),
            ),
    );
  }
}
