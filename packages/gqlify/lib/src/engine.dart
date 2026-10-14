import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:crypto/crypto.dart';

import 'package:dart_style/dart_style.dart';

import 'config.dart';
import 'diagnostics.dart';
import 'documents/document_set.dart';
import 'documents/typename.dart';
import 'documents/validator.dart';
import 'emit/dart_emitter.dart';
import 'emit/formatter.dart';
import 'ir/builder.dart';
import 'schema/loader.dart';
import 'source.dart';

/// Everything one generation depends on. Adapters gather it; the engine does
/// no I/O of its own.
final class GenerationInput {
  GenerationInput({
    required this.config,
    required List<GqlifySource> schema,
    required List<GqlifySource> documents,
    FormatSettings? format,
  }) : format = format ?? FormatSettings(),
       schema = List.unmodifiable(schema),
       documents = List.unmodifiable(
         <GqlifySource>[...documents]..sort((a, b) => a.path.compareTo(b.path)),
       );

  final GqlifyConfig config;

  /// Formatting of generated code; part of the output-affecting input.
  final FormatSettings format;

  /// Schema sources in configuration order.
  final List<GqlifySource> schema;

  /// Operation documents, sorted by path.
  final List<GqlifySource> documents;
}

/// The complete outcome of one generation.
final class GenerationResult {
  GenerationResult(
    Map<String, String> outputs,
    this.diagnostics, {
    Map<String, List<String>> dependencies = const {},
    this.timings = const {},
    this.formatCached = const {},
    this.formatMemoized = false,
  }) : outputs = UnmodifiableMapView(SplayTreeMap.of(outputs)),
       dependencies = UnmodifiableMapView(SplayTreeMap.of(dependencies));

  /// Generated libraries by project-relative path, sorted. Empty whenever
  /// [hasErrors]: generation is all-or-nothing.
  final Map<String, String> outputs;

  /// Sorted diagnostics.
  final List<Diagnostic> diagnostics;

  /// For each output, the operation documents its content can depend on
  /// (sorted). Every output additionally depends on the schema, the
  /// configuration, the format settings and the generator itself.
  final Map<String, List<String>> dependencies;

  /// Wall-clock time per engine phase. Informational only.
  final Map<String, Duration> timings;

  /// Outputs whose formatting was served by the [FormatMemo].
  final Set<String> formatCached;

  /// Whether a [FormatMemo] was used.
  final bool formatMemoized;

  bool get hasErrors => diagnostics.any((d) => d.isError);
}

/// Memoizes formatting, which is a pure function of the format settings and
/// the unformatted source; [key]s are SHA-256 digests of exactly those. A
/// memo can therefore never produce stale code, only skip work.
abstract interface class FormatMemo {
  String? lookup(String key);
  void store(String key, String formatted);
}

/// The deterministic gqlify generator engine.
///
/// [generate] is a pure function of its input: identical inputs produce
/// identical outputs and diagnostics. CLI and build_runner adapters both call
/// it. It never relies on a cache; an optional [FormatMemo] only avoids
/// repeated formatting.
final class GqlifyEngine {
  GqlifyEngine();

  /// Version of the memo key derivation; bump when it changes.
  static const _formatKeyVersion = 'gqlify-format-key-1';

  GenerationResult generate(GenerationInput input, {FormatMemo? memo}) {
    final run = _Run(input, memo);
    final pending = run.prepare();
    if (pending == null) return run.failed();
    final formatter = GeneratedCodeFormatter(input.format);
    for (final job in pending) {
      run.complete(job, _formatOne(formatter, job));
    }
    return run.finish();
  }

