import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:args/command_runner.dart';
import 'package:path/path.dart' as p;

import '../cache/cache_store.dart';
import '../cache/fingerprint.dart';
import '../cache/incremental.dart';
import '../cache/lock.dart';
import '../diagnostics.dart';
import 'output_sync.dart';
import 'project.dart';

/// Exit codes of the `gqlify` command.
abstract final class ExitCodes {
  static const success = 0;

  /// Invalid schema/documents/config, out-of-date outputs (`check`), a
  /// corrupt cache (`cache verify`) or a failed write.
  static const failure = 1;
  static const usage = 64;
}

/// The `gqlify` command line interface.
final class GqlifyCommandRunner extends CommandRunner<int> {
  GqlifyCommandRunner({
    StringSink? out,
    StringSink? err,
    this.io = const OutputIO(),
  }) : out = out ?? stdout,
       err = err ?? stderr,
       super('gqlify', 'GraphQL, simplified for Dart.') {
    argParser
      ..addOption(
        'project-dir',
        abbr: 'C',
        help:
            'Package root containing gqlify.yaml (defaults to the current '
            'directory).',
      )
      ..addOption(
        'reporter',
        allowed: ['human', 'json'],
        defaultsTo: 'human',
        help:
            'Output format. "json" prints one machine-readable object to '
            'stdout.',
      )
      ..addOption(
        'lock-timeout',
        defaultsTo: '120',
        help: 'Seconds to wait for another gqlify process on the same package.',
      );
    addCommand(_GenerateCommand(this));
    addCommand(_CheckCommand(this));
    addCommand(_CacheCommand(this));
  }

  final StringSink out;
  final StringSink err;

  /// File operations for outputs; replaced in tests to inject failures.
  final OutputIO io;

  @override
  Future<int> run(Iterable<String> args) async {
    try {
      return await super.run(args) ?? ExitCodes.success;
    } on UsageException catch (e) {
      err.writeln(e);
      return ExitCodes.usage;
    }
  }

  Project project(ArgResults? globalResults) => Project(
    p.normalize(
      p.absolute(
        globalResults?.option('project-dir') ?? Directory.current.path,
      ),
    ),
  );
}

/// What a command did, rendered for humans (stderr/stdout) or as one JSON
/// object on stdout (`--reporter json`).
final class _Report {
  _Report(this.command);

  final String command;
  final stopwatch = Stopwatch()..start();
  final List<Diagnostic> diagnostics = [];
  final Map<String, List<String>> files = {};
  final List<OutputExplanation> explanations = [];
  final List<String> notes = [];
  Map<String, Duration> timings = const {};
  String? cacheStatus;
  String? summary;
  bool success = false;

  Map<String, Object?> toJson({required bool explain}) => {
    'command': command,
    'success': success,
    'diagnostics': [for (final d in diagnostics) d.toJson()],
    'files': files,
    if (cacheStatus != null) 'cache': cacheStatus,
    if (notes.isNotEmpty) 'notes': notes,
    if (explain) 'explain': [for (final e in explanations) e.toJson()],
    if (explain)
      'timings': {
        for (final MapEntry(:key, :value) in timings.entries)
          key: value.inMicroseconds / 1000,
      },
    'elapsedMs': stopwatch.elapsedMilliseconds,
  };
}

