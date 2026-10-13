import 'package:gql/ast.dart' as ast;

import '../config.dart';
import '../diagnostics.dart';
import '../documents/document_set.dart';
import '../documents/printer.dart';
import '../emit/naming.dart';
import '../schema/schema.dart';
import '../schema/type_ref.dart';
import 'model.dart';

/// Members of a generated operation class that variables must not shadow.
const _operationMembers = {
  ...objectMembers,
  'operationName',
  'operationType',
  'document',
  'variables',
  'parseData',
};

/// Members of a generated response class that fields must not shadow.
const _selectionMembers = {...objectMembers, 'toJson', 'fromJson'};

/// Members of the generated client that operation methods must not shadow.
const _clientMembers = {...objectMembers, 'execute', 'close', 'transport'};

/// Builds the [GenerationModel] for validated [documents].
///
/// Reports unsupported constructs and naming conflicts to [sink]; the model
/// must not be emitted if [sink] has errors afterwards.
GenerationModel buildModel(
  Schema schema,
  DocumentSet documents,
  GqlifyConfig config,
  DiagnosticSink sink,
) => _ModelBuilder(schema, documents, config, sink).build();

final class _ModelBuilder {
  _ModelBuilder(this.schema, this.documents, this.config, this.sink);

  final Schema schema;
  final DocumentSet documents;
  final GqlifyConfig config;
  final DiagnosticSink sink;

  /// Every generated top-level name, mapped to a description of its origin.
  final Map<String, String> _topLevelNames = {};
  final Map<String, String> _methodNames = {};

  late String _path;

  GenerationModel build() {
    _claim(config.clientName, 'the generated client', null);
    final libraries = <DocumentLibrary>[];
    if (config.mode.includesOperations) {
      final sorted = [...documents.documents]
        ..sort((a, b) => a.path.compareTo(b.path));
      for (final doc in sorted) {
        _path = doc.path;
        if (doc.fragments.isNotEmpty) {
          _unsupported(doc.fragments.first, 'Fragment definitions');
        }
        final operations = [for (final op in doc.operations) ?_operation(op)];
        if (operations.isEmpty) continue;
        libraries.add(
          DocumentLibrary(
            sourcePath: doc.path,
            outputPath: '${doc.path}.dart',
            operations: operations,
          ),
        );
      }
    }
    return GenerationModel(
      schemaOutputPath: config.schemaOutputPath,
      schemaSourcePaths: config.schema,
      clientName: config.clientName,
      documents: libraries,
    );
  }

  void _unsupported(ast.Node at, String what) => sink.error(
    'unsupported-feature',
    '$what are not supported by this version of gqlify yet.',
    path: _path,
    at: at,
  );

  /// Registers a generated top-level [name]; reports a collision if taken.
  bool _claim(String name, String origin, ast.Node? at) {
    final previous = _topLevelNames[name];
    if (previous != null) {
      sink.error(
        'name-collision',
        'Generated name "$name" for $origin collides with $previous. '
            'Rename the operation or use a field alias.',
        path: at == null ? null : _path,
        at: at,
      );
      return false;
    }
    _topLevelNames[name] = '$origin${at == null ? '' : ' ($_path)'}';
    return true;
  }

  OperationModel? _operation(ast.OperationDefinitionNode op) {
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
    final dataName = escapeType('${base}Data');
    final extensionName = escapeType('$base${suffix}Call');
    var methodName = camelCase(base);
    if (dartReservedWords.contains(methodName)) methodName = '\$$methodName';

    final errorsBefore = sink.items.where((d) => d.isError).length;
    _claim(descriptorName, 'operation "$name"', op.name);
    _claim(extensionName, 'operation "$name"', op.name);
    if (_clientMembers.contains(methodName)) {
      sink.error(
        'name-collision',
        'Operation "$name" would generate method "$methodName", which is a '
            'member of the generated client. Rename the operation.',
        path: _path,
        at: op.name,
      );
    } else if (_methodNames[methodName] case final previous?) {
      sink.error(
        'name-collision',
        'Operation "$name" would generate client method "$methodName", '
            'already generated for $previous. Rename one of the operations.',
        path: _path,
        at: op.name,
      );
    } else {
      _methodNames[methodName] = 'operation "${op.name!.value}" ($_path)';
    }

    final variables = [for (final v in op.variableDefinitions) ?_variable(v)];
    final seenVariables = <String, String>{};
    for (final v in variables) {
      final previous = seenVariables[v.dartName];
      if (previous != null) {
        sink.error(
          'name-collision',
          'Variables "\$$previous" and "\$${v.graphqlName}" both map to Dart '
              'parameter "${v.dartName}".',
          path: _path,
          at: op.name,
        );
      }
      seenVariables[v.dartName] = v.graphqlName;
    }

    final root = schema[schema.rootTypeName(op.type)!]!;
    final data = _selectionClass(
      dataName,
      base,
      root,
      [op.selectionSet],
      'operation "$name"',
      op.name!,
    );
    if (data == null) return null;
    if (sink.items.where((d) => d.isError).length != errorsBefore) return null;

    return OperationModel(
      name: name,
      type: op.type,
      descriptorName: descriptorName,
      methodName: methodName,
      extensionName: extensionName,
      documentConstName: '_${camelCase(base)}${suffix}Document',
      data: data,
      variables: variables,
      document: printExecutable(op),
    );
  }

