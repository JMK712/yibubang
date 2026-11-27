import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

typedef WindowsUpdateProgress = void Function(int received, int? total);
typedef WindowsUpdaterLauncher =
    Future<void> Function(
      String executable,
      List<String> arguments,
      Directory workingDirectory,
    );

class WindowsUpdateInstallException implements Exception {
  const WindowsUpdateInstallException(this.message);

  final String message;

  @override
  String toString() => message;
}

class WindowsUpdateInstaller {
  WindowsUpdateInstaller({
    http.Client? client,
    WindowsUpdaterLauncher? launcher,
  }) : _client = client,
       _launcher = launcher;

  final http.Client? _client;
  final WindowsUpdaterLauncher? _launcher;

  static const _maxDownloadBytes = 1024 * 1024 * 1024;
  static const _maxExtractedBytes = 4 * _maxDownloadBytes;
  static const _appFiles = [
    'yibubang.exe',
    'flutter_windows.dll',
    'data/icudtl.dat',
    'data/app.so',
  ];

  Future<void> install(
    Uri downloadUri, {
    required String sha256,
    int? expectedSize,
    WindowsUpdateProgress? onProgress,
    Directory? installDirectory,
    int? processId,
    String? workingDirectory,
  }) async {
    if (downloadUri.scheme != 'https' ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(sha256)) {
      throw const WindowsUpdateInstallException('安装包连接或 SHA-256 无效。');
    }
    final target = installDirectory ?? File(Platform.resolvedExecutable).parent;
    final targetPath = p.normalize(target.absolute.path);
    if (!p.equals(targetPath, await target.resolveSymbolicLinks()) ||
        !_isDedicatedFolder(targetPath) ||
        !_containsApp(targetPath)) {
      throw const WindowsUpdateInstallException('请从独立目录运行解压后的 Windows 应用。');
    }

    final work = await target.parent.createTemp('.yibubang-update-');
    try {
      final zip = File(p.join(work.path, 'update.zip'));
      await _download(downloadUri, zip, sha256, expectedSize, onProgress);
      final expanded = p.join(work.path, 'expanded');
      final zipPath = zip.path;
      final payload = await Isolate.run(() => _extract(zipPath, expanded));
      await zip.delete();

      final config = File(p.join(work.path, 'install.json'));
      await config.writeAsString(
        jsonEncode({
          'target': targetPath,
          'payload': payload,
          'oldPid': processId ?? pid,
          'restartDirectory': workingDirectory ?? Directory.current.path,
          'lock': _sha256Digest(targetPath.toLowerCase()),
        }),
        flush: true,
      );
      final script = await File(
        p.join(work.path, 'apply-update.ps1'),
      ).writeAsString(_applyScript, flush: true);
      final systemRoot = Platform.environment['SystemRoot'] ?? r'C:\Windows';
      await (_launcher ?? _startDetached)(
        p.join(
          systemRoot,
          'System32',
          'WindowsPowerShell',
          'v1.0',
          'powershell.exe',
        ),
        [
          '-NoProfile',
          '-NonInteractive',
          '-WindowStyle',
          'Hidden',
          '-ExecutionPolicy',
          'Bypass',
          '-File',
          script.path,
        ],
        work,
      );
      final ready = File(p.join(work.path, 'ready'));
      final error = File(p.join(work.path, 'start-error.txt'));
      final deadline = Stopwatch()..start();
      while (!await ready.exists()) {
        if (await error.exists()) {
          throw WindowsUpdateInstallException(await error.readAsString());
        }
        if (deadline.elapsed > const Duration(seconds: 12)) {
          throw const WindowsUpdateInstallException('Windows 更新程序未能启动。');
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      await File(p.join(work.path, 'proceed')).writeAsString('', flush: true);
    } catch (_) {
      try {
        await work.delete(recursive: true);
      } on FileSystemException {
        // Windows may still be releasing the helper's handles.
      }
      rethrow;
    }
  }

  Future<void> _download(
    Uri uri,
    File file,
    String expectedHash,
    int? expectedSize,
    WindowsUpdateProgress? onProgress,
  ) async {
    final client = _client ?? http.Client();
    try {
      final request = http.Request('GET', uri);
      final response = await client
          .send(request)
          .timeout(const Duration(seconds: 30));
      if (response.statusCode != 200) {
        throw WindowsUpdateInstallException(
          '下载失败（HTTP ${response.statusCode}）。',
        );
      }
      final length = expectedSize ?? response.contentLength;
      if (length != null && (length <= 0 || length > _maxDownloadBytes)) {
        throw const WindowsUpdateInstallException('安装包大小无效。');
      }
      final digest = _DigestSink();
      final hash = sha256.startChunkedConversion(digest);
      final sink = file.openWrite();
      var received = 0;
      onProgress?.call(0, length);
      try {
        await sink.addStream(
          response.stream.timeout(const Duration(seconds: 30)).map((chunk) {
            received += chunk.length;
            if (received > (length ?? _maxDownloadBytes)) {
              throw const WindowsUpdateInstallException('安装包超出声明大小。');
            }
            hash.add(chunk);
            onProgress?.call(received, length);
            return chunk;
          }),
        );
        hash.close();
      } finally {
        await sink.close();
      }
      if ((length != null && received != length) ||
          digest.value?.toString() != expectedHash) {
        throw const WindowsUpdateInstallException('安装包 SHA-256 或大小校验失败。');
      }
    } finally {
      if (_client == null) client.close();
    }
  }

  static String _extract(String zip, String destination) {
    final archiveInput = InputFileStream(zip);
    try {
      final archive = ZipDecoder().decodeBuffer(archiveInput);
      final paths = <String>{};
      var expandedBytes = 0;
      for (final entry in archive.files) {
        final name = entry.name
            .replaceAll(r'\', '/')
            .replaceFirst(RegExp(r'/$'), '');
        final parts = name.split('/');
        if (entry.isSymbolicLink ||
            parts.any(_invalidPart) ||
            !paths.add(name.toLowerCase())) {
          throw const WindowsUpdateInstallException('安装包含有不安全或重复的路径。');
        }
        if (!entry.isFile) continue;
        expandedBytes += entry.size;
        if (expandedBytes > _maxExtractedBytes || paths.length > 20000) {
          throw const WindowsUpdateInstallException('安装包解压后的大小超出限制。');
        }
        final file = File(parts.fold(destination, p.join));
        file.parent.createSync(recursive: true);
        final output = OutputFileStream(file.path);
        try {
          entry.writeContent(output);
        } finally {
          output.closeSync();
        }
      }
    } finally {
      archiveInput.closeSync();
    }

    final root = Directory(destination);
    final roots = [
      root,
      ...root.listSync(followLinks: false).whereType<Directory>(),
    ].where((candidate) => _containsApp(candidate.path)).toList();
    if (roots.length != 1) {
      throw const WindowsUpdateInstallException('安装包缺少完整的 Windows 应用。');
    }
    final payload = roots.single;
    for (final entry in payload.listSync(followLinks: false)) {
      final name = p.basename(entry.path).toLowerCase();
      final isBundleFile =
          entry is File && (name == 'yibubang.exe' || name.endsWith('.dll'));
      if (!isBundleFile && !(entry is Directory && name == 'data')) {
        throw const WindowsUpdateInstallException('安装包包含应用之外的文件。');
      }
    }
    return payload.path;
  }

  static bool _invalidPart(String part) =>
      part.isEmpty ||
      part.endsWith('.') ||
      part.endsWith(' ') ||
      RegExp(r'[\x00-\x1f<>:"|?*]').hasMatch(part) ||
      RegExp(
        r'^(?:con|prn|aux|nul|com[1-9¹²³]|lpt[1-9¹²³])(?:\.|$)',
        caseSensitive: false,
      ).hasMatch(part);

  static bool _containsApp(String path) =>
      _appFiles.every((name) => File(p.join(path, name)).existsSync());

  static bool _isDedicatedFolder(String path) {
    final env = Platform.environment;
    final profile = env['USERPROFILE'];
    return !p.equals(path, p.dirname(path)) &&
        ![
          env['SystemRoot'],
          env['ProgramFiles'],
          env['ProgramFiles(x86)'],
          profile,
          if (profile != null) ...[
            p.join(profile, 'Downloads'),
            p.join(profile, 'Desktop'),
            p.join(profile, 'Documents'),
          ],
        ].whereType<String>().any((folder) => p.equals(path, folder));
  }

  static String _sha256Digest(String path) =>
      sha256.convert(utf8.encode(path)).toString();

  static Future<void> _startDetached(
    String executable,
    List<String> arguments,
    Directory work,
  ) async {
    await Process.start(
      executable,
      arguments,
      workingDirectory: work.parent.path,
      mode: ProcessStartMode.detached,
    );
  }

  static const _applyScript = r'''
$ErrorActionPreference = 'Stop'
$work = $PSScriptRoot
$config = Get-Content -LiteralPath (Join-Path $work 'install.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$target = [string]$config.target
$payload = [string]$config.payload
$backup = Join-Path $work 'rollback'
$exe = Join-Path $target 'yibubang.exe'
$oldPid = [int]$config.oldPid
$moves = [Collections.Generic.List[object]]::new()
$locked = $false
$ready = $false
$backedUp = $false
$activated = $false
$swapped = $false
$keepWork = $false
$mutex = [Threading.Mutex]::new($false, 'Local\YibubangUpdater-' + [string]$config.lock)

function Move-Entry($source, $destination, $isDirectory) {
  if ($isDirectory) {
    [IO.Directory]::Move($source, $destination)
  } else {
    [IO.File]::Move($source, $destination)
  }
}

function Preserve-Entries($from, $to) {
  foreach ($entry in (Get-ChildItem -LiteralPath $from -Force)) {
    $destination = Join-Path $to $entry.Name
    if (Test-Path -LiteralPath $destination) { continue }
    Move-Entry $entry.FullName $destination $entry.PSIsContainer
    $moves.Add(@{ Old = $entry.FullName; New = $destination; IsDirectory = $entry.PSIsContainer })
  }
}

try {
  try {
    $locked = $mutex.WaitOne(0)
  } catch [Threading.AbandonedMutexException] {
    $locked = $true
  }
  if (!$locked) { throw 'Another update is running.' }
  $parent = [IO.Path]::GetDirectoryName($target)
  if ([IO.Path]::GetDirectoryName($work) -ine $parent -or
      [IO.Path]::GetFileName($work) -notlike '.yibubang-update-*' -or
      !$payload.StartsWith($work + '\expanded', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Invalid staging location.'
  }
  foreach ($path in @($target, $payload, (Join-Path $target 'data'))) {
    if (((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
      throw 'The installation directory uses a junction or symbolic link.'
    }
  }
  $old = if ($oldPid -gt 0) { Get-Process -Id $oldPid -ErrorAction SilentlyContinue }
  [IO.File]::WriteAllText((Join-Path $work 'ready'), '')
  $acceptBy = [DateTime]::UtcNow.AddSeconds(15)
  while (!(Test-Path -LiteralPath (Join-Path $work 'proceed'))) {
    if ([DateTime]::UtcNow -gt $acceptBy) { throw 'The application did not accept the update.' }
    Start-Sleep -Milliseconds 100
  }
  $ready = $true
  if ($old -and !$old.WaitForExit(30000)) { throw 'The original application did not close.' }

  [IO.Directory]::Move($target, $backup)
  $backedUp = $true
  Preserve-Entries (Join-Path $backup 'data') (Join-Path $payload 'data')
  Preserve-Entries $backup $payload
  [IO.Directory]::Move($payload, $target)
  $activated = $true
  $restart = [string]$config.restartDirectory
  if (!(Test-Path -LiteralPath $restart -PathType Container)) { $restart = $target }
  $process = Start-Process -FilePath $exe -WorkingDirectory $restart -PassThru
  if ($process.WaitForExit(5000)) { throw "The replacement exited during startup ($($process.ExitCode))." }
  $swapped = $true
} catch {
  $failure = $_.Exception.Message
  if (!$ready) {
    $keepWork = $true
    [IO.File]::WriteAllText((Join-Path $work 'start-error.txt'), $failure)
  } else {
    try {
      if ($activated) { [IO.Directory]::Move($target, $payload) }
      for ($i = $moves.Count - 1; $i -ge 0; $i--) {
        $entry = $moves[$i]
        Move-Entry $entry.New $entry.Old $entry.IsDirectory
      }
      if ($backedUp) { [IO.Directory]::Move($backup, $target) }
      [IO.File]::WriteAllText((Join-Path $target 'windows-update-error.txt'), $failure)
      if ($null -eq $old -or $old.HasExited) {
        $restart = [string]$config.restartDirectory
        if (!(Test-Path -LiteralPath $restart -PathType Container)) { $restart = $target }
        Start-Process -FilePath $exe -WorkingDirectory $restart
      }
    } catch {
      $keepWork = $true
      [IO.File]::WriteAllText((Join-Path $work 'recovery-error.txt'), "$failure`r`n$($_.Exception.Message)")
    }
  }
} finally {
  if ($locked) { $mutex.ReleaseMutex() }
  $mutex.Dispose()
  if ($ready -and !$keepWork) {
    try { [IO.Directory]::Delete($work, $true) } catch {}
  }
}
if ($swapped) { exit 0 }
exit 1
''';
}

class _DigestSink implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest event) => value = event;

  @override
  void close() {}
}