abstract base class _GqlifyCommand extends Command<int> {
  _GqlifyCommand(this.cli);

  final GqlifyCommandRunner cli;

  bool get _json => globalResults?.option('reporter') == 'json';

  bool get _explain =>
      argResults?.options.contains('explain') == true &&
      argResults!.flag('explain');

  Duration get _lockTimeout {
    final seconds = int.tryParse(globalResults?.option('lock-timeout') ?? '');
    if (seconds == null || seconds < 0) {
      throw UsageException(
        '--lock-timeout must be a number of seconds.',
        usage,
      );
    }
    return Duration(seconds: seconds);
  }

  void _waiting() {
    if (!_json) {
      cli.err.writeln(
        'gqlify: waiting for another gqlify process on this package...',
      );
    }
  }

  int finish(_Report report, {required bool success}) {
    report.success = success;
    if (_json) {
      cli.out.writeln(
        const JsonEncoder.withIndent(
          '  ',
        ).convert(report.toJson(explain: _explain)),
      );
    } else {
      for (final d in report.diagnostics) {
        cli.err.writeln(d);
      }
      for (final note in report.notes) {
        cli.out.writeln(note);
      }
      if (_explain) _printExplanation(report);
      if (report.summary case final summary?) {
        (success ? cli.out : cli.err).writeln(summary);
      }
    }
    return success ? ExitCodes.success : ExitCodes.failure;
  }

  void _printExplanation(_Report report) {
    final out = cli.out;
    out.writeln('Cache: ${report.cacheStatus ?? 'not used'}');
    for (final e in report.explanations) {
      final format = switch (e.formatCached) {
        true => '; formatting reused from cache',
        false => '; formatted',
        null => '',
      };
      out.writeln('  ${e.status.padRight(10)} ${e.path}');
      out.writeln('             ${e.reasons.join('; ')}$format');
    }
    if (report.timings.isNotEmpty) {
      out.writeln('Timings:');
      for (final MapEntry(:key, :value) in report.timings.entries) {
        out.writeln(
          '  ${key.padRight(18)} ${(value.inMicroseconds / 1000).toStringAsFixed(1)} ms',
        );
      }
    }
  }

  Future<IncrementalOutcome?> runIncremental(
    _Report report,
    CacheMode mode,
  ) async {
    try {
      return await IncrementalGenerator(
        cli.project(globalResults),
        mode: mode,
        io: cli.io,
        lockTimeout: _lockTimeout,
        onLockWait: _waiting,
      ).run();
    } on FileSystemException catch (e) {
      report.diagnostics.add(
        Diagnostic(
          severity: Severity.error,
          code: 'io-error',
          message: '${e.message}${e.path == null ? '' : ' (${e.path})'}',
        ),
      );
      return null;
    }
  }

  void absorb(_Report report, IncrementalOutcome outcome) {
    report
      ..diagnostics.addAll(outcome.diagnostics)
      ..files.addAll(outcome.files)
      ..explanations.addAll(outcome.explanations)
      ..cacheStatus = outcome.cacheStatus
      ..timings = outcome.timings;
  }
}

final class _GenerateCommand extends _GqlifyCommand {
  _GenerateCommand(super.cli) {
    argParser
      ..addFlag(
        'clean',
        negatable: false,
        help:
            'Recompute everything without using cached results, reconcile '
            'outputs and rebuild the cache. Never deletes unrelated files.',
      )
      ..addFlag(
        'explain',
        negatable: false,
        help:
            'Report why each output was regenerated, reused or removed, and '
            'time spent per phase.',
      );
  }

  @override
  String get name => 'generate';

  @override
  String get description =>
      'Generate Dart code from the schema and operation documents.';

  @override
  Future<int> run() async {
    final report = _Report(name);
    final outcome = await runIncremental(
      report,
      argResults!.flag('clean') ? CacheMode.clean : CacheMode.normal,
    );
    if (outcome == null) return finish(report, success: false);
    absorb(report, outcome);
    if (!outcome.success) {
      report.summary = report.diagnostics.any((d) => d.code == 'write-failed')
          ? 'gqlify: writing outputs failed.'
          : 'gqlify: generation failed; no files were changed.';
      return finish(report, success: false);
    }
    final files = outcome.files;
    report.summary =
        'gqlify: ${files['created']!.length} created, ${files['updated']!.length} updated, '
        '${files['unchanged']!.length} unchanged, ${files['removed']!.length} removed '
        '(${report.stopwatch.elapsedMilliseconds} ms).';
    return finish(report, success: true);
  }
}

final class _CheckCommand extends _GqlifyCommand {
  _CheckCommand(super.cli) {
    argParser
      ..addFlag('clean', negatable: false, help: 'Do not use cached results.')
      ..addFlag(
        'explain',
        negatable: false,
        help: 'Explain the result of every output.',
      );
  }

  @override
  String get name => 'check';

  @override
  String get description =>
      'Validate schema and documents and verify generated files are up to '
      'date, without writing anything. Exits with 1 on failure (for CI).';

