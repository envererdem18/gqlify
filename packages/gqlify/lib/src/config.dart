import 'dart:convert';

import 'package:yaml/yaml.dart';

import 'diagnostics.dart';
import 'source.dart';

/// What the engine generates.
enum GenerationMode {
  /// Operation types, client methods and the schema types they need.
  operations('operations'),

  /// Reusable schema types only; operation documents are ignored.
  schemaOnly('schema_only'),

  /// Every schema type plus everything from [operations].
  both('both');

  const GenerationMode(this.yamlName);

  final String yamlName;

  bool get includesOperations => this != schemaOnly;
  bool get includesAllSchemaTypes => this != operations;
}

/// Configuration read from `gqlify.yaml`.
///
/// Discovery settings ([schema], [documents]) are used by adapters; the rest
/// affects generated output and is part of [outputFingerprint].
final class GqlifyConfig {
  GqlifyConfig({
    required List<String> schema,
    List<String>? documents,
    this.mode = GenerationMode.operations,
    this.clientName = 'GqlifyClient',
  }) : schema = List.unmodifiable(schema.map(normalizePath)),
       documents = List.unmodifiable(documents ?? defaultDocuments);

  static const fileName = 'gqlify.yaml';
  static const defaultDocuments = ['lib/**.graphql', 'lib/**.gql'];

  /// Schema files (SDL). Order is significant for type extensions.
  final List<String> schema;

  /// Glob patterns of operation documents, relative to the package root.
  /// Files that are also listed in [schema] are never treated as documents.
  final List<String> documents;

  final GenerationMode mode;

  /// Name of the generated client class.
  final String clientName;

  /// Project-relative path of the generated schema library.
  String get schemaOutputPath => '${schema.first}.dart';

  /// Canonical JSON of every setting that can change generated output.
  String get outputFingerprint => jsonEncode({
    'schema': schema,
    'mode': mode.yamlName,
    'client_name': clientName,
  });

  static const _keys = {'schema', 'documents', 'mode', 'client_name'};

  /// Parses `gqlify.yaml` content. Problems are reported to [sink]; returns
  /// `null` if the configuration is unusable.
  static GqlifyConfig? parse(
    String yaml,
    DiagnosticSink sink, {
    String path = fileName,
  }) {
    var failed = false;
    void fail(String message, [YamlNode? node]) {
      failed = true;
      sink.add(
        Diagnostic.error(
          'invalid-config',
          message,
          path: path,
          span: node?.span,
        ),
      );
    }

    final Object? root;
    try {
      root = loadYamlNode(yaml, sourceUrl: Uri.file(path));
    } on YamlException catch (e) {
      sink.add(Diagnostic.error('invalid-config', e.message, path: path));
      return null;
    }
    if (root is! YamlMap) {
      fail('Expected a map of settings.');
      return null;
    }
    final map = root;

    for (final key in map.nodes.keys.cast<YamlNode>()) {
      if (!_keys.contains(key.value)) {
        fail(
          'Unknown setting "${key.value}". Known settings: '
          '${(_keys.toList()..sort()).join(', ')}.',
          key,
        );
      }
    }

    List<String>? stringList(String key) {
      final node = map.nodes[key];
      if (node == null) return null;
      final value = node.value;
      if (value is String) return [value];
      if (value is YamlList &&
          value.isNotEmpty &&
          value.every((e) => e is String)) {
        return value.cast<String>().toList();
      }
      fail('"$key" must be a path or a non-empty list of paths.', node);
      return null;
    }

    final schema = stringList('schema');
    if (schema == null && map.nodes['schema'] == null) {
      fail('Missing required setting "schema".');
    }
    final documents = stringList('documents');

    var mode = GenerationMode.operations;
    final modeNode = map.nodes['mode'];
    if (modeNode != null) {
      final match = GenerationMode.values
          .where((m) => m.yamlName == modeNode.value)
          .firstOrNull;
      if (match == null) {
        fail(
          '"mode" must be one of: '
          '${GenerationMode.values.map((m) => m.yamlName).join(', ')}.',
          modeNode,
        );
      } else {
        mode = match;
      }
    }

    var clientName = 'GqlifyClient';
    final clientNode = map.nodes['client_name'];
    if (clientNode != null) {
      final value = clientNode.value;
      if (value is String && RegExp(r'^[A-Z][A-Za-z0-9]*$').hasMatch(value)) {
        clientName = value;
      } else {
        fail(
          '"client_name" must be an UpperCamelCase Dart identifier.',
          clientNode,
        );
      }
    }

    if (failed || schema == null) return null;
    return GqlifyConfig(
      schema: schema,
      documents: documents,
      mode: mode,
      clientName: clientName,
    );
  }
}
