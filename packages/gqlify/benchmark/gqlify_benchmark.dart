// Benchmarks gqlify end to end, the way users run it: `dart run gqlify` in
// a separate process (including startup), plus optional build_runner runs.
//
//   dart run benchmark/gqlify_benchmark.dart [--fixtures small,medium,large,magento]
//       [--iterations 5] [--build-runner] [--markdown BENCHMARKS.results.md]
//
// The Magento fixture needs `benchmark/fetch_magento.sh` first.
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;

import 'src/magento_schema.dart';
import 'src/operations.dart';
import 'package:gqlify/gqlify.dart';
import 'package:gqlify/src/schema/loader.dart';

final _packageRoot = p.normalize(
  p.join(p.dirname(Platform.script.toFilePath()), '..'),
);
final _repoRoot = p.normalize(p.join(_packageRoot, '..', '..'));
final _work = p.join(_packageRoot, '.dart_tool', 'gqlify_benchmark');

Future<void> main(List<String> args) async {
  final parser = ArgParser()
    ..addOption('fixtures', defaultsTo: 'small,medium,large,magento')
    ..addOption('iterations', defaultsTo: '5')
    ..addFlag('build-runner', help: 'Also benchmark build_runner (slow).')
    ..addFlag(
      'aot',
      help:
          'Run an AOT-compiled gqlify (`dart compile exe`) instead of `dart run gqlify`.',
    )
    ..addOption('markdown', help: 'Write results as Markdown to this file.');
  final options = parser.parse(args);
  final iterations = int.parse(options.option('iterations')!);
  if (options.flag('aot')) {
    _aot = p.join(_work, 'gqlify_aot');
    await _run(Platform.resolvedExecutable, [
      'compile',
      'exe',
      p.join(_packageRoot, 'bin', 'gqlify.dart'),
      '-o',
      _aot!,
    ], _packageRoot);
  }
  final results = <FixtureResult>[];
  for (final name in options.option('fixtures')!.split(',')) {
    final fixture = await _fixture(name.trim());
    if (fixture == null) {
      stderr.writeln('Skipping $name (run benchmark/fetch_magento.sh first).');
      continue;
    }
    stderr.writeln('== ${fixture.name}: ${fixture.describe()}');
    results.add(
      await _benchmark(
        fixture,
        iterations,
        buildRunner: options.flag('build-runner'),
      ),
    );
  }
  final report = _markdown(results, iterations);
  stdout.writeln(report);
  if (options.option('markdown') case final path?) {
    File(path).writeAsStringSync(report);
  }
}

// -----------------------------------------------------------------------------
// Fixtures

final class Fixture {
  Fixture(
    this.name,
    this.schema,
    this.documents, {
    this.extraFiles = const {},
    this.pubspecExtra = '',
  });

  final String name;
  final String schema;
  final Map<String, String> documents;
  final Map<String, String> extraFiles;
  final String pubspecExtra;

  String describe() {
    final sink = DiagnosticSink();
    final s = loadSchema([GqlifySource('schema.graphql', schema)], sink)!;
    final ops = documents.values.fold(
      0,
      (n, d) =>
          n +
          RegExp(
            r'^\s*(query|mutation) ',
            multiLine: true,
          ).allMatches(d).length,
    );
    final frags = documents.values.fold(
      0,
      (n, d) =>
          n + RegExp(r'^\s*fragment ', multiLine: true).allMatches(d).length,
    );
    return '${s.types.length} schema types, ${documents.length} documents, $ops operations, $frags fragments, '
        '${(schema.length / 1024).toStringAsFixed(0)} KiB schema';
  }
}

