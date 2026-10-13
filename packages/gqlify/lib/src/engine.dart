import 'dart:collection';
import 'dart:convert';

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
    final sink = DiagnosticSink();
    final config = input.config;
    final timings = <String, Duration>{};
    final stopwatch = Stopwatch()..start();
    void lap(String phase) {
      timings[phase] = stopwatch.elapsed;
      stopwatch.reset();
    }

    GenerationResult failed() =>
        GenerationResult(const {}, sink.sorted(), timings: timings);

    final schema = loadSchema(input.schema, sink);
    lap('schema');
    if (schema == null) return failed();

    // Schema-only generation ignores operation documents entirely.
    final documents = DocumentSet.parse(
      config.mode.includesOperations ? input.documents : const [],
      sink,
    );
    lap('parse');
    validateDocuments(schema, documents, sink);
    lap('validate');
    if (sink.hasErrors) return failed();

    final model = buildModel(
      schema,
      addTypenames(schema, documents),
      config,
      sink,
    );
    lap('model');
    if (sink.hasErrors) return failed();

    final sources = emitLibraries(model);
    lap('emit');

    final formatter = GeneratedCodeFormatter(input.format);
    final outputs = <String, String>{};
    final cached = <String>{};
    for (final MapEntry(key: path, value: source) in sources.entries) {
      final key = memo == null
          ? null
          : sha256
                .convert(
                  utf8.encode(
                    '$_formatKeyVersion\n${input.format.fingerprint}\n$source',
                  ),
                )
                .toString();
      final memoized = key == null ? null : memo!.lookup(key);
      if (memoized != null) {
        cached.add(path);
        outputs[path] = memoized;
        continue;
      }
      try {
        final formatted = formatter.format(source, path: path);
        outputs[path] = formatted;
        if (key != null) memo!.store(key, formatted);
      } on FormatterException catch (e) {
        sink.error(
          'internal-error',
          'gqlify generated invalid Dart for $path; please report this bug.\n'
              '${e.message()}',
          path: path,
        );
      }
    }
    lap('format');
    if (sink.hasErrors) return failed();
    return GenerationResult(
      outputs,
      sink.sorted(),
      dependencies: {
        for (final library in model.libraries)
          library.outputPath: library.dependencies.toList()..sort(),
      },
      timings: timings,
      formatCached: cached,
      formatMemoized: memo != null,
    );
  }
}
