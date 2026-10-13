import 'package:gql/ast.dart' as ast;
import 'package:gql/language.dart' as lang;
import 'package:source_span/source_span.dart';

import '../diagnostics.dart';
import '../source.dart';
import 'schema.dart';
import 'type_ref.dart';

/// Parses GraphQL SDL [sources] into a [Schema], reporting problems to
/// [sink]. Returns `null` if the schema has errors.
Schema? buildSchemaFromSdl(List<GqlifySource> sources, DiagnosticSink sink) {
  final builder = _SdlBuilder(sink);
  for (final source in sources) {
    final ast.DocumentNode doc;
    try {
      doc = lang.parseString(source.content, url: source.path);
    } on SourceSpanException catch (e) {
      sink.add(
        Diagnostic.error(
          'syntax-error',
          e.message,
          path: source.path,
          span: e.span,
        ),
      );
      continue;
    }
    builder.addDocument(source.path, doc);
  }
  if (sink.hasErrors) return null;
  return builder.build();
}

/// Parses an SDL string; convenience for tests and tools.
Schema? parseSchema(
  String sdl,
  DiagnosticSink sink, {
  String path = 'schema.graphql',
}) => buildSchemaFromSdl([GqlifySource(path, sdl)], sink);

final class _Located<T extends ast.Node> {
  _Located(this.path, this.node);

  final String path;
  final T node;
}

final class _SdlBuilder {
  _SdlBuilder(this.sink);

  final DiagnosticSink sink;
  final List<_Located<ast.TypeDefinitionNode>> _typeDefs = [];
  final List<_Located<ast.TypeExtensionNode>> _typeExts = [];
  final List<_Located<ast.DirectiveDefinitionNode>> _directiveDefs = [];
  final List<_Located<ast.SchemaDefinitionNode>> _schemaDefs = [];
  final List<_Located<ast.SchemaExtensionNode>> _schemaExts = [];

  final Map<String, SchemaType> _types = {};
  final Map<String, String> _typePaths = {};
  final Map<String, DirectiveDef> _directives = {};

  void addDocument(String path, ast.DocumentNode doc) {
    for (final def in doc.definitions) {
      switch (def) {
        case ast.TypeDefinitionNode():
          _typeDefs.add(_Located(path, def));
        case ast.TypeExtensionNode():
          _typeExts.add(_Located(path, def));
        case ast.DirectiveDefinitionNode():
          _directiveDefs.add(_Located(path, def));
        case ast.SchemaDefinitionNode():
          _schemaDefs.add(_Located(path, def));
        case ast.SchemaExtensionNode():
          _schemaExts.add(_Located(path, def));
        case ast.OperationDefinitionNode() || ast.FragmentDefinitionNode():
          sink.error(
            'executable-in-schema',
            'Schema files may only contain type system definitions; move '
                'operations and fragments to document files.',
            path: path,
            at: def,
          );
        default:
          sink.error(
            'unsupported-definition',
            'Unsupported definition.',
            path: path,
          );
      }
    }
  }

  void _error(String code, String message, String path, ast.Node? at) =>
      sink.error(code, message, path: path, at: at);