Future<Fixture?> _fixture(String name) async {
  switch (name) {
    case 'small':
      final example = p.join(_repoRoot, 'example', 'lib');
      return Fixture(
        'small (example/)',
        File(p.join(example, 'graphql', 'schema.graphql')).readAsStringSync(),
        {
          for (final f in Directory(
            p.join(example, 'graphql'),
          ).listSync().whereType<File>())
            if (f.path.endsWith('.graphql') &&
                !f.path.endsWith('schema.graphql'))
              'lib/graphql/${p.basename(f.path)}': f.readAsStringSync(),
        },
        extraFiles: {
          'lib/scalars.dart': File(
            p.join(example, 'scalars.dart'),
          ).readAsStringSync(),
        },
        pubspecExtra: '''
  scalars:
    DateTime:
      type: DateTime
      json_type: String
      from_json: DateTime.parse
      to_json: encodeDateTime
      import: package:bench/scalars.dart
''',
      );
    case 'medium':
      return _synthetic(
        'medium (synthetic)',
        types: 60,
        documents: 40,
        ops: 5,
        fragments: 30,
      );
    case 'large':
      return _synthetic(
        'large (synthetic)',
        types: 400,
        documents: 200,
        ops: 5,
        fragments: 120,
      );
    case 'magento':
      final dir = Directory(p.join(_work, 'magento'));
      if (!dir.existsSync()) return null;
      final schema = mergeMagentoSchema(dir);
      final sink = DiagnosticSink();
      final model = loadSchema([GqlifySource('schema.graphql', schema)], sink)!;
      return Fixture(
        'magento (Magento 2.4 open source schema)',
        schema,
        OperationGenerator(
          model,
          Random(7),
        ).generate(documents: 60, operationsPerDocument: 5, fragments: 60),
      );
  }
  throw ArgumentError('Unknown fixture $name');
}

Fixture _synthetic(
  String name, {
  required int types,
  required int documents,
  required int ops,
  required int fragments,
}) {
  final schema = syntheticSchema(types: types);
  final sink = DiagnosticSink();
  final model = loadSchema([GqlifySource('schema.graphql', schema)], sink)!;
  return Fixture(
    name,
    schema,
    OperationGenerator(model, Random(1)).generate(
      documents: documents,
      operationsPerDocument: ops,
      fragments: fragments,
    ),
  );
}

// -----------------------------------------------------------------------------
// Runs

final class Sample {
  Sample(this.wallMs, this.report);

  final double wallMs;
  final Map<String, Object?> report;

  double phase(String name) =>
      ((report['timings'] as Map?)?[name] as num?)?.toDouble() ?? 0;
  int get rss => (report['peakRssBytes'] as int?) ?? 0;
  String get cache => report['cache'] as String? ?? '';
  int count(String category) =>
      ((report['files'] as Map?)?[category] as List?)?.length ?? 0;
}

final class FixtureResult {
  FixtureResult(this.fixture, this.description);

  final String fixture;
  final String description;
  final Map<String, List<Sample>> scenarios = {};
  final Map<String, double> buildRunner = {};
}

Future<FixtureResult> _benchmark(
  Fixture fixture,
  int iterations, {
  required bool buildRunner,
}) async {
  final dir = p.join(_work, 'run', fixture.name.split(' ').first);
  _writeProject(dir, fixture);
  await _run(Platform.resolvedExecutable, ['pub', 'get', '--offline'], dir);
  // Compile the gqlify snapshot once, as users' second run would.
  await _gqlify(dir, ['generate']);

  final result = FixtureResult(fixture.name, fixture.describe());
  final schemaPath = p.join(dir, 'lib', 'graphql', 'schema.graphql');
  final firstDoc = fixture.documents.keys.firstWhere(
    (k) => k.contains('/ops/') || !k.contains('fragment'),
  );
  final fragmentDoc = fixture.documents.keys
      .where((k) => fixture.documents[k]!.contains('fragment '))
      .firstOrNull;

  for (var i = 0; i < iterations; i++) {
    _resetOutputs(dir, fixture);
    Future<void> sample(String scenario, List<String> args) async {
      final s = await _gqlify(dir, args);
      result.scenarios.putIfAbsent(scenario, () => []).add(s);
    }

    await sample('cold (no cache, no outputs)', ['generate']);
    await sample('warm (nothing changed)', ['generate']);
    File(p.join(dir, firstDoc)).writeAsStringSync(
      '${fixture.documents[firstDoc]}\nquery BenchEdit$i { __typename }\n',
    );
    await sample('one operation document changed', ['generate']);
    if (fragmentDoc != null) {
      final edited = fixture.documents[fragmentDoc]!.replaceFirstMapped(
        RegExp(r'(fragment \w+ on \w+ \{)'),
        (m) => '${m[1]} __typename',
      );
      File(p.join(dir, fragmentDoc)).writeAsStringSync(edited);
      await sample('shared fragment changed', ['generate']);
    }
    File(schemaPath).writeAsStringSync(
      '${fixture.schema}\nextend type Query { benchEdit$i: Int }\n',
    );
    await sample('schema changed', ['generate']);
    await sample('--clean', ['generate', '--clean']);
    // Restore sources for the next iteration.
    _writeProject(dir, fixture);
  }

  if (buildRunner) {
    _resetOutputs(dir, fixture);
    _deleteIfExists(p.join(dir, '.dart_tool', 'build'));
    result.buildRunner['first build (incl. compiling builders)'] = await _timed(
      Platform.resolvedExecutable,
      ['run', 'build_runner', 'build'],
      dir,
    );
    result.buildRunner['no-op build'] = await _timed(
      Platform.resolvedExecutable,
      ['run', 'build_runner', 'build'],
      dir,
    );
    if (fragmentDoc != null) {
      final edited = fixture.documents[fragmentDoc]!.replaceFirstMapped(
        RegExp(r'(fragment \w+ on \w+ \{)'),
        (m) => '${m[1]} __typename',
      );
      File(p.join(dir, fragmentDoc)).writeAsStringSync(edited);
      result.buildRunner['shared fragment changed'] = await _timed(
        Platform.resolvedExecutable,
        ['run', 'build_runner', 'build'],
        dir,
      );
    }
    _writeProject(dir, fixture);
  }
  return result;
}