  VariableModel? _variable(ast.VariableDefinitionNode v) {
    final graphqlName = v.variable.name.value;
    final type = _inputValueType(TypeRef.fromAst(v.type), v);
    if (type == null) return null;
    return VariableModel(
      graphqlName: graphqlName,
      dartName: escapeMember(camelCase(graphqlName), _operationMembers),
      type: type,
      hasDefault: v.defaultValue?.value != null,
    );
  }

  ValueType? _inputValueType(TypeRef ref, ast.Node at) {
    final nullable = !ref.isNonNull;
    switch (ref) {
      case ListTypeRef(:final ofType):
        final item = _inputValueType(ofType, at);
        return item == null ? null : ListValue(item, nullable: nullable);
      case NamedTypeRef(:final name):
        final type = schema[name];
        if (type is ScalarType) return _scalar(type, nullable: nullable);
        _unsupported(
          at,
          '${type is EnumType ? 'Enum' : 'Input object'} variables',
        );
        return null;
    }
  }

  ScalarValue _scalar(ScalarType type, {required bool nullable}) =>
      ScalarValue(type.name, switch (type.name) {
        'Int' => 'int',
        'Float' => 'double',
        'String' || 'ID' => 'String',
        'Boolean' => 'bool',
        _ => 'Object',
      }, nullable: nullable);

  /// Builds the class for the merged [sets] selected on [parent].
  SelectionClass? _selectionClass(
    String dartName,
    String nestedPrefix,
    SchemaType parent,
    List<ast.SelectionSetNode> sets,
    String origin,
    ast.Node at,
  ) {
    _claim(dartName, origin, at);

    // Group fields by response key, preserving first-occurrence order. The
    // validator guarantees that fields sharing a key are mergeable.
    final grouped = <String, List<ast.FieldNode>>{};
    for (final set in sets) {
      for (final selection in set.selections) {
        switch (selection) {
          case ast.FieldNode():
            grouped
                .putIfAbsent(
                  (selection.alias ?? selection.name).value,
                  () => [],
                )
                .add(selection);
          case ast.InlineFragmentNode():
            _unsupported(selection, 'Inline fragments');
          case ast.FragmentSpreadNode():
            _unsupported(selection, 'Fragment spreads');
          default:
            break;
        }
      }
    }

    final fields = <FieldModel>[];
    final dartNames = <String, String>{};
    for (final MapEntry(key: responseKey, value: nodes) in grouped.entries) {
      final def = schema.field(parent, nodes.first.name.value)!;
      final dartFieldName = escapeMember(
        camelCase(responseKey),
        _selectionMembers,
      );
      final previous = dartNames[dartFieldName];
      if (previous != null) {
        sink.error(
          'name-collision',
          'Response keys "$previous" and "$responseKey" both map to Dart field '
              '"$dartFieldName" in "$dartName". Use an alias for one of them.',
          path: _path,
          at: nodes.first,
        );
        continue;
      }
      dartNames[dartFieldName] = responseKey;

      final childSets = [for (final n in nodes) ?n.selectionSet];
      final type = _outputValueType(
        def.type,
        childSets,
        '$nestedPrefix${pascalCase(responseKey)}',
        'field "$responseKey" of $origin',
        nodes.first,
      );
      if (type == null) continue;
      fields.add(
        FieldModel(
          responseKey: responseKey,
          dartName: dartFieldName,
          // A field excluded by @skip/@include is absent from the response.
          type: nodes.every(_isConditional) ? _asNullable(type) : type,
          description: def.description,
          deprecationReason: def.deprecationReason,
        ),
      );
    }
    return SelectionClass(dartName, parent.name, fields);
  }

  ValueType? _outputValueType(
    TypeRef ref,
    List<ast.SelectionSetNode> childSets,
    String className,
    String origin,
    ast.Node at,
  ) {
    final nullable = !ref.isNonNull;
    switch (ref) {
      case ListTypeRef(:final ofType):
        final item = _outputValueType(ofType, childSets, className, origin, at);
        return item == null ? null : ListValue(item, nullable: nullable);
      case NamedTypeRef(:final name):
        final type = schema[name]!;
        switch (type) {
          case ScalarType():
            return _scalar(type, nullable: nullable);
          case EnumType():
            _unsupported(at, 'Enum fields');
            return null;
          case ObjectType():
            final cls = _selectionClass(
              escapeType(className),
              className,
              type,
              childSets,
              origin,
              at,
            );
            return cls == null ? null : ObjectValue(cls, nullable: nullable);
          case InterfaceType() || UnionType():
            _unsupported(at, 'Interface and union fields');
            return null;
          case InputObjectType():
            throw StateError('Input type in output position: $name');
        }
    }
  }

  static ValueType _asNullable(ValueType type) => switch (type) {
    ScalarValue() => ScalarValue(
      type.graphqlType,
      type.baseDartType,
      nullable: true,
    ),
    ObjectValue() => ObjectValue(type.selection, nullable: true),
    ListValue() => ListValue(type.item, nullable: true),
  };

  /// Whether @skip/@include may exclude [field] from the response.
  static bool _isConditional(ast.FieldNode field) {
    for (final d in field.directives) {
      final name = d.name.value;
      if (name != 'skip' && name != 'include') continue;
      final condition = d.arguments
          .where((a) => a.name.value == 'if')
          .firstOrNull
          ?.value;
      final alwaysIncluded =
          condition is ast.BooleanValueNode &&
          condition.value == (name == 'include');
      if (!alwaysIncluded) return true;
    }
    return false;
  }
}
