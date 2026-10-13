import 'package:gql/ast.dart' as ast;

import '../config.dart';
import '../diagnostics.dart';
import '../documents/document_set.dart';
import '../documents/printer.dart';
import '../emit/naming.dart';
import '../schema/schema.dart';
import '../schema/type_ref.dart';
import 'model.dart';
import 'naming_registry.dart';
import 'selections.dart';

/// Members of a generated operation class that variables must not shadow.
const _operationMembers = {
  ...objectMembers,
  'operationName',
  'operationType',
  'document',
  'variables',
  'parseData',
  'withNull',
};

/// Members of a generated input class that fields must not shadow.
const _inputMembers = {...objectMembers, 'toJson', 'withNull'};

/// Members of generated enums that values must not shadow.
const _enumMembers = {
  ...objectMembers,
  'values',
  'index',
  'name',
  'value',
  'toJson',
  'fromJson',
};

/// Members of the generated client that operation methods must not shadow.
const _clientMembers = {...objectMembers, 'execute', 'close', 'transport'};

/// Dart types a custom scalar can have without a `from_json` conversion.
const _jsonDartTypes = {
  'String',
  'int',
  'double',
  'num',
  'bool',
  'Object',
  'Map<String, Object?>',
  'List<Object?>',
};

/// Builds the [GenerationModel].
///
/// [documents] must be validated and have `__typename` added. Reports
/// unsupported constructs and naming conflicts to [sink]; the model must not
/// be emitted if [sink] has errors afterwards.
GenerationModel buildModel(
  Schema schema,
  DocumentSet documents,
  GqlifyConfig config,
  DiagnosticSink sink,
) => _ModelBuilder(schema, documents, config, sink).build();

final class _ModelBuilder implements LeafTypes {
  _ModelBuilder(this.schema, this.documents, this.config, this.sink)
    : names = NamingRegistry(sink);

  final Schema schema;
  final DocumentSet documents;
  final GqlifyConfig config;
  final DiagnosticSink sink;
  final NamingRegistry names;

  final Map<String, EnumModel> _enums = {};
  final Map<String, InputModel> _inputs = {};
  final Map<String, String> _methodNames = {};
  late final LibraryModel _schemaLibrary;
  late final SelectionBuilder _selections;

  GenerationModel build() {
    _checkScalarConfig();
    _schemaLibrary = LibraryModel(
      outputPath: config.schemaOutputPath,
      sourcePaths: config.schema,
    );
    final libraries = <String, LibraryModel>{
      _schemaLibrary.outputPath: _schemaLibrary,
    };

    if (config.mode.includesOperations) {
      names.claim(config.clientName, 'the generated client');
      _schemaLibrary.clientName = config.clientName;

      final sorted = [...documents.documents]
        ..sort((a, b) => a.path.compareTo(b.path));
      final fragmentLibraries =
          <String, ({String output, String source, int index})>{};
      for (final doc in sorted) {
        final library = LibraryModel(
          outputPath: '${doc.path}.dart',
          sourcePaths: [doc.path],
        )..imports.add(_schemaLibrary.outputPath);
        libraries[library.outputPath] = library;
        for (final (index, def) in doc.node.definitions.indexed) {
          if (def is ast.FragmentDefinitionNode) {
            fragmentLibraries[def.name.value] = (
              output: library.outputPath,
              source: doc.path,
              index: index,
            );
          }
        }
      }
      _selections = SelectionBuilder(
        schema: schema,
        fragments: {
          for (final MapEntry(:key, :value) in documents.fragments.entries)
            key: value.node,
        },
        fragmentLibraries: fragmentLibraries,
        leafTypes: this,
        names: names,
        sink: sink,
      )..libraries.addAll(libraries);

      for (final doc in sorted) {
        for (final fragment in doc.fragments) {
          _selections.fragmentInterface(fragment.name.value);
        }
        final library = libraries['${doc.path}.dart']!;
        for (final (index, def) in doc.node.definitions.indexed) {
          if (def is! ast.OperationDefinitionNode) continue;
          _selections.group = index;
          final model = _operation(doc.path, library, def);
          if (model != null) library.operations.add(model);
        }
      }
    }

    if (config.mode.includesOperations) {
      for (final doc in documents.documents) {
        libraries['${doc.path}.dart']!.dependencies.addAll(_dependencies(doc));
        // Which enums and inputs the schema library contains depends on
        // every document (operations mode only).
        if (!config.mode.includesAllSchemaTypes) {
          _schemaLibrary.dependencies.add(doc.path);
        }
      }
    }

    if (config.mode.includesAllSchemaTypes) {
      for (final type in schema.types.values) {
        if (type is EnumType) _enum(type);
        if (type is InputObjectType) _input(type, at: null);
      }
    }
    _schemaLibrary.enums.addAll(
      _enums.values.toList()
        ..sort((a, b) => a.graphqlName.compareTo(b.graphqlName)),
    );
    _schemaLibrary.inputs.addAll(
      _inputs.values.toList()
        ..sort((a, b) => a.graphqlName.compareTo(b.graphqlName)),
    );

    return GenerationModel(
      [
        for (final library in libraries.values)
          if (!library.isEmpty) library,
      ]..sort((a, b) => a.outputPath.compareTo(b.outputPath)),
    );
  }

