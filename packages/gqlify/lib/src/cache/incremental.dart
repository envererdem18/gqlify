import 'dart:convert';
import 'dart:io';

import '../cli/output_sync.dart';
import '../cli/project.dart';
import '../diagnostics.dart';
import '../engine.dart';
import 'cache_store.dart';
import 'fingerprint.dart';
import 'lock.dart';
import 'manifest.dart';

/// How a run treats the cache.
enum CacheMode {
  /// Use and update the cache.
  normal,

  /// Recompute everything without reading cached results, reconcile
  /// outputs and rebuild the cache (`--clean`).
  clean,

  /// Use the cache but never write outputs or cache files (`check`).
  readOnly,
}

/// Why an output was (re)examined, for `--explain`.
final class OutputExplanation {
  OutputExplanation(this.path, this.status, this.reasons, {this.formatCached});

  final String path;

  /// `created`, `updated`, `unchanged`, `removed` or `conflict` (for
  /// `check`: `missing`, `outdated`, `up-to-date`, `stale`, `conflict`).
  final String status;
  final List<String> reasons;

  /// Whether formatting was served from the cache (`null`: not formatted).
  final bool? formatCached;

  Map<String, Object?> toJson() => {
    'path': path,
    'status': status,
    'reasons': reasons,
    if (formatCached != null) 'formatCached': formatCached,
  };
}

/// Result of an incremental run.
final class IncrementalOutcome {
  IncrementalOutcome({
    required this.success,
    required this.diagnostics,
    required this.files,
    required this.explanations,
    required this.cacheStatus,
    required this.timings,
    this.plan,
    this.outputCount = 0,
  });

  final bool success;
  final List<Diagnostic> diagnostics;

  /// Affected files by category, for reports.
  final Map<String, List<String>> files;
  final List<OutputExplanation> explanations;

  /// How the cache was used, e.g. `hit: inputs unchanged`.
  final String cacheStatus;
  final Map<String, Duration> timings;
  final OutputPlan? plan;
  final int outputCount;
}

/// Correctness-first incremental generation for the CLI.
///
/// Invariant: for the same sources and configuration, the files written and
/// the diagnostics reported are identical to a clean run without cache.
///
/// * Validation always runs in full unless *every* input is byte-identical
///   to the last successful run and every recorded output is verified on
///   disk ("warm hit"); the cache can therefore never hide a new error.
/// * Otherwise the engine runs; only formatting is memoized, keyed by the
///   formatter's exact input, so a memo can never yield stale code.
/// * The manifest is deleted before outputs change and written only after
///   all outputs are written and re-verified.
final class IncrementalGenerator {
  IncrementalGenerator(
    this.project, {
    this.mode = CacheMode.normal,
    this.io = const OutputIO(),
    this.onLockWait,
    this.lockTimeout = const Duration(minutes: 2),
  }) : cache = CacheStore(project.root);

  final Project project;
  final CacheMode mode;
  final OutputIO io;
  final CacheStore cache;
  final void Function()? onLockWait;
  final Duration lockTimeout;

  bool get _writes => mode != CacheMode.readOnly;

  Future<IncrementalOutcome> run() async {
    final lock = await ProjectLock.acquire(
      cache.lockPath,
      exclusive: _writes,
      timeout: lockTimeout,
      onWait: onLockWait,
    );
    try {
      return await _run();
    } finally {
      lock.release();
    }
  }

