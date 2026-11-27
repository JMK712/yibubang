import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:yibubang/services/windows_update_installer.dart';

const _bundlePaths = ['flutter_windows.dll', 'data/icudtl.dat', 'data/app.so'];
final _url = Uri.https('example.test', '/windows.zip');

List<int> _archive(List<int> exe, {String? extra}) {
  final archive = Archive();
  void add(String name, List<int> bytes) =>
      archive.addFile(ArchiveFile(name, bytes.length, bytes));
  add('bundle/yibubang.exe', exe);
  for (final file in _bundlePaths) {
    add('bundle/$file', [42]);
  }
  if (extra != null) add(extra, [5]);
  return ZipEncoder().encode(archive)!;
}

Future<Directory> _installRoot(Directory scratch, List<int> exe) async {
  final root = Directory(p.join(scratch.path, '医不帮 portable'));
  for (final file in ['yibubang.exe', ..._bundlePaths]) {
    final path = File(p.join(root.path, file));
    await path.parent.create(recursive: true);
    await path.writeAsBytes(file == 'yibubang.exe' ? exe : [1]);
  }
  return root;
}

void main() {
  test('wrong hash and unsafe ZIP never start the updater', () async {
    final scratch = await Directory.systemTemp.createTemp(
      'yibubang-update-test-',
    );
    addTearDown(() => scratch.delete(recursive: true));
    final root = await _installRoot(scratch, [1]);
    for (final extra in [
      null,
      'bundle/data/../user.db',
      'bundle/data/a:stream',
    ]) {
      final bytes = _archive([2], extra: extra);
      await expectLater(
        WindowsUpdateInstaller(
          client: MockClient((_) async => http.Response.bytes(bytes, 200)),
          launcher: (_, _, _) async =>
              fail('An unverified package was launched'),
        ).install(
          _url,
          sha256: extra == null ? '0' * 64 : sha256.convert(bytes).toString(),
          installDirectory: root,
        ),
        throwsA(isA<WindowsUpdateInstallException>()),
      );
    }
    expect(await File(p.join(root.path, 'yibubang.exe')).readAsBytes(), [1]);
    expect(scratch.listSync(), hasLength(1));
  });

  test(
    'Windows helper swaps the bundle and rolls back on startup failure',
    () async {
      final scratch = await Directory.systemTemp.createTemp(
        'yibubang-update-e2e-',
      );
      addTearDown(() => scratch.delete(recursive: true));
      final compiler = p.join(
        Platform.environment['SystemRoot']!,
        'Microsoft.NET',
        'Framework64',
        'v4.0.30319',
        'csc.exe',
      );

      Future<List<int>> executable(String name, String body) async {
        final source = File(p.join(scratch.path, '$name.cs'));
        await source.writeAsString('class App { static int Main() { $body } }');
        final output = p.join(scratch.path, '$name.exe');
        final result = await Process.run(compiler, [
          '/nologo',
          '/target:winexe',
          '/out:$output',
          source.path,
        ]);
        expect(result.exitCode, 0, reason: result.stdout.toString());
        return File(output).readAsBytes();
      }

      final old = await executable('old', 'return 0;');
      final broken = await executable('broken', 'return 7;');
      final healthy = await executable('new', '''
System.IO.File.WriteAllText("started.txt", "new");
System.Threading.Thread.Sleep(6500);
return 0;
''');
      final root = await _installRoot(scratch, old);
      final database = File(
        p.join(root.path, '.dart_tool', 'user_data.sqlite'),
      );
      await database.parent.create(recursive: true);
      await database.writeAsString('existing progress');
      final unknown = File(p.join(root.path, 'my-notes.txt'));
      await unknown.writeAsString('notes');

      Future<int> update(List<int> exe) async {
        final bytes = _archive(exe);
        late Process helper;
        await WindowsUpdateInstaller(
          client: MockClient((_) async => http.Response.bytes(bytes, 200)),
          launcher: (executable, args, work) async {
            helper = await Process.start(
              executable,
              args,
              workingDirectory: work.parent.path,
            );
            helper.stdout.drain<void>();
            helper.stderr.drain<void>();
          },
        ).install(
          _url,
          sha256: sha256.convert(bytes).toString(),
          expectedSize: bytes.length,
          installDirectory: root,
          processId: -1,
          workingDirectory: root.path,
        );
        return helper.exitCode;
      }

      expect(await update(broken), 1);
      final exe = File(p.join(root.path, 'yibubang.exe'));
      expect(await exe.readAsBytes(), old);
      expect(await database.readAsString(), 'existing progress');
      expect(await unknown.readAsString(), 'notes');
      expect(
        File(p.join(root.path, 'windows-update-error.txt')).existsSync(),
        isTrue,
      );

      expect(await update(healthy), 0);
      expect(await exe.readAsBytes(), healthy);
      expect(await database.readAsString(), 'existing progress');
      expect(await unknown.readAsString(), 'notes');
      expect(File(p.join(root.path, 'started.txt')).readAsStringSync(), 'new');
      // Wait for the scratch executable to exit before removing the fixture.
      await Future<void>.delayed(const Duration(seconds: 2));
    },
    skip:
        !Platform.isWindows ||
        !File(
          p.join(
            Platform.environment['SystemRoot'] ?? '',
            'Microsoft.NET',
            'Framework64',
            'v4.0.30319',
            'csc.exe',
          ),
        ).existsSync(),
  );
}