  // ---------------------------------------------------------------------------
  // Leaf and schema types

  void _checkScalarConfig() {
    for (final MapEntry(key: name, value: scalar) in config.scalars.entries) {
      final type = schema[name];
      String? problem;
      if (type == null) {
        problem = 'the schema has no scalar "$name"';
      } else if (type is! ScalarType) {
        problem = '"$name" is not a scalar';
      } else if (type.isBuiltIn) {
        problem = 'built-in scalar "$name" cannot be remapped';
      } else if (scalar.fromJson == null &&
          !_jsonDartTypes.contains(scalar.type)) {
        problem =
            'type "${scalar.type}" is not a JSON type, so "from_json" is required';
      }
      if (problem != null) {
        sink.error(
          'invalid-config',
          'Invalid mapping for scalar "$name": $problem.',
          path: GqlifyConfig.fileName,
        );
      }
    }
  }

  ScalarMapping _scalarMapping(ScalarType type) {
    switch (type.name) {
      case 'Int':
        return ScalarMapping.int_;
      case 'Float':
        return ScalarMapping.double_;
      case 'String' || 'ID':
        return ScalarMapping.string;
      case 'Boolean':
        return ScalarMapping.bool_;
    }
    final configured = config.scalars[type.name];
    if (configured == null) return ScalarMapping.json;
    return ScalarMapping(
      dartType: configured.type,
      jsonType: configured.jsonType,
      fromJson: configured.fromJson,
      toJson: configured.toJson,
      import: configured.import,
    );
  }

  @override
  ValueType? leaf(
    SchemaType type, {
    required bool nullable,
    required ast.Node at,
  }) => switch (type) {
    ScalarType() => ScalarValue(
      type.name,
      _scalarMapping(type),
      nullable: nullable,
    ),
    EnumType() => EnumValue(_enum(type), nullable: nullable),
    _ => throw StateError('Not a leaf type: ${type.name}'),
  };

  EnumModel _enum(EnumType type) {
    final existing = _enums[type.name];
    if (existing != null) return existing;
    final dartName = escapeType(pascalCase(type.name));
    names.claim(dartName, 'enum "${type.name}"');
    final values = <EnumValueModel>[];
    final seen = <String, String>{};
    for (final value in type.values.values) {
      final dartValue = escapeMember(camelCase(value.name), _enumMembers);
      final previous = seen[dartValue];
      if (previous != null) {
        sink.error(
          'name-collision',
          'Enum values "${type.name}.$previous" and "${type.name}.${value.name}" '
              'both map to Dart value "$dartValue".',
        );
        continue;
      }
      seen[dartValue] = value.name;
      values.add(
        EnumValueModel(
          graphqlName: value.name,
          dartName: dartValue,
          description: value.description,
          deprecationReason: value.deprecationReason,
        ),
      );
    }
    return _enums[type.name] = EnumModel(
      graphqlName: type.name,
      dartName: dartName,
      values: values,
      description: type.description,
    );
  }

  InputModel _input(InputObjectType type, {required ast.Node? at}) {
    final existing = _inputs[type.name];
    if (existing != null) return existing;
    final dartName = escapeType(pascalCase(type.name));
    names.claim(dartName, 'input "${type.name}"');
    final model = InputModel(
      graphqlName: type.name,
      dartName: dartName,
      isOneOf: type.isOneOf,
      description: type.description,
    );
    _inputs[type.name] = model; // Before fields: inputs may be recursive.
    final seen = <String, String>{};
    for (final field in type.fields.values) {
      final dartField = escapeMember(camelCase(field.name), _inputMembers);
      final previous = seen[dartField];
      if (previous != null) {
        sink.error(
          'name-collision',
          'Input fields "${type.name}.$previous" and "${type.name}.${field.name}" '
              'both map to Dart field "$dartField".',
        );
        continue;
      }
      seen[dartField] = field.name;
      model.fields.add(
        InputFieldModel(
          graphqlName: field.name,
          dartName: dartField,
          type: _inputValueType(field.type, at),
          hasDefault: field.defaultValue != null,
          description: field.description,
          deprecationReason: field.deprecationReason,
        ),
      );
    }
    return model;
  }

  ValueType _inputValueType(TypeRef ref, ast.Node? at) {
    final nullable = !ref.isNonNull;
    switch (ref) {
      case ListTypeRef(:final ofType):
        return ListValue(_inputValueType(ofType, at), nullable: nullable);
      case NamedTypeRef(:final name):
        return switch (schema[name]!) {
          final ScalarType t => ScalarValue(
            t.name,
            _scalarMapping(t),
            nullable: nullable,
          ),
          final EnumType t => EnumValue(_enum(t), nullable: nullable),
          final InputObjectType t => InputObjectValue(
            _input(t, at: at),
            nullable: nullable,
          ),
          _ => throw StateError('Not an input type: $name'),
        };
    }
  }