  Future<IncrementalOutcome> _run() async {
    final timings = <String, Duration>{};
    final stopwatch = Stopwatch()..start();
    void lap(String phase) {
      timings[phase] = stopwatch.elapsed;
      stopwatch.reset();
    }

    IncrementalOutcome fail(List<Diagnostic> diagnostics, String cacheStatus) =>
        IncrementalOutcome(
          success: false,
          diagnostics: diagnostics,
          files: const {},
          explanations: const [],
          cacheStatus: cacheStatus,
          timings: timings,
        );

    // 1. Inputs.
    final sink = DiagnosticSink();
    final resolved = project.resolveConfig(sink);
    final input = resolved == null
        ? null
        : project.loadInput(resolved.config, sink);
    if (input == null) return fail(sink.sorted(), 'not used');
    lap('discovery');

    // 2. Cache identity.
    final generator = await generatorFingerprint();
    final inputs = {
      for (final s in [...input.schema, ...input.documents])
        s.path: sha256Text(s.content),
    };
    final configDigest = sha256Text(resolved!.digestSource);
    final inputKey = sha256Text(
      jsonEncode({
        'cache': Manifest.formatVersion,
        'generator': generator,
        'config': configDigest,
        'format': input.format.fingerprint,
        'schema': [
          for (final s in input.schema) [s.path, inputs[s.path]],
        ],
        'documents': [
          for (final d in input.documents) [d.path, inputs[d.path]],
        ],
      }),
    );
    lap('hashing');

    Manifest? previous;
    String cacheStatus;
    if (generator == null) {
      cacheStatus = 'disabled: generator fingerprint unavailable';
    } else if (mode == CacheMode.clean) {
      cacheStatus = 'bypassed: clean build requested';
    } else {
      final (manifest, reason) = cache.readManifest();
      previous = manifest;
      cacheStatus = reason;
      if (manifest != null && manifest.generator != generator) {
        previous = null;
        cacheStatus = 'cache ignored: generator changed';
      }
    }

    final owned = project.ownedOutputs();
    lap('scan');

    // 3. Warm hit: identical inputs and verified, complete outputs.
    if (previous != null && previous.inputKey == inputKey) {
      final problem = _verifyRecordedOutputs(previous, owned);
      lap('verify');
      if (problem == null) {
        return IncrementalOutcome(
          success: true,
          diagnostics: previous.diagnostics,
          files: {
            if (_writes) ...{
              'created': const [],
              'updated': const [],
              'unchanged': previous.outputs.keys.toList(),
              'removed': const [],
            } else ...{
              'missing': const [],
              'outdated': const [],
              'upToDate': previous.outputs.keys.toList(),
              'stale': const [],
              'conflicts': const [],
            },
          },
          explanations: [
            for (final path in previous.outputs.keys)
              OutputExplanation(path, _writes ? 'unchanged' : 'up-to-date', [
                'inputs unchanged; output verified',
              ]),
          ],
          cacheStatus: 'hit: inputs unchanged, outputs verified',
          timings: timings,
          outputCount: previous.outputs.length,
        );
      }
      cacheStatus = 'miss: $problem';
    } else if (previous != null) {
      cacheStatus = 'miss: inputs changed';
    }

    // 4. Engine (full validation), formatting memoized.
    final memo = generator == null
        ? null
        : cache.memo(
            generator,
            readOnly: !_writes,
            ignoreExisting: mode == CacheMode.clean,
          );
    final result = GqlifyEngine().generate(input, memo: memo);
    for (final MapEntry(:key, :value) in result.timings.entries) {
      timings['engine.$key'] = value;
    }
    lap('engine');
    if (result.hasErrors) {
      // The manifest still describes the last *successful* state, whose
      // input key differs from the current one, so it can never cause a hit.
      return fail(result.diagnostics, cacheStatus);
    }

    // 5. Reconcile outputs.
    final plan = OutputPlan.compute(project, result.outputs);
    lap('plan');
    final explanations = _explain(
      previous,
      result,
      plan,
      inputs,
      input.config.schema,
      configDigest,
      input.format.fingerprint,
      cacheStatus,
    );
    if (!_writes) {
      return IncrementalOutcome(
        success: plan.isUpToDate,
        diagnostics: result.diagnostics,
        files: {
          'missing': plan.created,
          'outdated': plan.changed,
          'upToDate': plan.unchanged,
          'stale': plan.stale,
          'conflicts': plan.conflicts,
        },
        explanations: explanations,
        cacheStatus: cacheStatus,
        timings: timings,
        plan: plan,
        outputCount: result.outputs.length,
      );
    }
    if (plan.conflicts.isNotEmpty) {
      return IncrementalOutcome(
        success: false,
        diagnostics: [
          ...result.diagnostics,
          for (final path in plan.conflicts)
            Diagnostic(
              severity: Severity.error,
              code: 'output-conflict',
              message:
                  'File exists and was not generated by gqlify; refusing to overwrite it.',
              path: path,
            ),
        ],
        files: {'conflicts': plan.conflicts},
        explanations: explanations,
        cacheStatus: cacheStatus,
        timings: timings,
        plan: plan,
      );
    }

    try {
      if (!plan.isUpToDate ||
          previous == null ||
          previous.inputKey != inputKey) {
        cache.invalidate();
      }
      plan.apply(project, result.outputs, io: io);
      lap('write');
      final mismatch = _verifyWritten(result.outputs);
      if (mismatch != null) {
        return fail([
          ...result.diagnostics,
          Diagnostic(
            severity: Severity.error,
            code: 'write-verification-failed',
            message:
                '$mismatch does not contain the generated content after writing.',
            path: mismatch,
          ),
        ], cacheStatus);
      }
      lap('verify');
      if (generator != null) {
        cache.writeManifest(
          Manifest(
            generator: generator,
            inputKey: inputKey,
            configDigest: configDigest,
            formatFingerprint: input.format.fingerprint,
            inputs: inputs,
            outputs: {
              for (final MapEntry(:key, :value) in result.outputs.entries)
                key: OutputRecord(
                  sha256: sha256Text(value),
                  dependencies: result.dependencies[key] ?? const [],
                ),
            },
            diagnostics: result.diagnostics,
          ),
        );
        cache.pruneArtifacts(memo!);
      }
      lap('cache');
    } on FileSystemException catch (e) {
      return fail([
        ...result.diagnostics,
        Diagnostic(
          severity: Severity.error,
          code: 'write-failed',
          message:
              '${e.message}${e.osError == null ? '' : ' (${e.osError!.message})'}. '
              'Outputs may be partially updated; the next run will repair them.',
          path: e.path == null ? null : project.relative(e.path!),
        ),
      ], cacheStatus);
    }

    return IncrementalOutcome(
      success: true,
      diagnostics: result.diagnostics,
      files: {
        'created': plan.created,
        'updated': plan.changed,
        'unchanged': plan.unchanged,
        'removed': plan.stale,
      },
      explanations: explanations,
      cacheStatus: cacheStatus,
      timings: timings,
      plan: plan,
      outputCount: result.outputs.length,
    );
  }

