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

/// JSON representation of a custom scalar on the wire.
enum ScalarJsonType {
  string('String', 'String'),
  int_('int', 'int'),
  double_('double', 'num'),
  num_('num', 'num'),
  bool_('bool', 'bool'),
  map('Map', 'Map<String, Object?>'),
  list('List', 'List<Object?>'),
  object('Object', 'Object');

  const ScalarJsonType(this.yamlName, this.readType);

  final String yamlName;

  /// Dart type the raw JSON value is checked against before conversion.
  final String readType;
}

/// How a custom scalar is represented in Dart and converted from/to JSON.
///
/// ```yaml
/// scalars:
///   DateTime:
///     type: DateTime
///     json_type: String
///     from_json: DateTime.parse
///     to_json: encodeDateTime        # optional
///     import: package:app/scalars.dart  # optional
/// ```
final class ScalarConfig {
  const ScalarConfig({
    required this.type,
    this.jsonType = ScalarJsonType.object,
    this.fromJson,
    this.toJson,
    this.import,
  });

  /// Dart type of the scalar.
  final String type;
  final ScalarJsonType jsonType;

  /// Expression called with the JSON value (typed as [jsonType]) to decode
  /// it. Without it the JSON value is used as-is and must be a [type].
  final String? fromJson;

  /// Expression called with the Dart value to encode it. Without it the
  /// value is sent as-is and must be JSON-encodable.
  final String? toJson;

  /// Library providing [type], [fromJson] and [toJson], if not `dart:core`.
  final String? import;

  Map<String, Object?> toFingerprint() => {
    'type': type,
    'json_type': jsonType.yamlName,
    'from_json': fromJson,
    'to_json': toJson,
    'import': import,
  };
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
    Map<String, ScalarConfig> scalars = const {},
  }) : scalars = Map.unmodifiable(scalars),
       schema = List.unmodifiable(schema.map(normalizePath)),
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

  /// Mappings of custom scalars, by GraphQL scalar name. Unmapped custom
  /// scalars are exposed as raw JSON (`Object`).
  final Map<String, ScalarConfig> scalars;

  /// Project-relative path of the generated schema library.
  String get schemaOutputPath => '${schema.first}.dart';

  /// Canonical JSON of every setting that can change generated output.
  String get outputFingerprint => jsonEncode({
    'schema': schema,
    'mode': mode.yamlName,
    'client_name': clientName,
    'scalars': {
      for (final name in scalars.keys.toList()..sort())
        name: scalars[name]!.toFingerprint(),
    },
  });

  static const _keys = {
    'schema',
    'documents',
    'mode',
    'client_name',
    'scalars',
  };
  static const _scalarKeys = {
    'type',
    'json_type',
    'from_json',
    'to_json',
    'import',
  };

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

    final scalars = <String, ScalarConfig>{};
    final scalarsNode = map.nodes['scalars'];
    if (scalarsNode != null) {
      if (scalarsNode is! YamlMap) {
        fail('"scalars" must map scalar names to settings.', scalarsNode);
      } else {
        for (final MapEntry(key: nameNode, value: settings)
            in scalarsNode.nodes.entries) {
          final name = (nameNode as YamlNode).value;
          if (name is! String) {
            fail('Scalar names must be strings.', nameNode);
            continue;
          }
          final scalar = _parseScalar(name, settings, fail);
          if (scalar != null) scalars[name] = scalar;
        }
      }
    }

    if (failed || schema == null) return null;
    return GqlifyConfig(
      schema: schema,
      documents: documents,
      mode: mode,
      clientName: clientName,
      scalars: scalars,
    );
  }

  static ScalarConfig? _parseScalar(
    String name,
    YamlNode settings,
    void Function(String, [YamlNode?]) fail,
  ) {
    if (settings is! YamlMap) {
      fail('Scalar "$name" must be a map with at least "type".', settings);
      return null;
    }
    for (final key in settings.nodes.keys.cast<YamlNode>()) {
      if (!_scalarKeys.contains(key.value)) {
        fail(
          'Unknown setting "${key.value}" for scalar "$name". Known settings: '
          '${(_scalarKeys.toList()..sort()).join(', ')}.',
          key,
        );
      }
    }
    String? text(String key) {
      final node = settings.nodes[key];
      if (node == null) return null;
      if (node.value is String && (node.value as String).trim().isNotEmpty) {
        return (node.value as String).trim();
      }
      fail('"$key" of scalar "$name" must be a non-empty string.', node);
      return null;
    }

    final type = text('type');
    if (type == null) {
      if (settings.nodes['type'] == null) {
        fail('Scalar "$name" needs a Dart "type".', settings);
      }
      return null;
    }
    var jsonType = ScalarJsonType.object;
    final jsonTypeName = text('json_type');
    if (jsonTypeName != null) {
      final match = ScalarJsonType.values
          .where((t) => t.yamlName == jsonTypeName)
          .firstOrNull;
      if (match == null) {
        fail(
          '"json_type" of scalar "$name" must be one of: '
          '${ScalarJsonType.values.map((t) => t.yamlName).join(', ')}.',
          settings.nodes['json_type'],
        );
        return null;
      }
      jsonType = match;
    }
    return ScalarConfig(
      type: type,
      jsonType: jsonType,
      fromJson: text('from_json'),
      toJson: text('to_json'),
      import: text('import'),
    );
  }
}
