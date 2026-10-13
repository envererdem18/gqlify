import 'dart:convert';

import 'package:gql/ast.dart' as ast;
import 'package:gql/language.dart' as lang;
import 'package:source_span/source_span.dart';

import '../diagnostics.dart';

/// Converts an introspection result (`{"data": {"__schema": ...}}` or
/// `{"__schema": ...}`) to an SDL document, so that both inputs share one
/// schema builder and one set of schema validation rules.
///
/// Returns `null` and reports to [sink] if the JSON is not an introspection
/// result.
ast.DocumentNode? introspectionToSdl(
  String json,
  String path,
  DiagnosticSink sink,
) {
  void fail(String message) =>
      sink.error('invalid-introspection', message, path: path);

  final Object? decoded;
  try {
    decoded = jsonDecode(json);
  } on FormatException catch (e) {
    fail('Invalid JSON: ${e.message}');
    return null;
  }
  Object? schema = decoded is Map ? decoded['__schema'] : null;
  if (schema == null && decoded is Map && decoded['data'] is Map) {
    schema = (decoded['data'] as Map)['__schema'];
  }
  if (schema is! Map) {
    fail('Expected an introspection result with a "__schema" object.');
    return null;
  }
  try {
    return _Converter(schema).document();
  } on _IntrospectionError catch (e) {
    fail(e.message);
    return null;
  }
}

final class _IntrospectionError implements Exception {
  _IntrospectionError(this.message);

  final String message;
}

final class _Converter {
  _Converter(this.schema);

  final Map<Object?, Object?> schema;

  static const _builtInDirectives = {
    'skip',
    'include',
    'deprecated',
    'specifiedBy',
    'oneOf',
  };

  ast.DocumentNode document() {
    final definitions = <ast.DefinitionNode>[];
    final roots = <ast.OperationTypeDefinitionNode>[
      for (final (key, operation) in [
        ('queryType', ast.OperationType.query),
        ('mutationType', ast.OperationType.mutation),
        ('subscriptionType', ast.OperationType.subscription),
      ])
        if (_map(schema[key])?['name'] case final String name)
          ast.OperationTypeDefinitionNode(
            operation: operation,
            type: ast.NamedTypeNode(name: _name(name)),
          ),
    ];
    definitions.add(ast.SchemaDefinitionNode(operationTypes: roots));

    for (final type in _list(schema['types'], 'types')) {
      final def = _type(
        _map(type) ?? (throw _IntrospectionError('Malformed type: $type')),
      );
      if (def != null) definitions.add(def);
    }
    for (final d in _list(schema['directives'] ?? const [], 'directives')) {
      final directive = _map(d)!;
      final name = _string(directive['name'], 'directive name');
      if (_builtInDirectives.contains(name)) continue;
      definitions.add(
        ast.DirectiveDefinitionNode(
          name: _name(name),
          description: _description(directive),
          args: _inputValues(directive['args'] ?? const []),
          locations: [
            for (final l in _list(directive['locations'], 'locations'))
              _location(_string(l, 'directive location')),
          ],
          repeatable: directive['isRepeatable'] == true,
        ),
      );
    }
    return ast.DocumentNode(definitions: definitions);
  }

  ast.TypeDefinitionNode? _type(Map<Object?, Object?> type) {
    final name = _string(type['name'], 'type name');
    if (name.startsWith('__')) return null; // Introspection types.
    final description = _description(type);
    switch (type['kind']) {
      case 'SCALAR':
        return ast.ScalarTypeDefinitionNode(
          name: _name(name),
          description: description,
        );
      case 'OBJECT':
        return ast.ObjectTypeDefinitionNode(
          name: _name(name),
          description: description,
          interfaces: _namedTypes(type['interfaces'] ?? const []),
          fields: _fields(type['fields']),
        );
      case 'INTERFACE':
        return ast.InterfaceTypeDefinitionNode(
          name: _name(name),
          description: description,
          interfaces: _namedTypes(type['interfaces'] ?? const []),
          fields: _fields(type['fields']),
        );
      case 'UNION':
        return ast.UnionTypeDefinitionNode(
          name: _name(name),
          description: description,
          types: _namedTypes(type['possibleTypes']),
        );
      case 'ENUM':
        return ast.EnumTypeDefinitionNode(
          name: _name(name),
          description: description,
          values: [
            for (final v in _list(type['enumValues'], 'enumValues'))
              ast.EnumValueDefinitionNode(
                name: _name(_string(_map(v)!['name'], 'enum value')),
                description: _description(_map(v)!),
                directives: _deprecated(_map(v)!),
              ),
          ],
        );
      case 'INPUT_OBJECT':
        return ast.InputObjectTypeDefinitionNode(
          name: _name(name),
          description: description,
          fields: _inputValues(type['inputFields']),
          directives: [
            if (type['isOneOf'] == true)
              ast.DirectiveNode(name: _name('oneOf')),
          ],
        );
      default:
        throw _IntrospectionError(
          'Unknown kind ${type['kind']} of type "$name".',
        );
    }
  }

