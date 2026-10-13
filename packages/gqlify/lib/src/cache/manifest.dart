import 'dart:convert';

import '../diagnostics.dart';

/// Thrown when cache metadata is unreadable or inconsistent. The cache is
/// then ignored and rebuilt; it is never partially trusted.
final class CacheCorruptException implements Exception {
  CacheCorruptException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// A generated output as recorded after a successful run.
final class OutputRecord {
  const OutputRecord({required this.sha256, required this.dependencies});

  /// Digest of the exact bytes written.
  final String sha256;

  /// Operation documents the output depends on (besides schema/config).
  final List<String> dependencies;
}

/// Metadata of the last successful CLI generation
/// (`.dart_tool/gqlify/manifest.json`).
///
/// Written only after every output has been written and verified; deleted
/// before outputs are modified. A manifest therefore always describes a
/// complete, consistent set of outputs.
final class Manifest {
  const Manifest({
    required this.generator,
    required this.inputKey,
    required this.configDigest,
    required this.formatFingerprint,
    required this.inputs,
    required this.outputs,
    required this.diagnostics,
  });

  /// Bump whenever the manifest or artifact layout changes.
  static const formatVersion = 1;

  final String generator;

  /// Digest of every engine input; equal keys imply equal results.
  final String inputKey;
  final String configDigest;
  final String formatFingerprint;

  /// Source path to SHA-256, for schema files and documents.
  final Map<String, String> inputs;
  final Map<String, OutputRecord> outputs;

  /// Diagnostics of the run (warnings only; failed runs are not recorded).
  final List<Diagnostic> diagnostics;

  Map<String, Object?> toJson() => {
    'format': formatVersion,
    'generator': generator,
    'inputKey': inputKey,
    'configDigest': configDigest,
    'formatFingerprint': formatFingerprint,
    'inputs': inputs,
    'outputs': {
      for (final MapEntry(:key, :value) in outputs.entries)
        key: {'sha256': value.sha256, 'dependencies': value.dependencies},
    },
    'diagnostics': [for (final d in diagnostics) d.toJson()],
  };

  String encode() => const JsonEncoder.withIndent('  ').convert(toJson());

  /// Parses and strictly validates [json]; throws [CacheCorruptException].
  static Manifest decode(String json) {
    final Object? root;
    try {
      root = jsonDecode(json);
    } on FormatException catch (e) {
      throw CacheCorruptException('manifest is not valid JSON (${e.message})');
    }
    if (root is! Map<String, Object?>) {
      throw CacheCorruptException('manifest is not a JSON object');
    }
    if (root['format'] != formatVersion) {
      throw CacheCorruptException(
        'cache format ${root['format']} is not $formatVersion',
      );
    }
    String string(Object? v, String what) => v is String && v.isNotEmpty
        ? v
        : throw CacheCorruptException('manifest field $what is invalid');
    Map<String, Object?> map(Object? v, String what) =>
        v is Map<String, Object?>
        ? v
        : throw CacheCorruptException('manifest field $what is invalid');
    final digest = RegExp(r'^[0-9a-f]{64}$');
    String hash(Object? v, String what) {
      final s = string(v, what);
      if (!digest.hasMatch(s)) {
        throw CacheCorruptException('manifest field $what is not a digest');
      }
      return s;
    }

    return Manifest(
      generator: hash(root['generator'], 'generator'),
      inputKey: hash(root['inputKey'], 'inputKey'),
      configDigest: hash(root['configDigest'], 'configDigest'),
      formatFingerprint: string(root['formatFingerprint'], 'formatFingerprint'),
      inputs: {
        for (final MapEntry(:key, :value) in map(
          root['inputs'],
          'inputs',
        ).entries)
          key: hash(value, 'inputs.$key'),
      },
      outputs: {
        for (final MapEntry(:key, :value) in map(
          root['outputs'],
          'outputs',
        ).entries)
          key: () {
            final record = map(value, 'outputs.$key');
            final deps = record['dependencies'];
            if (deps is! List || deps.any((d) => d is! String)) {
              throw CacheCorruptException(
                'manifest field outputs.$key.dependencies is invalid',
              );
            }
            return OutputRecord(
              sha256: hash(record['sha256'], 'outputs.$key.sha256'),
              dependencies: deps.cast<String>(),
            );
          }(),
      },
      diagnostics: [
        for (final d
            in (root['diagnostics'] is List
                ? root['diagnostics'] as List
                : throw CacheCorruptException(
                    'manifest field diagnostics is invalid',
                  )))
          _diagnostic(d),
      ],
    );
  }

  static Diagnostic _diagnostic(Object? json) {
    if (json is! Map<String, Object?>) {
      throw CacheCorruptException('manifest diagnostic is invalid');
    }
    final severity = Severity.values
        .where((s) => s.name == json['severity'])
        .firstOrNull;
    final code = json['code'];
    final message = json['message'];
    final path = json['path'];
    final line = json['line'];
    final column = json['column'];
    if (severity == null ||
        code is! String ||
        message is! String ||
        (path != null && path is! String) ||
        (line != null && line is! int) ||
        (column != null && column is! int)) {
      throw CacheCorruptException('manifest diagnostic is invalid');
    }
    return Diagnostic(
      severity: severity,
      code: code,
      message: message,
      path: path as String?,
      line: line as int?,
      column: column as int?,
    );
  }
}