  Schema? build() {
    for (final name in builtInScalars) {
      _types[name] = ScalarType(name);
    }
    _addBuiltInDirectives();

    // Pass 1: declare every named type so references can be resolved
    // regardless of definition order or file.
    for (final located in _typeDefs) {
      final node = located.node;
      final name = node.name.value;
      final description = node.description?.value;
      if (name.startsWith('__')) {
        _error(
          'reserved-name',
          'Name "$name" is reserved for introspection.',
          located.path,
          node,
        );
        continue;
      }
      final existing = _types[name];
      if (existing != null) {
        if (node is ast.ScalarTypeDefinitionNode &&
            existing is ScalarType &&
            existing.isBuiltIn) {
          continue; // Redeclaring a built-in scalar is harmless.
        }
        _error(
          'duplicate-type',
          'Type "$name" is defined more than once.',
          located.path,
          node,
        );
        continue;
      }
      _typePaths[name] = located.path;
      _types[name] = switch (node) {
        ast.ScalarTypeDefinitionNode() => ScalarType(
          name,
          description: description,
          node: node,
        ),
        ast.ObjectTypeDefinitionNode() => ObjectType(
          name,
          description: description,
          node: node,
        ),
        ast.InterfaceTypeDefinitionNode() => InterfaceType(
          name,
          description: description,
          node: node,
        ),
        ast.UnionTypeDefinitionNode() => UnionType(
          name,
          description: description,
          node: node,
        ),
        ast.EnumTypeDefinitionNode() => EnumType(
          name,
          description: description,
          node: node,
        ),
        ast.InputObjectTypeDefinitionNode() => InputObjectType(
          name,
          description: description,
          node: node,
        ),
        _ => throw StateError('Unexpected type definition $node'),
      };
    }
    for (final located in _directiveDefs) {
      _declareDirective(located.path, located.node);
    }

    // Pass 2: members of definitions, then extensions in source order.
    for (final located in _typeDefs) {
      final type = _types[located.node.name.value];
      if (type == null || type.node != located.node) continue;
      _addMembers(located.path, type, located.node);
    }
    for (final located in _typeExts) {
      _applyExtension(located.path, located.node);
    }

    final roots = _resolveRoots();
    if (roots == null || sink.hasErrors) return null;

    final schema = Schema(
      types: _types,
      directives: _directives,
      queryType: roots.query,
      mutationType: roots.mutation,
      subscriptionType: roots.subscription,
    );
    _validate(schema);
    return sink.hasErrors ? null : schema;
  }

  void _addBuiltInDirectives() {
    const L = ast.DirectiveLocation.values;
    ast.DirectiveLocation loc(String n) => L.firstWhere((l) => l.name == n);
    final executableField = {
      loc('field'),
      loc('fragmentSpread'),
      loc('inlineFragment'),
    };
    for (final name in ['skip', 'include']) {
      _directives[name] = DirectiveDef(name, executableField)
        ..args['if'] = InputValueDef(
          'if',
          const NamedTypeRef('Boolean', isNonNull: true),
        );
    }
    _directives['deprecated'] = DirectiveDef('deprecated', {
      loc('fieldDefinition'),
      loc('argumentDefinition'),
      loc('inputFieldDefinition'),
      loc('enumValue'),
    })..args['reason'] = InputValueDef('reason', const NamedTypeRef('String'));
    _directives['specifiedBy'] = DirectiveDef('specifiedBy', {loc('scalar')})
      ..args['url'] = InputValueDef(
        'url',
        const NamedTypeRef('String', isNonNull: true),
      );
    _directives['oneOf'] = DirectiveDef('oneOf', {loc('inputObject')});
  }

  void _declareDirective(String path, ast.DirectiveDefinitionNode node) {
    final name = node.name.value;
    if (_directives.containsKey(name) && !_isBuiltInDirective(name)) {
      _error(
        'duplicate-directive',
        'Directive "@$name" is defined more than once.',
        path,
        node,
      );
      return;
    }
    final def = DirectiveDef(
      name,
      node.locations.toSet(),
      isRepeatable: node.repeatable,
    );
    for (final arg in node.args) {
      _addInputValue(path, def.args, arg, 'directive "@$name"');
    }
    _directives[name] = def;
  }

  static bool _isBuiltInDirective(String name) => const {
    'skip',
    'include',
    'deprecated',
    'specifiedBy',
    'oneOf',
  }.contains(name);