  List<ast.FieldDefinitionNode> _fields(Object? fields) => [
    for (final f in _list(fields, 'fields'))
      ast.FieldDefinitionNode(
        name: _name(_string(_map(f)!['name'], 'field name')),
        description: _description(_map(f)!),
        type: _typeRef(_map(f)!['type']),
        args: _inputValues(_map(f)!['args'] ?? const []),
        directives: _deprecated(_map(f)!),
      ),
  ];

  List<ast.InputValueDefinitionNode> _inputValues(Object? values) => [
    for (final v in _list(values, 'input values'))
      ast.InputValueDefinitionNode(
        name: _name(_string(_map(v)!['name'], 'argument name')),
        description: _description(_map(v)!),
        type: _typeRef(_map(v)!['type']),
        defaultValue: switch (_map(v)!['defaultValue']) {
          final String literal => _parseValue(literal),
          _ => null,
        },
        directives: _deprecated(_map(v)!),
      ),
  ];

  ast.TypeNode _typeRef(Object? ref, {bool nonNull = false}) {
    final map =
        _map(ref) ??
        (throw _IntrospectionError('Malformed type reference: $ref'));
    return switch (map['kind']) {
      'NON_NULL' => _typeRef(map['ofType'], nonNull: true),
      'LIST' => ast.ListTypeNode(
        type: _typeRef(map['ofType']),
        isNonNull: nonNull,
      ),
      _ => ast.NamedTypeNode(
        name: _name(_string(map['name'], 'type reference name')),
        isNonNull: nonNull,
      ),
    };
  }

  List<ast.NamedTypeNode> _namedTypes(Object? refs) => [
    for (final r in _list(refs, 'type references'))
      ast.NamedTypeNode(name: _name(_string(_map(r)!['name'], 'type name'))),
  ];

  List<ast.DirectiveNode> _deprecated(Map<Object?, Object?> node) => [
    if (node['isDeprecated'] == true)
      ast.DirectiveNode(
        name: _name('deprecated'),
        arguments: [
          if (node['deprecationReason'] case final String reason)
            ast.ArgumentNode(
              name: _name('reason'),
              value: ast.StringValueNode(value: reason, isBlock: false),
            ),
        ],
      ),
  ];

  static ast.ValueNode _parseValue(String literal) {
    try {
      final doc = lang.parseString('query(\$v: Int = $literal) { a }');
      final op = doc.definitions.single as ast.OperationDefinitionNode;
      return op.variableDefinitions.single.defaultValue!.value!;
    } on SourceSpanException {
      throw _IntrospectionError('Invalid default value literal: $literal');
    }
  }

  static ast.DirectiveLocation _location(String name) {
    final camel = name.toLowerCase().replaceAllMapped(
      RegExp('_([a-z])'),
      (m) => m[1]!.toUpperCase(),
    );
    final normalized = camel == 'enum' ? 'enumDefinition' : camel;
    return ast.DirectiveLocation.values.firstWhere(
      (l) => l.name == normalized,
      orElse: () =>
          throw _IntrospectionError('Unknown directive location $name.'),
    );
  }

  static ast.StringValueNode? _description(Map<Object?, Object?> node) =>
      switch (node['description']) {
        final String d when d.isNotEmpty => ast.StringValueNode(
          value: d,
          isBlock: true,
        ),
        _ => null,
      };

  static ast.NameNode _name(String value) => ast.NameNode(value: value);

  static Map<Object?, Object?>? _map(Object? value) =>
      value is Map ? value.cast<Object?, Object?>() : null;

  static List<Object?> _list(Object? value, String what) => value is List
      ? value
      : throw _IntrospectionError('Expected a list of $what, got $value.');

  static String _string(Object? value, String what) => value is String
      ? value
      : throw _IntrospectionError('Expected a string $what, got $value.');
}