  /// `null` if every recorded output exists with the recorded digest and no
  /// other gqlify output exists; otherwise the first problem found.
  String? _verifyRecordedOutputs(Manifest manifest, List<String> owned) {
    for (final MapEntry(key: path, value: record) in manifest.outputs.entries) {
      final file = File(project.absolute(path));
      if (!file.existsSync()) return 'output missing: $path';
      if (sha256Hex(file.readAsBytesSync()) != record.sha256) {
        return 'output modified on disk: $path';
      }
    }
    for (final path in owned) {
      if (!manifest.outputs.containsKey(path)) {
        return 'unexpected generated file: $path';
      }
    }
    return null;
  }

  /// Re-reads written outputs; returns the first path that does not match.
  String? _verifyWritten(Map<String, String> outputs) {
    for (final MapEntry(key: path, value: content) in outputs.entries) {
      final file = File(project.absolute(path));
      if (!file.existsSync() ||
          sha256Hex(file.readAsBytesSync()) != sha256Text(content)) {
        return path;
      }
    }
    return null;
  }

  List<OutputExplanation> _explain(
    Manifest? previous,
    GenerationResult result,
    OutputPlan plan,
    Map<String, String> inputs,
    List<String> schemaPaths,
    String configDigest,
    String formatFingerprint,
    String cacheStatus,
  ) {
    final schemaOutputPath = '${schemaPaths.first}.dart';
    final schemaChanged =
        previous != null &&
        schemaPaths.any((s) => previous.inputs[s] != inputs[s]);
    final global = <String>[
      if (previous == null) cacheStatus,
      if (previous != null && previous.configDigest != configDigest)
        'configuration changed',
      if (previous != null && previous.formatFingerprint != formatFingerprint)
        'format settings changed',
      if (schemaChanged) 'schema changed',
    ];
    String status(String path) => _writes
        ? (plan.created.contains(path)
              ? 'created'
              : plan.changed.contains(path)
              ? 'updated'
              : plan.conflicts.contains(path)
              ? 'conflict'
              : 'unchanged')
        : (plan.created.contains(path)
              ? 'missing'
              : plan.changed.contains(path)
              ? 'outdated'
              : plan.conflicts.contains(path)
              ? 'conflict'
              : 'up-to-date');

    final explanations = <OutputExplanation>[];
    for (final path in result.outputs.keys) {
      final reasons = [...global];
      final record = previous?.outputs[path];
      final deps = result.dependencies[path] ?? const <String>[];
      if (previous != null && record == null) reasons.add('new output');
      if (record != null) {
        final file = File(project.absolute(path));
        if (!file.existsSync()) {
          reasons.add('output missing on disk');
        } else if (plan.changed.contains(path) ||
            plan.unchanged.contains(path)) {
          final onDisk = sha256Hex(file.readAsBytesSync());
          if (onDisk != record.sha256 && plan.changed.contains(path)) {
            reasons.add('output modified on disk');
          }
        }
        final source = path.substring(0, path.length - '.dart'.length);
        for (final dep in {...deps, ...record.dependencies}) {
          final before = previous!.inputs[dep];
          final now = inputs[dep];
          if (before == now) continue;
          final what = now == null
              ? 'deleted'
              : before == null
              ? 'added'
              : 'changed';
          reasons.add(
            dep == source
                ? 'document $what'
                : path == schemaOutputPath
                ? 'operation document $what: $dep (it may change which schema types are used)'
                : 'transitive fragment document $what: $dep',
          );
        }
        if (reasons.isEmpty) reasons.add('dependencies unchanged');
      }
      explanations.add(
        OutputExplanation(
          path,
          status(path),
          reasons,
          formatCached: result.formatMemoized
              ? result.formatCached.contains(path)
              : null,
        ),
      );
    }
    for (final path in plan.stale) {
      explanations.add(
        OutputExplanation(path, _writes ? 'removed' : 'stale', [
          'no longer generated (source deleted, mode changed or no definitions)',
        ]),
      );
    }
    return explanations;
  }
}
