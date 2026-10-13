import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:build/build.dart';
import 'package:glob/glob.dart';

import '../cache/fingerprint.dart';
import '../config.dart';
import '../diagnostics.dart';
import '../emit/formatter.dart';
import '../engine.dart';
import '../source.dart';

/// `build_runner` adapter: one build step per `.graphql`/`.gql`/`.json`
/// input, each writing at most the library generated for that input
/// (`<input>.dart`).
///
/// Every step reads *all* inputs that can affect generation through the
/// [BuildStep] (configuration, schema, every document found by the
/// configured globs, format settings), so build_runner tracks them as
/// dependencies; nothing is read behind its back. The engine is invoked once
/// per distinct input set per build (shared through a [Resource]); outputs
/// are byte-identical to the CLI's because both call the same engine with
/// the same [GenerationInput].
///
/// No persistent cache is kept: build_runner owns incrementality in
/// `.dart_tool/build/`. A bounded in-memory formatting memo (a pure-function
/// memo, see [FormatMemo]) only speeds up `watch`.
final class GqlifyBuilder implements Builder {
  GqlifyBuilder();

  @override
  final buildExtensions = const {
    '.graphql': ['.graphql.dart'],
    '.gql': ['.gql.dart'],
    '.json': ['.json.dart'],
  };

  static final _results = Resource<Map<String, Future<GenerationResult>>>(
    () => {},
    dispose: (results) => results.clear(),
  );

  static final _memo = _InMemoryFormatMemo(maxEntries: 2000);
  static var _warnedInactive = false;

  @override
  Future<void> build(BuildStep step) async {
    final package = step.inputId.package;
    final inputPath = step.inputId.path;

    // Configuration: gqlify.yaml (if visible to the build) or pubspec.yaml.
    final sink = DiagnosticSink();
    final gqlifyYaml = await _readOptional(step, GqlifyConfig.fileName);
    final pubspec = await _readOptional(step, 'pubspec.yaml');
    if (gqlifyYaml == null && !_hasGqlifySection(pubspec)) {
      // No configuration visible to the build: the builder is inactive, so
      // CLI-only users can run build_runner for other generators.
      if (!_warnedInactive && File(GqlifyConfig.fileName).existsSync()) {
        _warnedInactive = true;
        log.warning(
          'The gqlify builder is inactive: ${GqlifyConfig.fileName} is not '
          'visible to build_runner. Keep using `dart run gqlify generate`, or, '
          'to generate with build_runner, move the settings into a "gqlify:" '
          'section of pubspec.yaml or add the file to the target sources in '
          'build.yaml:\n$_sourcesHint',
        );
      }
      return;
    }
    final resolved = resolveConfig(
      gqlifyYaml: gqlifyYaml,
      pubspecYaml: pubspec,
      sink: sink,
    );
    if (resolved == null) {
      _report(sink.sorted(), owned: (_) => true);
      return;
    }
    final config = resolved.config;
    final schemaOwner = config.schema.first;

    // Documents, exactly as the CLI discovers them.
    final documentPaths = SplayTreeSet<String>();
    if (config.mode.includesOperations) {
      for (final pattern in config.documents) {
        await for (final id in step.findAssets(Glob(pattern))) {
          final path = id.path;
          if (!config.schema.contains(path) && !_isHidden(path)) {
            documentPaths.add(path);
          }
        }
      }
    }
    if (inputPath != schemaOwner && !documentPaths.contains(inputPath)) return;

    final schema = <GqlifySource>[];
    for (final path in config.schema) {
      final content = await _readOptional(step, path);
      if (content == null) {
        sink.error(
          'missing-schema',
          'Schema file "$path" does not exist or is not visible to build_runner.',
          path: GqlifyConfig.fileName,
        );
        continue;
      }
      schema.add(GqlifySource(path, content));
    }
    if (sink.hasErrors) {
      _report(sink.sorted(), owned: (d) => inputPath == schemaOwner);
      return;
    }
    final documents = [
      for (final path in documentPaths)
        GqlifySource(path, await step.readAsString(AssetId(package, path))),
    ];

    // Format settings, as the CLI derives them.
    final analysisOptions = await _readOptional(step, 'analysis_options.yaml');
    if (analysisOptions == null && _hasFormatterSettingsOnDisk()) {
      log.severe(
        'analysis_options.yaml has formatter settings but is not visible to '
        'build_runner, so generated code would be formatted differently from '
        '`dart format` and the gqlify CLI. Add it to the target sources in '
        'build.yaml:\n$_sourcesHint',
      );
      return;
    }
    final input = GenerationInput(
      config: config,
      schema: schema,
      documents: documents,
      format: FormatSettings.fromProjectFiles(
        pubspecYaml: pubspec,
        analysisOptionsYaml: analysisOptions,
      ),
    );

    final key = sha256Text(
      jsonEncode({
        'config': resolved.digestSource,
        'format': input.format.fingerprint,
        'schema': [
          for (final s in schema) [s.path, s.content],
        ],
        'documents': [
          for (final d in documents) [d.path, d.content],
        ],
      }),
    );
    final results = await step.fetchResource(_results);
    final result = await results.putIfAbsent(
      key,
      () => Future.sync(() => GqlifyEngine().generate(input, memo: _memo)),
    );

    // Each diagnostic is reported by exactly one step: the one whose input
    // it is located in; diagnostics without such a step go to the schema's.
    bool owned(Diagnostic d) {
      final path = d.path;
      if (path == inputPath) return true;
      if (inputPath != schemaOwner) return false;
      return path == null || !documentPaths.contains(path);
    }

    _report(result.diagnostics, owned: owned);
    if (result.hasErrors) {
      if (!result.diagnostics.any((d) => d.isError && owned(d)) &&
          inputPath == schemaOwner) {
        log.severe('Generation failed; see errors reported for other files.');
      }
      return;
    }
    final output = result.outputs['$inputPath.dart'];
    if (output != null) {
      await step.writeAsString(step.inputId.addExtension('.dart'), output);
    }
  }