void _writeProject(String dir, Fixture fixture) {
  void write(String relative, String content) {
    final file = File(p.join(dir, relative));
    file.parent.createSync(recursive: true);
    if (!file.existsSync() || file.readAsStringSync() != content) {
      file.writeAsStringSync(content);
    }
  }

  write('pubspec.yaml', '''
name: bench
publish_to: none
environment:
  sdk: ^3.8.0
dependencies:
  gqlify_runtime:
    path: ${p.join(_repoRoot, 'packages', 'gqlify_runtime')}
dev_dependencies:
  gqlify:
    path: ${p.join(_repoRoot, 'packages', 'gqlify')}
  build_runner: ^2.10.0
gqlify:
  schema: lib/graphql/schema.graphql
${fixture.pubspecExtra}''');
  write('lib/graphql/schema.graphql', fixture.schema);
  for (final MapEntry(:key, :value) in {
    ...fixture.documents,
    ...fixture.extraFiles,
  }.entries) {
    write(key, value);
  }
  // Remove documents added by edits.
  for (final f in Directory(
    p.join(dir, 'lib'),
  ).listSync(recursive: true).whereType<File>()) {
    final relative = p.relative(f.path, from: dir).replaceAll(r'\', '/');
    if (relative.endsWith('.graphql') &&
        relative != 'lib/graphql/schema.graphql' &&
        !fixture.documents.containsKey(relative)) {
      f.deleteSync();
    }
  }
}

void _resetOutputs(String dir, Fixture fixture) {
  _deleteIfExists(p.join(dir, '.dart_tool', 'gqlify'));
  for (final f in Directory(
    p.join(dir, 'lib'),
  ).listSync(recursive: true).whereType<File>()) {
    if (f.path.endsWith('.graphql.dart')) f.deleteSync();
  }
}

void _deleteIfExists(String path) {
  final dir = Directory(path);
  if (dir.existsSync()) dir.deleteSync(recursive: true);
}

/// Path of the AOT-compiled CLI when benchmarking with `--aot`.
String? _aot;

Future<Sample> _gqlify(String dir, List<String> args) async {
  final stopwatch = Stopwatch()..start();
  final command = ['--reporter', 'json', ...args, '--explain'];
  final result = _aot == null
      ? await Process.run(Platform.resolvedExecutable, [
          'run',
          'gqlify',
          ...command,
        ], workingDirectory: dir)
      : await Process.run(_aot!, command, workingDirectory: dir);
  stopwatch.stop();
  final report = jsonDecode(result.stdout as String) as Map<String, Object?>;
  if (result.exitCode != 0) {
    throw StateError(
      'gqlify ${args.join(' ')} failed in $dir: ${report['diagnostics']}',
    );
  }
  return Sample(stopwatch.elapsedMicroseconds / 1000, report);
}

Future<void> _run(String executable, List<String> args, String dir) async {
  final result = await Process.run(executable, args, workingDirectory: dir);
  if (result.exitCode != 0) {
    throw StateError(
      '${args.join(' ')} failed: ${result.stdout}${result.stderr}',
    );
  }
}

Future<double> _timed(String executable, List<String> args, String dir) async {
  final stopwatch = Stopwatch()..start();
  await _run(executable, args, dir);
  return stopwatch.elapsedMicroseconds / 1000;
}

// -----------------------------------------------------------------------------
// Report

String _markdown(List<FixtureResult> results, int iterations) {
  String ms(double v) => v >= 1000
      ? '${(v / 1000).toStringAsFixed(2)} s'
      : '${v.toStringAsFixed(0)} ms';
  double median(Iterable<double> values) {
    final sorted = values.toList()..sort();
    return sorted.isEmpty ? 0 : sorted[sorted.length ~/ 2];
  }

  final out = StringBuffer()
    ..writeln('## Environment')
    ..writeln()
    ..writeln('- Dart: `${Platform.version}`')
    ..writeln(
      '- OS: ${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
    )
    ..writeln('- Logical CPUs: ${Platform.numberOfProcessors}')
    ..writeln(
      '- Iterations per scenario: $iterations (median reported; min–max in parentheses)',
    )
    ..writeln(
      _aot == null
          ? '- Command: `dart run gqlify generate --explain --reporter json` in a separate process (JIT snapshot, startup included)'
          : '- Command: AOT-compiled gqlify (`dart compile exe bin/gqlify.dart`) in a separate process, startup included',
    )
    ..writeln(
      '- Formatting isolates: ${min(2, Platform.numberOfProcessors)} (default)',
    )
    ..writeln();
  for (final r in results) {
    out
      ..writeln('## ${r.fixture}')
      ..writeln()
      ..writeln(r.description)
      ..writeln()
      ..writeln(
        '| Scenario | Wall time | Engine | Format (of engine) | Startup + I/O | Peak RSS | Cache |',
      )
      ..writeln('| --- | --- | --- | --- | --- | --- | --- |');
    for (final MapEntry(key: scenario, value: samples) in r.scenarios.entries) {
      final wall = samples.map((s) => s.wallMs);
      final engine = median(samples.map((s) => s.phase('engine')));
      final format = median(samples.map((s) => s.phase('engine.format')));
      // Top-level phases only; `engine.*` are sub-phases of `engine`.
      final measured = median(
        samples.map(
          (s) => (s.report['timings'] as Map).entries
              .where((e) => !(e.key as String).contains('.'))
              .fold(0.0, (a, e) => a + (e.value as num)),
        ),
      );
      final rss = samples.map((s) => s.rss).reduce(max);
      final cacheStatus = samples.first.cache.split(':').first;
      out.writeln(
        '| $scenario | ${ms(median(wall))} (${ms(wall.reduce(min))}–${ms(wall.reduce(max))}) '
        '| ${ms(engine)} | ${ms(format)} | ${ms(median(wall) - measured)} '
        '| ${(rss / 1024 / 1024).toStringAsFixed(0)} MiB | $cacheStatus |',
      );
    }
    final phases = r.scenarios.values.first;
    out
      ..writeln()
      ..writeln(
        'Cold-run phases (median): ${[
          for (final phase in ['discovery', 'hashing', 'scan', 'engine.schema', 'engine.parse', 'engine.validate', 'engine.model', 'engine.emit', 'engine.format', 'write', 'verify', 'cache']) '$phase ${ms(median(phases.map((s) => s.phase(phase))))}',
        ].join(', ')}.',
      )
      ..writeln();
    if (r.buildRunner.isNotEmpty) {
      out
        ..writeln('build_runner (single run each):')
        ..writeln();
      for (final MapEntry(:key, :value) in r.buildRunner.entries) {
        out.writeln('- $key: ${ms(value)}');
      }
      out.writeln();
    }
  }
  return out.toString();
}
