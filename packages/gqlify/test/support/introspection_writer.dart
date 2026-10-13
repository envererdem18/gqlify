import 'package:gql/ast.dart' as ast;
import 'package:gqlify/src/documents/printer.dart';
import 'package:gqlify/src/schema/schema.dart';
import 'package:gqlify/src/schema/type_ref.dart';

/// Renders [schema] as a standard introspection result
/// (`{"data": {"__schema": ...}}`), like a server would return it.
Map<String, Object?> introspectionOf(Schema schema) {
  Map<String, Object?> ref(TypeRef type) => switch (type) {
    _ when type.isNonNull => {
      'kind': 'NON_NULL',
      'name': null,
      'ofType': ref(type.nullable),
    },
    ListTypeRef(:final ofType) => {
      'kind': 'LIST',
      'name': null,
      'ofType': ref(ofType),
    },
    NamedTypeRef(:final name) => {
      'kind': _kind(schema[name]!),
      'name': name,
      'ofType': null,
    },
  };
  Map<String, Object?> inputValue(InputValueDef v) => {
    'name': v.name,
    'description': v.description,
    'type': ref(v.type),
    'defaultValue': v.defaultValue == null
        ? null
        : printExecutable(v.defaultValue!),
    'isDeprecated': v.deprecationReason != null,
    'deprecationReason': v.deprecationReason,
  };
  List<Map<String, Object?>> named(Iterable<String> names) => [
    for (final n in names)
      {'kind': _kind(schema[n]!), 'name': n, 'ofType': null},
  ];

  return {
    'data': {
      '__schema': {
        'queryType': {'name': schema.queryType},
        'mutationType': schema.mutationType == null
            ? null
            : {'name': schema.mutationType},
        'subscriptionType': schema.subscriptionType == null
            ? null
            : {'name': schema.subscriptionType},
        'types': [
          for (final type in schema.types.values)
            {
              'kind': _kind(type),
              'name': type.name,
              'description': type.description,
              'fields': type is FieldsType
                  ? [
                      for (final f in type.fields.values)
                        {
                          'name': f.name,
                          'description': f.description,
                          'args': [
                            for (final a in f.args.values) inputValue(a),
                          ],
                          'type': ref(f.type),
                          'isDeprecated': f.deprecationReason != null,
                          'deprecationReason': f.deprecationReason,
                        },
                    ]
                  : null,
              'inputFields': type is InputObjectType
                  ? [for (final f in type.fields.values) inputValue(f)]
                  : null,
              'interfaces': type is FieldsType ? named(type.interfaces) : null,
              'enumValues': type is EnumType
                  ? [
                      for (final v in type.values.values)
                        {
                          'name': v.name,
                          'description': v.description,
                          'isDeprecated': v.deprecationReason != null,
                          'deprecationReason': v.deprecationReason,
                        },
                    ]
                  : null,
              'possibleTypes': type is UnionType
                  ? named(type.members)
                  : type is InterfaceType
                  ? named(schema.possibleTypes(type).toList()..sort())
                  : null,
              if (type is InputObjectType) 'isOneOf': type.isOneOf,
            },
        ],
        'directives': [
          for (final d in schema.directives.values)
            {
              'name': d.name,
              'description': null,
              'locations': [for (final l in d.locations) _location(l)],
              'args': [for (final a in d.args.values) inputValue(a)],
              'isRepeatable': d.isRepeatable,
            },
        ],
      },
    },
  };
}

String _kind(SchemaType type) => switch (type) {
  ScalarType() => 'SCALAR',
  ObjectType() => 'OBJECT',
  InterfaceType() => 'INTERFACE',
  UnionType() => 'UNION',
  EnumType() => 'ENUM',
  InputObjectType() => 'INPUT_OBJECT',
};

String _location(ast.DirectiveLocation l) =>
    l == ast.DirectiveLocation.enumDefinition
    ? 'ENUM'
    : l.name.replaceAllMapped(RegExp('[A-Z]'), (m) => '_${m[0]}').toUpperCase();