  void _addMembers(String path, SchemaType type, ast.Node node) {
    switch ((type, node)) {
      case (final ObjectType t, final ast.ObjectTypeDefinitionNode n):
        _addFields(path, t, n.fields);
        _addInterfaces(path, t, n.interfaces);
      case (final InterfaceType t, final ast.InterfaceTypeDefinitionNode n):
        _addFields(path, t, n.fields);
        _addInterfaces(path, t, n.interfaces);
      case (final UnionType t, final ast.UnionTypeDefinitionNode n):
        _addUnionMembers(path, t, n.types);
      case (final EnumType t, final ast.EnumTypeDefinitionNode n):
        _addEnumValues(path, t, n.values);
      case (final InputObjectType t, final ast.InputObjectTypeDefinitionNode n):
        _addInputFields(path, t, n.fields);
        if (n.directives.any((d) => d.name.value == 'oneOf')) t.isOneOf = true;
      case (ScalarType(), ast.ScalarTypeDefinitionNode()):
        break;
      default:
        throw StateError('Mismatched type definition for ${type.name}');
    }
  }

  void _applyExtension(String path, ast.TypeExtensionNode node) {
    final name = node.name.value;
    final type = _types[name];
    if (type == null) {
      _error('unknown-type', 'Cannot extend unknown type "$name".', path, node);
      return;
    }
    switch ((type, node)) {
      case (final ObjectType t, final ast.ObjectTypeExtensionNode n):
        _addFields(path, t, n.fields);
        _addInterfaces(path, t, n.interfaces);
      case (final InterfaceType t, final ast.InterfaceTypeExtensionNode n):
        _addFields(path, t, n.fields);
        _addInterfaces(path, t, n.interfaces);
      case (final UnionType t, final ast.UnionTypeExtensionNode n):
        _addUnionMembers(path, t, n.types);
      case (final EnumType t, final ast.EnumTypeExtensionNode n):
        _addEnumValues(path, t, n.values);
      case (final InputObjectType t, final ast.InputObjectTypeExtensionNode n):
        _addInputFields(path, t, n.fields);
        if (n.directives.any((d) => d.name.value == 'oneOf')) t.isOneOf = true;
      case (ScalarType(), ast.ScalarTypeExtensionNode()):
        break;
      default:
        _error(
          'invalid-extension',
          'Extension of "$name" does not match its kind.',
          path,
          node,
        );
    }
  }

  void _addFields(
    String path,
    FieldsType type,
    List<ast.FieldDefinitionNode> fields,
  ) {
    for (final f in fields) {
      final name = f.name.value;
      if (type.fields.containsKey(name)) {
        _error(
          'duplicate-field',
          'Field "${type.name}.$name" is defined more than once.',
          path,
          f,
        );
        continue;
      }
      final def = FieldDef(
        name,
        TypeRef.fromAst(f.type),
        description: f.description?.value,
        deprecationReason: _deprecation(f.directives),
        node: f,
      );
      for (final arg in f.args) {
        _addInputValue(path, def.args, arg, 'field "${type.name}.$name"');
      }
      type.fields[name] = def;
    }
  }

  void _addInputValue(
    String path,
    Map<String, InputValueDef> target,
    ast.InputValueDefinitionNode node,
    String owner,
  ) {
    final name = node.name.value;
    if (target.containsKey(name)) {
      _error(
        'duplicate-argument',
        'Argument "$name" of $owner is defined more than once.',
        path,
        node,
      );
      return;
    }
    target[name] = InputValueDef(
      name,
      TypeRef.fromAst(node.type),
      defaultValue: node.defaultValue,
      description: node.description?.value,
      deprecationReason: _deprecation(node.directives),
      node: node,
    );
  }

  void _addInterfaces(
    String path,
    FieldsType type,
    List<ast.NamedTypeNode> interfaces,
  ) {
    for (final i in interfaces) {
      final name = i.name.value;
      if (type.interfaces.contains(name)) {
        _error(
          'duplicate-interface',
          '"${type.name}" implements "$name" more than once.',
          path,
          i,
        );
        continue;
      }
      type.interfaces.add(name);
    }
  }

