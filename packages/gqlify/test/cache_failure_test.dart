@Tags(['differential'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:gqlify/src/cli/output_sync.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/sandbox.dart';

const _schema =
    'type Product { id: ID! name: String! } type Query { products: [Product!]! }';

/// Fails the [failAt]-th write (1-based) like a full disk or a crash would.
final class FailingIO extends OutputIO {
  FailingIO(this.failAt, {this.error});

  final int failAt;
  final FileSystemException? error;
  int writes = 0;

  @override
  void write(String path, String content) {
    if (++writes == failAt) {
      throw error ?? FileSystemException('Simulated interruption', path);
    }
    super.write(path, content);
  }
}

void main() {
  late Sandbox sandbox;
  setUp(() {
    sandbox = Sandbox()
      ..write('gqlify.yaml', 'schema: lib/schema.graphql\n')
      ..write('lib/schema.graphql', _schema)
      ..write('lib/a.graphql', 'query A { products { id } }')
      ..write('lib/b.graphql', 'query B { products { name } }');
  });
  tearDown(() => sandbox.dispose());

  test('the harness detects a cache that lies', () async {
    await sandbox.run(['generate']);
    // Tamper with an output and make the manifest agree with the tampering:
    // the warm path trusts it, and the differential check must catch it.
    final path = 'lib/a.graphql.dart';
    final tampered = '${sandbox.read(path)}// tampered\n';
    sandbox.write(path, tampered);
    final manifestFile = File(sandbox.path('.dart_tool/gqlify/manifest.json'));
    final manifest =
        jsonDecode(manifestFile.readAsStringSync()) as Map<String, Object?>;
    final outputs = manifest['outputs']! as Map<String, Object?>;
    final digest = await Process.run('shasum', [
      '-a',
      '256',
      sandbox.path(path),
    ]);
    (outputs[path]! as Map<String, Object?>)['sha256'] =
        (digest.stdout as String).split(' ').first;
    manifestFile.writeAsStringSync(jsonEncode(manifest));

    await expectLater(expectMatchesClean(sandbox), throwsA(isA<TestFailure>()));
  }, testOn: 'mac-os || linux');

  test('7a. interrupted multi-file write recovers on the next run', () async {
    await sandbox.run(['generate']);
    sandbox
      ..write('lib/a.graphql', 'query A { products { id name } }')
      ..write('lib/b.graphql', 'query B { products { id } }');
    final failed = await sandbox.run(['generate'], io: FailingIO(2));
    expect(failed.exitCode, 1);
    expect(failed.diagnostics.toString(), contains('write-failed'));
    expect(
      File(sandbox.path('.dart_tool/gqlify/manifest.json')).existsSync(),
      isFalse,
      reason: 'no success-marked cache after a failed write',
    );
    // Exactly one of the two outputs was updated.
    await expectMatchesClean(sandbox, reason: 'after interruption');
  });

  test('7b. disk full is reported and recovered from', () async {
    await sandbox.run(['generate']);
    sandbox.write('lib/a.graphql', 'query A { products { name } }');
    final full = await sandbox.run(
      ['generate'],
      io: FailingIO(
        1,
        error: const FileSystemException(
          'Cannot write file',
          'lib/a.graphql.dart',
          OSError('No space left on device', 28),
        ),
      ),
    );
    expect(full.exitCode, 1);
    expect(full.diagnostics.toString(), contains('No space left on device'));
    await expectMatchesClean(sandbox, reason: 'after disk full');
  });

  test(
    '7c. leftover temporary files from a killed process are removed',
    () async {
      await sandbox.run(['generate']);
      sandbox.write('lib/.a.graphql.dart.4242.gqlify-tmp', 'partial');
      await expectMatchesClean(sandbox, reason: 'temp file');
      expect(sandbox.exists('lib/.a.graphql.dart.4242.gqlify-tmp'), isFalse);
    },
  );

  test('7d. read-only output directory', () async {
    await sandbox.run(['generate']);
    sandbox.write('lib/a.graphql', 'query A { products { name } }');
    await Process.run('chmod', ['555', sandbox.path('lib')]);
    try {
      final denied = await sandbox.run(['generate']);
      expect(denied.exitCode, 1);
      expect(denied.diagnostics.toString(), contains('write-failed'));
    } finally {
      await Process.run('chmod', ['755', sandbox.path('lib')]);
    }
    await expectMatchesClean(sandbox, reason: 'after permissions restored');
  }, testOn: 'mac-os || linux');

  group('7e. concurrency', () {
    final script = p.absolute('bin', 'gqlify.dart');
    final dart = Platform.resolvedExecutable;

    Future<ProcessResult> cli(List<String> args) =>
        Process.run(dart, [script, '-C', sandbox.dir.path, ...args]);

    test(
      'two processes generating simultaneously',
      () async {
        sandbox.write('lib/c.graphql', 'query C { products { id name } }');
        final results = await Future.wait([
          cli(['generate']),
          cli(['generate']),
        ]);
        for (final r in results) {
          expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
        }
        await expectMatchesClean(sandbox, reason: 'after concurrent runs');
        expect((await sandbox.run(['cache', 'verify'])).exitCode, 0);
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );

    test(
      'a lock held by a crashed process does not block later runs',
      () async {
        final holder = await Process.start(dart, [
          p.absolute('test', 'support', 'hold_lock.dart'),
          sandbox.path('.dart_tool/gqlify/lock'),
          '600000',
        ]);
        final stderrDone = holder.stderr.drain<void>();
        await holder.stdout
            .transform(utf8.decoder)
            .firstWhere((l) => l.contains('locked'));

        final blocked = await sandbox.run(['--lock-timeout', '1', 'generate']);
        expect(blocked.exitCode, 1);
        expect(blocked.diagnostics.toString(), contains('Timed out'));

        holder.kill(ProcessSignal.sigkill);
        await holder.exitCode;
        await stderrDone;
        await expectMatchesClean(
          sandbox,
          reason: 'after the lock holder crashed',
        );
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );

    test('waits for a running process', () async {
      final holder = await Process.start(dart, [
        p.absolute('test', 'support', 'hold_lock.dart'),
        sandbox.path('.dart_tool/gqlify/lock'),
        '8000',
      ]);
      await holder.stdout
          .transform(utf8.decoder)
          .firstWhere((l) => l.contains('locked'));
      final result = await cli(['generate']);
      expect(result.exitCode, 0);
      expect(result.stderr, contains('waiting for another gqlify process'));
      await holder.exitCode;
    }, timeout: const Timeout(Duration(minutes: 2)));
  });

  test('cache verify and clear', () async {
    expect((await sandbox.run(['cache', 'verify'])).report['notes'], [
      'gqlify: no cache present.',
    ]);
    await sandbox.run(['generate']);
    expect((await sandbox.run(['cache', 'verify'])).exitCode, 0);

    final artifacts = Directory(
      sandbox.path('.dart_tool/gqlify/artifacts'),
    ).listSync(recursive: true).whereType<File>().toList();
    artifacts.first.writeAsStringSync('truncated');
    final corrupt = await sandbox.run(['cache', 'verify']);
    expect(corrupt.exitCode, 1);
    expect(corrupt.diagnostics.toString(), contains('corrupt-cache'));

    sandbox.write(
      'lib/a.graphql.dart',
      '${sandbox.read('lib/a.graphql.dart')}// edited',
    );
    final notes = (await sandbox.run(['cache', 'verify'])).report['notes'];
    expect(notes.toString(), contains('lib/a.graphql.dart was modified'));

    final before = sandbox.generatedFiles();
    expect((await sandbox.run(['cache', 'clear'])).exitCode, 0);
    expect(
      Directory(sandbox.path('.dart_tool/gqlify/artifacts')).existsSync(),
      isFalse,
    );
    expect(
      File(sandbox.path('.dart_tool/gqlify/manifest.json')).existsSync(),
      isFalse,
    );
    expect(
      sandbox.generatedFiles(),
      before,
      reason: 'clear never touches generated files',
    );
    await expectMatchesClean(sandbox, reason: 'after clear');
  });

  test('check never writes outputs or cache files', () async {
    await sandbox.run(['generate']);
    sandbox.write('lib/a.graphql', 'query A { products { name } }');
    final cacheDir = Directory(sandbox.path('.dart_tool/gqlify'));
    List<String> listing() => [
      for (final e in cacheDir.listSync(recursive: true))
        if (e is File && !e.path.endsWith('lock'))
          '${e.path}:${e.lengthSync()}',
    ]..sort();
    final cacheBefore = listing();
    final outputsBefore = sandbox.generatedFiles();
    final check = await sandbox.run(['check']);
    expect(check.exitCode, 1);
    expect(sandbox.generatedFiles(), outputsBefore);
    expect(listing(), cacheBefore);
  });
}