  @override
  Future<int> run() async {
    final report = _Report(name);
    // `check` never writes, including cache files; --clean only bypasses
    // cached results.
    final outcome = await runIncremental(
      report,
      argResults!.flag('clean') ? CacheMode.clean : CacheMode.readOnly,
    );
    if (outcome == null) return finish(report, success: false);
    absorb(report, outcome);
    if (outcome.diagnostics.any((d) => d.isError)) {
      return finish(report, success: false);
    }
    final files = outcome.files;
    for (final (key, label) in [
      ('missing', 'missing'),
      ('outdated', 'out of date'),
      ('stale', 'stale (no longer generated)'),
      ('conflicts', 'conflicts with a non-generated file'),
    ]) {
      for (final path in files[key] ?? const <String>[]) {
        report.diagnostics.add(
          Diagnostic(
            severity: Severity.error,
            code: 'outdated-output',
            message: 'Generated file is $label.',
            path: path,
          ),
        );
      }
    }
    if (!outcome.success) {
      report.summary =
          "gqlify: generated files are not up to date; run 'dart run gqlify generate'.";
      return finish(report, success: false);
    }
    report.summary =
        'gqlify: ${outcome.outputCount} generated files are up to date.';
    return finish(report, success: true);
  }
}

final class _CacheCommand extends Command<int> {
  _CacheCommand(GqlifyCommandRunner cli) {
    addSubcommand(_CacheVerifyCommand(cli));
    addSubcommand(_CacheClearCommand(cli));
  }

  @override
  String get name => 'cache';

  @override
  String get description =>
      'Inspect or clear the CLI cache in .dart_tool/gqlify/ (never touches '
      'build_runner\'s cache or generated files).';
}

final class _CacheVerifyCommand extends _GqlifyCommand {
  _CacheVerifyCommand(super.cli);

  @override
  String get name => 'verify';

  @override
  String get description =>
      'Check the integrity of the cache. Exits with 1 if it is corrupt. A '
      'corrupt or outdated cache is always ignored and rebuilt by generate.';

  @override
  Future<int> run() async {
    final report = _Report('cache verify');
    final project = cli.project(globalResults);
    final store = CacheStore(project.root);
    final lock = await ProjectLock.acquire(
      store.lockPath,
      exclusive: false,
      timeout: _lockTimeout,
      onWait: _waiting,
    );
    try {
      final problems = <String>[];
      final (manifest, reason) = store.readManifest();
      if (manifest == null) {
        if (File(store.manifestPath).existsSync()) {
          problems.add(reason);
        } else {
          report.notes.add('gqlify: no cache present.');
        }
      } else {
        final generator = await generatorFingerprint();
        if (generator != manifest.generator) {
          report.notes.add(
            'gqlify: the cache was written by a different generator '
            'version and will be rebuilt on the next generate.',
          );
        }
        for (final MapEntry(key: path, value: record)
            in manifest.outputs.entries) {
          final file = File(project.absolute(path));
          if (!file.existsSync()) {
            report.notes.add(
              'gqlify: $path is missing; the next generate restores it.',
            );
          } else if (sha256Hex(file.readAsBytesSync()) != record.sha256) {
            report.notes.add(
              'gqlify: $path was modified; the next generate restores it.',
            );
          }
        }
      }
      problems.addAll(store.verifyArtifacts());
      for (final problem in problems) {
        report.diagnostics.add(
          Diagnostic(
            severity: Severity.error,
            code: 'corrupt-cache',
            message:
                '$problem. Run `dart run gqlify cache clear` or `generate --clean`.',
          ),
        );
      }
      if (problems.isEmpty && manifest != null) {
        report.summary =
            'gqlify: cache is valid (${manifest.outputs.length} outputs recorded).';
      }
      return finish(report, success: problems.isEmpty);
    } finally {
      lock.release();
    }
  }
}

final class _CacheClearCommand extends _GqlifyCommand {
  _CacheClearCommand(super.cli);

  @override
  String get name => 'clear';

  @override
  String get description =>
      'Delete the CLI cache. Generated files are kept; only speed is affected.';

  @override
  Future<int> run() async {
    final report = _Report('cache clear');
    final store = CacheStore(cli.project(globalResults).root);
    final lock = await ProjectLock.acquire(
      store.lockPath,
      exclusive: true,
      timeout: _lockTimeout,
      onWait: _waiting,
    );
    try {
      store.clear();
    } finally {
      lock.release();
    }
    report.summary = 'gqlify: cache cleared.';
    return finish(report, success: true);
  }
}