  void _addUnionMembers(
    String path,
    UnionType type,
    List<ast.NamedTypeNode> members,
  ) {
    for (final m in members) {
      final name = m.name.value;
      if (type.members.contains(name)) {
        _error(
          'duplicate-union-member',
          'Union "${type.name}" includes "$name" more than once.',
          path,
          m,
        );
        continue;
      }
      type.members.add(name);
    }
  }

  void _addEnumValues(
    String path,
    EnumType type,
    List<ast.EnumValueDefinitionNode> values,
  ) {
    for (final v in values) {
      final name = v.name.value;
      if (type.values.containsKey(name)) {
        _error(
          'duplicate-enum-value',
          'Enum value "${type.name}.$name" is defined more than once.',
          path,
          v,
        );
        continue;
      }
      if (name == 'true' || name == 'false' || name == 'null') {
        _error(
          'invalid-enum-value',
          'Enum value cannot be named "$name".',
          path,
          v,
        );
        continue;
      }
      type.values[name] = EnumValueDef(
        name,
        description: v.description?.value,
        deprecationReason: _deprecation(v.directives),
      );
    }
  }

  void _addInputFields(
    String path,
    InputObjectType type,
    List<ast.InputValueDefinitionNode> fields,
  ) {
    for (final f in fields) {
      _addInputValue(path, type.fields, f, 'input "${type.name}"');
    }
  }

  String? _deprecation(List<ast.DirectiveNode> directives) {
    for (final d in directives) {
      if (d.name.value != 'deprecated') continue;
      for (final a in d.arguments) {
        if (a.name.value == 'reason' && a.value is ast.StringValueNode) {
          return (a.value as ast.StringValueNode).value;
        }
      }
      return 'No longer supported';
    }
    return null;
  }

  ({String query, String? mutation, String? subscription})? _resolveRoots() {
    String? query, mutation, subscription;
    final operationTypes = [
      for (final d in _schemaDefs) (d.path, d.node.operationTypes),
      for (final e in _schemaExts) (e.path, e.node.operationTypes),
    ];
    if (_schemaDefs.length > 1) {
      _error(
        'duplicate-schema',
        'Only one schema definition is allowed.',
        _schemaDefs[1].path,
        null,
      );
    }
    if (_schemaDefs.isEmpty && _schemaExts.isEmpty) {
      query = _types.containsKey('Query') ? 'Query' : null;
      mutation = _types.containsKey('Mutation') ? 'Mutation' : null;
      subscription = _types.containsKey('Subscription') ? 'Subscription' : null;
    }
    for (final (path, defs) in operationTypes) {
      for (final def in defs) {
        final name = def.type.name.value;
        final current = switch (def.operation) {
          ast.OperationType.query => query,
          ast.OperationType.mutation => mutation,
          ast.OperationType.subscription => subscription,
        };
        if (current != null) {
          _error(
            'duplicate-root-type',
            'Root type for ${def.operation.name} is defined more than once.',
            path,
            def.type,
          );
        }
        if (_types[name] is! ObjectType) {
          _error(
            'invalid-root-type',
            'Root ${def.operation.name} type "$name" must be an object type.',
            path,
            def.type,
          );
        }
        switch (def.operation) {
          case ast.OperationType.query:
            query = name;
          case ast.OperationType.mutation:
            mutation = name;
          case ast.OperationType.subscription:
            subscription = name;
        }
      }
    }
    if (query == null || _types[query] is! ObjectType) {
      sink.error(
        'missing-query-type',
        'The schema must define a query root type (e.g. "type Query").',
      );
      return null;
    }
    return (query: query, mutation: mutation, subscription: subscription);
  }