  /// Like [generate], but formats libraries on up to [concurrency] isolates.
  /// Results are identical: each library is formatted independently by the
  /// same pure function.
  ///
  /// The default is [defaultConcurrency]: isolates share one heap, and the
  /// formatter allocates heavily, so garbage collection limits scaling. On
  /// the large benchmark fixture 2 isolates were as fast as 4 in an AOT build
  /// (12.2 s vs. 12.9-14.1 s) while 4 used ten times the memory (2.7 GiB vs.
  /// 285 MiB); under JIT, 4 were 12% faster than 2. See BENCHMARKS.md.
  Future<GenerationResult> generateAsync(
    GenerationInput input, {
    FormatMemo? memo,
    int? concurrency,
  }) async {
    final run = _Run(input, memo);
    final pending = run.prepare();
    if (pending == null) return run.failed();
    final workers = min(concurrency ?? defaultConcurrency, pending.length);
    final totalSize = pending.fold(0, (n, j) => n + j.source.length);
    if (workers <= 1 || totalSize < _parallelThreshold) {
      final formatter = GeneratedCodeFormatter(input.format);
      for (final job in pending) {
        run.complete(job, _formatOne(formatter, job));
      }
      return run.finish();
    }
    // Balance buckets by source size, largest first.
    final buckets = List.generate(workers, (_) => <_Job>[]);
    final sizes = List.filled(workers, 0);
    for (final job in [
      ...pending,
    ]..sort((a, b) => b.source.length - a.source.length)) {
      var smallest = 0;
      for (var i = 1; i < workers; i++) {
        if (sizes[i] < sizes[smallest]) smallest = i;
      }
      buckets[smallest].add(job);
      sizes[smallest] += job.source.length;
    }
    final settings = input.format;
    final results = await Future.wait([
      for (final bucket in buckets)
        if (bucket.isNotEmpty)
          Isolate.run(() {
            final formatter = GeneratedCodeFormatter(settings);
            return [
              for (final job in bucket) (job, _formatOne(formatter, job)),
            ];
          }),
    ]);
    for (final (job, outcome) in results.expand((r) => r)) {
      run.complete(job, outcome);
    }
    return run.finish();
  }

  static int get defaultConcurrency => min(2, Platform.numberOfProcessors);

  /// Below this much unformatted source, isolate start-up costs more than
  /// parallel formatting saves.
  static const _parallelThreshold = 256 * 1024;

  static ({String? formatted, String? error}) _formatOne(
    GeneratedCodeFormatter formatter,
    _Job job,
  ) {
    try {
      return (
        formatted: formatter.format(job.source, path: job.path),
        error: null,
      );
    } on FormatterException catch (e) {
      return (formatted: null, error: e.message());
    }
  }
}

/// A library waiting to be formatted.
final class _Job {
  _Job(this.path, this.source, this.memoKey);

  final String path;
  final String source;
  final String? memoKey;
}

/// State of one engine run, shared by the sequential and parallel paths.
final class _Run {
  _Run(this.input, this.memo);

  final GenerationInput input;
  final FormatMemo? memo;
  final sink = DiagnosticSink();
  final timings = <String, Duration>{};
  final stopwatch = Stopwatch()..start();
  final outputs = <String, String>{};
  final cached = <String>{};
  Map<String, List<String>> dependencies = const {};

  void lap(String phase) {
    timings[phase] = stopwatch.elapsed;
    stopwatch.reset();
  }

  GenerationResult failed() =>
      GenerationResult(const {}, sink.sorted(), timings: timings);

  /// Runs everything up to formatting; returns the libraries still to
  /// format, or `null` on errors.
  List<_Job>? prepare() {
    final config = input.config;
    final schema = loadSchema(input.schema, sink);
    lap('schema');
    if (schema == null) return null;

    // Schema-only generation ignores operation documents entirely.
    final documents = DocumentSet.parse(
      config.mode.includesOperations ? input.documents : const [],
      sink,
    );
    lap('parse');
    validateDocuments(schema, documents, sink);
    lap('validate');
    if (sink.hasErrors) return null;

    final model = buildModel(
      schema,
      addTypenames(schema, documents),
      config,
      sink,
    );
    lap('model');
    if (sink.hasErrors) return null;
    dependencies = {
      for (final library in model.libraries)
        library.outputPath: library.dependencies.toList()..sort(),
    };

    final sources = emitLibraries(model);
    lap('emit');

    final pending = <_Job>[];
    for (final MapEntry(key: path, value: source) in sources.entries) {
      final key = memo == null
          ? null
          : sha256
                .convert(
                  utf8.encode(
                    '${GqlifyEngine._formatKeyVersion}\n${input.format.fingerprint}\n$source',
                  ),
                )
                .toString();
      final memoized = key == null ? null : memo!.lookup(key);
      if (memoized != null) {
        cached.add(path);
        outputs[path] = memoized;
      } else {
        pending.add(_Job(path, source, key));
      }
    }
    return pending;
  }

  void complete(_Job job, ({String? formatted, String? error}) outcome) {
    final formatted = outcome.formatted;
    if (formatted == null) {
      sink.error(
        'internal-error',
        'gqlify generated invalid Dart for ${job.path}; please report this bug.\n'
            '${outcome.error}',
        path: job.path,
      );
      return;
    }
    outputs[job.path] = formatted;
    if (job.memoKey case final key?) memo!.store(key, formatted);
  }

  GenerationResult finish() {
    lap('format');
    if (sink.hasErrors) return failed();
    return GenerationResult(
      outputs,
      sink.sorted(),
      dependencies: dependencies,
      timings: timings,
      formatCached: cached,
      formatMemoized: memo != null,
    );
  }
}
