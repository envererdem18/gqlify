@Tags(['integration'])
@Timeout(Duration(minutes: 6))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/sandbox.dart';

/// Runs the real `build_runner build` and `build_runner watch` in a temporary
/// package and requires, after every change, the generated files to be
/// byte-identical to a clean CLI generation of the same sources.
///
/// Slow (compiles build scripts); run with `dart test -t integration`.
void main() {
  final root = p.normalize(p.join(Directory.current.path, '..', '..'));
  String fixture(String name) =>
      File(p.join('test', 'fixtures', 'shop', name)).readAsStringSync();

  late Sandbox sandbox;

  setUpAll(() async {
    sandbox = Sandbox()
      ..write('pubspec.yaml', '''
name: br_sandbox
publish_to: none
environment:
  sdk: ^3.8.0
dependencies:
  gqlify_runtime:
    path: ${p.join(root, 'packages', 'gqlify_runtime')}
dev_dependencies:
  gqlify:
    path: ${p.join(root, 'packages', 'gqlify')}
  build_runner: ^2.10.0
gqlify:
  schema: lib/graphql/schema.graphql
  scalars:
    DateTime:
      type: DateTime
      json_type: String
      from_json: DateTime.parse
      to_json: encodeDateTime
      import: package:br_sandbox/scalars.dart
''')
      ..write('lib/scalars.dart', fixture('scalars.dart'))
      ..write('lib/graphql/schema.graphql', fixture('schema.graphql'))
      ..write('lib/graphql/fragments.graphql', fixture('fragments.graphql'))
      ..write('lib/graphql/products.graphql', fixture('products.graphql'));
    final pubGet = await Process.run(Platform.resolvedExecutable, [
      'pub',
      'get',
      '--offline',
    ], workingDirectory: sandbox.dir.path);
    expect(pubGet.exitCode, 0, reason: '${pubGet.stdout}${pubGet.stderr}');
  });

  tearDownAll(() => sandbox.dispose());

  /// Generates the current sources with the CLI from scratch.
  Future<Snapshot> cleanCli() async {
    final clone = sandbox.cloneSources();
    try {
      return await clone.run(['generate']);
    } finally {
      clone.dispose();
    }
  }

  Future<void> expectBuilderMatchesCli(String reason) async {
    final cli = await cleanCli();
    expect(cli.exitCode, 0, reason: '$reason: ${cli.diagnostics}');
    final built = sandbox.generatedFiles();
    expect(built.keys, cli.outputs.keys, reason: '$reason: output paths');
    expect(built, cli.outputs, reason: '$reason: output contents');
  }

  test('build_runner build equals CLI generation', () async {
    final build = await Process.run(Platform.resolvedExecutable, [
      'run',
      'build_runner',
      'build',
    ], workingDirectory: sandbox.dir.path);
    expect(build.exitCode, 0, reason: '${build.stdout}${build.stderr}');
    expect(build.stdout, contains('deprecated-field'));
    await expectBuilderMatchesCli('build');
  });

  test(
    'build_runner watch follows schema, fragment and operation changes',
    () async {
      final watch = await Process.start(Platform.resolvedExecutable, [
        'run',
        'build_runner',
        'watch',
      ], workingDirectory: sandbox.dir.path);
      final log = StringBuffer();
      var builds = 0;
      var failures = 0;
      final changed = StreamController<void>.broadcast();
      void onLine(String line) {
        log.writeln(line);
        if (line.contains('Built with build_runner')) builds++;
        if (line.contains('Failed to build with build_runner')) failures++;
        if (line.contains('with build_runner')) changed.add(null);
      }

      watch.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(onLine);
      watch.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(onLine);

      /// Waits until a build finishes after [edit] and settles.
      Future<void> step(
        String reason,
        void Function() edit, {
        bool fails = false,
      }) async {
        final before = builds + failures;
        final finished = changed.stream.firstWhere(
          (_) => builds + failures > before,
        );
        edit();
        await finished.timeout(
          const Duration(minutes: 2),
          onTimeout: () => fail('$reason: no build finished.\n$log'),
        );
        // Let follow-up builds triggered by the same edit settle.
        await Future<void>.delayed(const Duration(seconds: 2));
        if (fails) {
          expect(failures, greaterThan(0), reason: '$reason\n$log');
          expect(
            (await cleanCli()).exitCode,
            1,
            reason: '$reason: the CLI must fail too',
          );
        } else {
          await expectBuilderMatchesCli('$reason\n$log');
        }
      }

      try {
        await changed.stream.first.timeout(
          const Duration(minutes: 3),
          onTimeout: () => fail('watch did not start.\n$log'),
        );
        await expectBuilderMatchesCli('initial watch build');

        await step('operation changed', () {
          sandbox.write(
            'lib/graphql/products.graphql',
            fixture('products.graphql').replaceFirst('    updatedAt\n', ''),
          );
        });
        await step('shared fragment changed', () {
          sandbox.write(
            'lib/graphql/fragments.graphql',
            fixture(
              'fragments.graphql',
            ).replaceFirst('  status\n', '  status\n  tags\n'),
          );
        });
        await step('schema changed', () {
          sandbox.write(
            'lib/graphql/schema.graphql',
            fixture('schema.graphql').replaceFirst(
              '  tags: [String!]!',
              '  tags: [String!]\n  sku: String',
            ),
          );
        });
        await step('document added', () {
          sandbox.write(
            'lib/graphql/extra/users.graphql',
            'query Owner { node(id: "1") { id ...NodeSummary } }',
          );
        });
        await step('invalid document', fails: true, () {
          sandbox.write(
            'lib/graphql/extra/users.graphql',
            'query Owner { nope }',
          );
        });
        await step('document deleted (recovers)', () {
          sandbox.delete('lib/graphql/extra/users.graphql');
        });
        expect(sandbox.exists('lib/graphql/extra/users.graphql.dart'), isFalse);
      } finally {
        // `dart run` starts child processes (the compiled build script); on
        // Windows killing the parent leaves them running, so kill the tree.
        if (Platform.isWindows) {
          await Process.run('taskkill', ['/PID', '${watch.pid}', '/T', '/F']);
        } else {
          watch.kill();
        }
        await watch.exitCode;
        await changed.close();
      }
    },
  );
}