  void _validate(Schema schema) {
    void checkRef(
      String path,
      TypeRef ref,
      ast.Node? at, {
      required bool input,
      required String owner,
    }) {
      final named = schema[ref.namedType];
      if (named == null) {
        _error(
          'unknown-type',
          'Unknown type "${ref.namedType}" in $owner.',
          path,
          at,
        );
      } else if (input && !named.isInputType) {
        _error(
          'invalid-input-type',
          '$owner must have an input type, but "${named.name}" is an output type.',
          path,
          at,
        );
      } else if (!input && !named.isOutputType) {
        _error(
          'invalid-output-type',
          '$owner must have an output type, but "${named.name}" is an input type.',
          path,
          at,
        );
      }
    }

    for (final type in _types.values) {
      final path = _typePaths[type.name] ?? '';
      switch (type) {
        case FieldsType():
          if (type.fields.isEmpty) {
            _error(
              'empty-type',
              'Type "${type.name}" must define at least one field.',
              path,
              type.node,
            );
          }
          for (final field in type.fields.values) {
            final owner = 'field "${type.name}.${field.name}"';
            checkRef(path, field.type, field.node, input: false, owner: owner);
            for (final arg in field.args.values) {
              checkRef(
                path,
                arg.type,
                arg.node,
                input: true,
                owner: 'argument "${arg.name}" of $owner',
              );
            }
          }
          _validateInterfaces(schema, path, type);
        case UnionType():
          for (final m in type.members) {
            if (schema[m] is! ObjectType) {
              _error(
                'invalid-union-member',
                'Union "${type.name}" member "$m" must be an object type.',
                path,
                type.node,
              );
            }
          }
        case InputObjectType():
          for (final f in type.fields.values) {
            checkRef(
              path,
              f.type,
              f.node,
              input: true,
              owner: 'input field "${type.name}.${f.name}"',
            );
          }
        case EnumType():
          if (type.values.isEmpty) {
            _error(
              'empty-type',
              'Enum "${type.name}" must define at least one value.',
              path,
              type.node,
            );
          }
        case ScalarType():
          break;
      }
    }
    for (final d in _directives.values) {
      for (final arg in d.args.values) {
        checkRef(
          '',
          arg.type,
          arg.node,
          input: true,
          owner: 'argument "${arg.name}" of directive "@${d.name}"',
        );
      }
    }
  }

  void _validateInterfaces(Schema schema, String path, FieldsType type) {
    for (final name in type.interfaces) {
      final iface = schema[name];
      if (iface is! InterfaceType) {
        _error(
          'invalid-interface',
          '"${type.name}" can only implement interfaces, but "$name" is not one.',
          path,
          type.node,
        );
        continue;
      }
      for (final transitive in iface.interfaces) {
        if (!type.interfaces.contains(transitive)) {
          _error(
            'missing-transitive-interface',
            '"${type.name}" must also implement "$transitive" because "$name" does.',
            path,
            type.node,
          );
        }
      }
      for (final ifaceField in iface.fields.values) {
        final field = type.fields[ifaceField.name];
        if (field == null) {
          _error(
            'missing-interface-field',
            '"${type.name}" must define field "${ifaceField.name}" of interface "$name".',
            path,
            type.node,
          );
          continue;
        }
        if (!schema.isSubtype(field.type, ifaceField.type)) {
          _error(
            'invalid-interface-field',
            'Field "${type.name}.${field.name}" has type ${field.type}, which is not '
                'compatible with ${ifaceField.type} from interface "$name".',
            path,
            field.node,
          );
        }
        for (final arg in ifaceField.args.values) {
          final own = field.args[arg.name];
          if (own == null || own.type != arg.type) {
            _error(
              'invalid-interface-field',
              'Field "${type.name}.${field.name}" must accept argument "${arg.name}: '
                  '${arg.type}" from interface "$name".',
              path,
              field.node,
            );
          }
        }
        for (final own in field.args.values) {
          if (!ifaceField.args.containsKey(own.name) &&
              own.type.isNonNull &&
              own.defaultValue == null) {
            _error(
              'invalid-interface-field',
              'Additional argument "${own.name}" of "${type.name}.${field.name}" '
                  'must be optional to satisfy interface "$name".',
              path,
              own.node,
            );
          }
        }
      }
    }
  }
}
