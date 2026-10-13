import 'dart:collection';

import 'package:dart_style/dart_style.dart';

import 'config.dart';
import 'diagnostics.dart';
import 'documents/document_set.dart';
import 'documents/validator.dart';
import 'emit/dart_emitter.dart';
import 'emit/formatter.dart';
import 'ir/builder.dart';
import 'schema/sdl_builder.dart';
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
  GenerationResult(Map<String, String> outputs, this.diagnostics)
    : outputs = UnmodifiableMapView(SplayTreeMap.of(outputs));

  /// Generated libraries by project-relative path, sorted. Empty whenever
  /// [hasErrors]: generation is all-or-nothing.
  final Map<String, String> outputs;

  /// Sorted diagnostics.
  final List<Diagnostic> diagnostics;

  bool get hasErrors => diagnostics.any((d) => d.isError);
}

/// The deterministic gqlify generator engine.
///
/// [generate] is a pure function of its input: identical inputs produce
/// identical outputs and diagnostics. CLI and build_runner adapters both call
/// it, and it never relies on a cache.
final class GqlifyEngine {
  GqlifyEngine();

  GenerationResult generate(GenerationInput input) {
    final sink = DiagnosticSink();
    final config = input.config;

    if (config.mode != GenerationMode.operations) {
      sink.error(
        'unsupported-feature',
        'mode "${config.mode.yamlName}" is not supported by this version of '
            'gqlify yet; use "operations".',
        path: GqlifyConfig.fileName,
      );
      return GenerationResult(const {}, sink.sorted());
    }

    final schema = buildSchemaFromSdl(input.schema, sink);
    if (schema == null) return GenerationResult(const {}, sink.sorted());

    final documents = DocumentSet.parse(input.documents, sink);
    validateDocuments(schema, documents, sink);
    if (sink.hasErrors) return GenerationResult(const {}, sink.sorted());

    final model = buildModel(schema, documents, config, sink);
    if (sink.hasErrors) return GenerationResult(const {}, sink.sorted());

    final formatter = GeneratedCodeFormatter(input.format);
    final outputs = <String, String>{};
    for (final MapEntry(key: path, value: source) in emitLibraries(
      model,
    ).entries) {
      try {
        outputs[path] = formatter.format(source, path: path);
      } on FormatterException catch (e) {
        sink.error(
          'internal-error',
          'gqlify generated invalid Dart for $path; please report this bug.\n'
              '${e.message()}',
          path: path,
        );
      }
    }
    if (sink.hasErrors) return GenerationResult(const {}, sink.sorted());
    return GenerationResult(outputs, sink.sorted());
  }
}