  static void _report(
    List<Diagnostic> diagnostics, {
    required bool Function(Diagnostic) owned,
  }) {
    for (final d in diagnostics) {
      if (!owned(d)) continue;
      switch (d.severity) {
        case Severity.error:
          log.severe(d.toString());
        case Severity.warning:
          log.warning(d.toString());
        case Severity.info:
          log.info(d.toString());
      }
    }
  }

  static Future<String?> _readOptional(BuildStep step, String path) async {
    final id = AssetId(step.inputId.package, path);
    return await step.canRead(id) ? step.readAsString(id) : null;
  }

  static bool _hasGqlifySection(String? pubspec) =>
      pubspec != null &&
      RegExp(r'^gqlify\s*:', multiLine: true).hasMatch(pubspec);

  /// Only used to refuse silently diverging from the CLI, never as an input:
  /// build_runner runs builders with the package root as working directory.
  static bool _hasFormatterSettingsOnDisk() {
    final file = File('analysis_options.yaml');
    return file.existsSync() &&
        RegExp(
          r'^formatter\s*:',
          multiLine: true,
        ).hasMatch(file.readAsStringSync());
  }

  static bool _isHidden(String path) =>
      path.split('/').any((s) => s.startsWith('.'));

  static const _sourcesHint = '''
targets:
  \$default:
    sources:
      include:
        - \$package\$
        - lib/**
        - pubspec.yaml
        - gqlify.yaml
        - analysis_options.yaml''';
}

/// A bounded, process-wide memo of formatting results. Formatting is a pure
/// function of the memo key (see [FormatMemo]), so sharing results across
/// builds cannot affect outputs, only time.
final class _InMemoryFormatMemo implements FormatMemo {
  _InMemoryFormatMemo({required this.maxEntries});

  final int maxEntries;
  final _entries = <String, String>{};

  @override
  String? lookup(String key) {
    final value = _entries.remove(key);
    if (value != null) _entries[key] = value; // Most recently used last.
    return value;
  }

  @override
  void store(String key, String formatted) {
    _entries[key] = formatted;
    while (_entries.length > maxEntries) {
      _entries.remove(_entries.keys.first);
    }
  }
}