  // ---------------------------------------------------------------------------
  // Operations

  OperationModel? _operation(
    String path,
    LibraryModel library,
    ast.OperationDefinitionNode op,
  ) {
    final name = op.name!.value;
    final suffix = switch (op.type) {
      ast.OperationType.query => 'Query',
      ast.OperationType.mutation => 'Mutation',
      ast.OperationType.subscription => 'Subscription',
    };
    var base = pascalCase(name);
    if (base.length > suffix.length && base.endsWith(suffix)) {
      base = base.substring(0, base.length - suffix.length);
    }
    final descriptorName = escapeType('$base$suffix');
    final extensionName = escapeType('$base${suffix}Call');
    var methodName = camelCase(base);
    if (dartReservedWords.contains(methodName)) methodName = '\$$methodName';

    final origin = 'operation "$name"';
    names.claim(descriptorName, origin, path: path, at: op.name);
    names.claim(extensionName, origin, path: path, at: op.name);
    if (_clientMembers.contains(methodName)) {
      sink.error(
        'name-collision',
        'Operation "$name" would generate method "$methodName", which is a '
            'member of the generated client. Rename the operation.',
        path: path,
        at: op.name,
      );
    } else if (_methodNames[methodName] case final previous?) {
      sink.error(
        'name-collision',
        'Operation "$name" would generate client method "$methodName", '
            'already generated for $previous. Rename one of the operations.',
        path: path,
        at: op.name,
      );
    } else {
      _methodNames[methodName] = '$origin ($path)';
    }

    final variables = <InputFieldModel>[];
    final seen = <String, String>{};
    for (final v in op.variableDefinitions) {
      final graphqlName = v.variable.name.value;
      final dartName = escapeMember(camelCase(graphqlName), _operationMembers);
      final previous = seen[dartName];
      if (previous != null) {
        sink.error(
          'name-collision',
          'Variables "\$$previous" and "\$$graphqlName" both map to Dart '
              'parameter "$dartName".',
          path: path,
          at: v,
        );
        continue;
      }
      seen[dartName] = graphqlName;
      variables.add(
        InputFieldModel(
          graphqlName: graphqlName,
          dartName: dartName,
          type: _inputValueType(TypeRef.fromAst(v.type), v),
          hasDefault: v.defaultValue?.value != null,
        ),
      );
    }

    final root = schema[schema.rootTypeName(op.type)!]!;
    final dataName = escapeType('${base}Data');
    _selections.responseType(
      dartName: dataName,
      nestedPrefix: base,
      static: root,
      sets: SelectionBuilder.rootSets(op.selectionSet),
      required: const [],
      library: library.outputPath,
      origin: origin,
      at: op.name!,
      path: path,
    );

    return OperationModel(
      name: name,
      type: op.type,
      descriptorName: descriptorName,
      methodName: methodName,
      extensionName: extensionName,
      documentConstName: '_${camelCase(base)}${suffix}Document',
      dataName: dataName,
      variables: variables,
      document: _document(op),
      clientName: config.clientName,
    );
  }

  /// Documents whose content can affect the library generated for [doc]:
  /// [doc] itself and the documents of every fragment it transitively
  /// spreads. Fragment content only reaches other definitions via spreads.
  Set<String> _dependencies(ParsedDocument doc) {
    final result = {doc.path};
    final visited = <String>{};
    void visit(ast.SelectionSetNode set) {
      for (final selection in set.selections) {
        switch (selection) {
          case ast.FieldNode(:final selectionSet?):
            visit(selectionSet);
          case ast.InlineFragmentNode(:final selectionSet):
            visit(selectionSet);
          case ast.FragmentSpreadNode(:final name):
            final fragment = documents.fragments[name.value]!;
            result.add(fragment.path);
            if (visited.add(name.value)) visit(fragment.node.selectionSet);
          default:
            break;
        }
      }
    }

    for (final def in doc.node.definitions) {
      switch (def) {
        case ast.OperationDefinitionNode(:final selectionSet):
          visit(selectionSet);
        case ast.FragmentDefinitionNode(:final selectionSet):
          visit(selectionSet);
        default:
          break;
      }
    }
    return result;
  }

  /// The operation followed by every fragment it transitively spreads,
  /// sorted by name.
  String _document(ast.OperationDefinitionNode op) {
    final used = <String>{};
    void visit(ast.SelectionSetNode set) {
      for (final selection in set.selections) {
        switch (selection) {
          case ast.FieldNode(:final selectionSet?):
            visit(selectionSet);
          case ast.InlineFragmentNode(:final selectionSet):
            visit(selectionSet);
          case ast.FragmentSpreadNode(:final name):
            if (used.add(name.value)) {
              visit(documents.fragments[name.value]!.node.selectionSet);
            }
          default:
            break;
        }
      }
    }

    visit(op.selectionSet);
    return [
      printExecutable(op),
      for (final name in used.toList()..sort())
        printExecutable(documents.fragments[name]!.node),
    ].join('\n');
  }
}
