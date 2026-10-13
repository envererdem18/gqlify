import 'package:gql/ast.dart' as ast;

import '../diagnostics.dart';
import '../schema/schema.dart';
import '../schema/type_ref.dart';
import 'document_set.dart';
import 'printer.dart';

/// Validates every operation and fragment of [documents] against [schema]
/// (GraphQL specification, section 5 "Validation").
///
/// `package:gql` ships no executable-document validation rules, so gqlify
/// implements them here. Code generation only runs on documents without
/// errors, which lets later phases assume a well-formed input.
void validateDocuments(
  Schema schema,
  DocumentSet documents,
  DiagnosticSink sink,
) => _Validator(schema, documents, sink).run();

final class _VariableUsage {
  _VariableUsage(this.node, this.expected, this.hasLocationDefault, this.path);

  final ast.VariableNode node;
  final TypeRef expected;
  final bool hasLocationDefault;
  final String path;
}

/// Context of the definition currently being validated.
final class _Scope {
  _Scope(this.path);

  final String path;
  final List<_VariableUsage> variableUsages = [];
  final Set<String> fragmentSpreads = {};
}

final class _FieldInfo {
  _FieldInfo(this.parent, this.node, this.def);

  final SchemaType parent;
  final ast.FieldNode node;
  final FieldDef? def;
}

final class _Validator {
  _Validator(this.schema, this.documents, this.sink);

  final Schema schema;
  final DocumentSet documents;
  final DiagnosticSink sink;

  /// Variable usages and direct spreads of each fragment, keyed by name.
  final Map<String, _Scope> _fragmentScopes = {};

  void _error(String code, String message, String path, ast.Node? at) =>
      sink.error(code, message, path: path, at: at);

  void _deprecated(_Scope scope, String code, String message, ast.Node at) =>
      sink.warning(code, message, path: scope.path, at: at);

  void run() {
    _checkUniqueNames();
    for (final fragment in documents.fragments.values) {
      _validateFragment(fragment);
    }
    _checkFragmentCycles();
    final usedFragments = <String>{};
    for (final doc in documents.documents) {
      for (final op in doc.operations) {
        _validateOperation(doc.path, op, usedFragments);
      }
    }
    for (final f in documents.fragments.values) {
      if (!usedFragments.contains(f.node.name.value)) {
        sink.warning(
          'unused-fragment',
          'Fragment "${f.node.name.value}" is not used by any operation.',
          path: f.path,
          at: f.node,
        );
      }
    }
  }

  void _checkUniqueNames() {
    final operations = <String, String>{};
    final fragments = <String, String>{};
    for (final doc in documents.documents) {
      for (final op in doc.operations) {
        final name = op.name?.value;
        if (name == null) continue;
        final previous = operations[name];
        if (previous != null) {
          _error(
            'duplicate-operation',
            'Operation "$name" is already defined in $previous.',
            doc.path,
            op,
          );
        } else {
          operations[name] = doc.path;
        }
      }
      for (final f in doc.fragments) {
        final name = f.name.value;
        final previous = fragments[name];
        if (previous != null) {
          _error(
            'duplicate-fragment',
            'Fragment "$name" is already defined in $previous.',
            doc.path,
            f,
          );
        } else {
          fragments[name] = doc.path;
        }
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Definitions

  void _validateFragment(Defined<ast.FragmentDefinitionNode> fragment) {
    final node = fragment.node;
    final scope = _Scope(fragment.path);
    _fragmentScopes[node.name.value] = scope;
    final type = _typeCondition(scope, node.typeCondition.on, node);
    _directives(
      scope,
      node.directives,
      ast.DirectiveLocation.fragmentDefinition,
    );
    if (type != null) _selectionSet(scope, node.selectionSet, type);
  }

  void _validateOperation(
    String path,
    ast.OperationDefinitionNode op,
    Set<String> usedFragments,
  ) {
    final scope = _Scope(path);
    if (op.name == null) {
      _error(
        'anonymous-operation',
        'Operations must be named: gqlify derives Dart names from them.',
        path,
        op.selectionSet.selections.firstOrNull,
      );
    }
    final opLabel = op.name?.value ?? 'anonymous ${op.type.name}';

    if (op.type == ast.OperationType.subscription) {
      _error(
        'unsupported-subscription',
        'Subscriptions are not supported yet ("$opLabel").',
        path,
        op,
      );
      return;
    }

    final rootName = schema.rootTypeName(op.type);
    final root = rootName == null ? null : schema[rootName];
    if (root == null) {
      _error(
        'missing-root-type',
        'The schema does not support ${op.type.name} operations.',
        path,
        op,
      );
      return;
    }

    final location = switch (op.type) {
      ast.OperationType.query => ast.DirectiveLocation.query,
      ast.OperationType.mutation => ast.DirectiveLocation.mutation,
      ast.OperationType.subscription => ast.DirectiveLocation.subscription,
    };
    _directives(scope, op.directives, location);

    final variables = <String, ast.VariableDefinitionNode>{};
    for (final v in op.variableDefinitions) {
      final name = v.variable.name.value;
      if (variables.containsKey(name)) {
        _error(
          'duplicate-variable',
          'Variable "\$$name" is declared more than once.',
          path,
          v,
        );
        continue;
      }
      variables[name] = v;
      final type = TypeRef.fromAst(v.type);
      final named = schema[type.namedType];
      if (named == null) {
        _error(
          'unknown-type',
          'Unknown type "${type.namedType}".',
          path,
          v.type,
        );
      } else if (!named.isInputType) {
        _error(
          'invalid-variable-type',
          'Variable "\$$name" must have an input type, but "${named.name}" is not one.',
          path,
          v.type,
        );
      } else if (v.defaultValue?.value case final value?) {
        _value(scope, value, type, v, isConst: true);
      }
      _directives(
        scope,
        v.directives,
        ast.DirectiveLocation.variableDefinition,
      );
    }

    _selectionSet(scope, op.selectionSet, root);

    // Gather variable usages through all transitively spread fragments.
    final usages = [...scope.variableUsages];
    final visited = <String>{};
    final queue = [...scope.fragmentSpreads];
    while (queue.isNotEmpty) {
      final name = queue.removeLast();
      if (!visited.add(name)) continue;
      usedFragments.add(name);
      final fragmentScope = _fragmentScopes[name];
      if (fragmentScope == null) continue;
      usages.addAll(fragmentScope.variableUsages);
      queue.addAll(fragmentScope.fragmentSpreads);
    }

    final used = <String>{};
    for (final usage in usages) {
      final name = usage.node.name.value;
      used.add(name);
      final def = variables[name];
      if (def == null) {
        _error(
          'undefined-variable',
          'Variable "\$$name" is not defined by operation "$opLabel".',
          usage.path,
          usage.node,
        );
        continue;
      }
      final varType = TypeRef.fromAst(def.type);
      if (!_isVariableUsageAllowed(varType, def, usage)) {
        _error(
          'invalid-variable-usage',
          'Variable "\$$name" of type $varType cannot be used where '
              '${usage.expected} is expected.',
          usage.path,
          usage.node,
        );
      }
    }
    for (final v in variables.values) {
      if (!used.contains(v.variable.name.value)) {
        _error(
          'unused-variable',
          'Variable "\$${v.variable.name.value}" is never used in operation "$opLabel".',
          path,
          v,
        );
      }
    }
  }

  bool _isVariableUsageAllowed(
    TypeRef varType,
    ast.VariableDefinitionNode def,
    _VariableUsage usage,
  ) {
    final location = usage.expected;
    if (location.isNonNull && !varType.isNonNull) {
      final defaultValue = def.defaultValue?.value;
      final hasNonNullDefault =
          defaultValue != null && defaultValue is! ast.NullValueNode;
      if (!hasNonNullDefault && !usage.hasLocationDefault) return false;
      return _areTypesCompatible(varType, location.nullable);
    }
    return _areTypesCompatible(varType, location);
  }

  bool _areTypesCompatible(TypeRef variable, TypeRef location) {
    if (location.isNonNull) {
      return variable.isNonNull &&
          _areTypesCompatible(variable.nullable, location.nullable);
    }
    if (variable.isNonNull) {
      return _areTypesCompatible(variable.nullable, location);
    }
    if (location is ListTypeRef) {
      return variable is ListTypeRef &&
          _areTypesCompatible(variable.ofType, location.ofType);
    }
    if (variable is ListTypeRef) return false;
    return variable.namedType == location.namedType;
  }

  void _checkFragmentCycles() {
    final state = <String, int>{}; // 1 = visiting, 2 = done
    void visit(String name, List<String> stack) {
      final scope = _fragmentScopes[name];
      if (scope == null || state[name] == 2) return;
      state[name] = 1;
      for (final spread in scope.fragmentSpreads.toList()..sort()) {
        if (state[spread] == 1) {
          final cycle = [...stack.sublist(stack.indexOf(spread)), spread];
          final def = documents.fragments[spread]!;
          _error(
            'fragment-cycle',
            'Fragment spreads form a cycle: ${cycle.join(' -> ')}.',
            def.path,
            def.node,
          );
        } else {
          visit(spread, [...stack, spread]);
        }
      }
      state[name] = 2;
    }

    for (final name in _fragmentScopes.keys.toList()..sort()) {
      visit(name, [name]);
    }
  }

  // ---------------------------------------------------------------------------
  // Selections

  SchemaType? _typeCondition(_Scope scope, ast.NamedTypeNode on, ast.Node at) {
    final type = schema[on.name.value];
    if (type == null) {
      _error(
        'unknown-type',
        'Unknown type "${on.name.value}".',
        scope.path,
        on,
      );
      return null;
    }
    if (!type.isComposite) {
      _error(
        'invalid-type-condition',
        'Fragments can only be defined on object, interface or union types, '
            'not "${type.name}".',
        scope.path,
        on,
      );
      return null;
    }
    return type;
  }

  void _selectionSet(
    _Scope scope,
    ast.SelectionSetNode set,
    SchemaType parent,
  ) {
    for (final selection in set.selections) {
      switch (selection) {
        case ast.FieldNode():
          _field(scope, selection, parent);
        case ast.InlineFragmentNode():
          _directives(
            scope,
            selection.directives,
            ast.DirectiveLocation.inlineFragment,
          );
          var type = parent;
          if (selection.typeCondition case final condition?) {
            final conditionType = _typeCondition(
              scope,
              condition.on,
              selection,
            );
            if (conditionType == null) continue;
            type = conditionType;
            _checkSpreadPossible(
              scope,
              parent,
              type,
              selection,
              'Inline fragment on "${type.name}"',
            );
          }
          _selectionSet(scope, selection.selectionSet, type);
        case ast.FragmentSpreadNode():
          _directives(
            scope,
            selection.directives,
            ast.DirectiveLocation.fragmentSpread,
          );
          final name = selection.name.value;
          final fragment = documents.fragments[name];
          if (fragment == null) {
            _error(
              'unknown-fragment',
              'Unknown fragment "$name".',
              scope.path,
              selection,
            );
            continue;
          }
          scope.fragmentSpreads.add(name);
          final type = schema[fragment.node.typeCondition.on.name.value];
          if (type != null && type.isComposite) {
            _checkSpreadPossible(
              scope,
              parent,
              type,
              selection,
              'Fragment "$name"',
            );
          }
        default:
          break;
      }
    }
    _checkFieldsCanMerge(scope, set, parent);
  }

  void _checkSpreadPossible(
    _Scope scope,
    SchemaType parent,
    SchemaType fragmentType,
    ast.Node at,
    String label,
  ) {
    final overlap = schema
        .possibleTypes(parent)
        .intersection(schema.possibleTypes(fragmentType));
    if (overlap.isEmpty) {
      _error(
        'impossible-fragment-spread',
        '$label can never apply to type "${parent.name}".',
        scope.path,
        at,
      );
    }
  }

  void _field(_Scope scope, ast.FieldNode node, SchemaType parent) {
    final name = node.name.value;
    _directives(scope, node.directives, ast.DirectiveLocation.field);
    final def = schema.field(parent, name);
    if (def == null) {
      if (name == '__schema' || name == '__type') {
        _error(
          'unsupported-introspection',
          'Introspection fields are not supported in generated operations.',
          scope.path,
          node,
        );
      } else {
        _error(
          'unknown-field',
          'Cannot query field "$name" on type "${parent.name}".',
          scope.path,
          node,
        );
      }
      return;
    }
    if (def.deprecationReason case final reason?) {
      _deprecated(
        scope,
        'deprecated-field',
        'Field "${parent.name}.$name" is deprecated: $reason',
        node,
      );
    }
    _arguments(
      scope,
      node.arguments,
      def.args,
      'field "${parent.name}.$name"',
      node,
    );

    final type = schema[def.type.namedType];
    if (type == null) return;
    final selectionSet = node.selectionSet;
    if (type.isLeaf) {
      if (selectionSet != null) {
        _error(
          'selection-on-leaf',
          'Field "$name" returns ${def.type} and must not have a selection set.',
          scope.path,
          node,
        );
      }
    } else if (selectionSet == null) {
      _error(
        'missing-selection',
        'Field "$name" returns ${def.type} and must have a selection of subfields.',
        scope.path,
        node,
      );
    } else {
      _selectionSet(scope, selectionSet, type);
    }
  }

  void _arguments(
    _Scope scope,
    List<ast.ArgumentNode> args,
    Map<String, InputValueDef> defs,
    String owner,
    ast.Node at,
  ) {
    final seen = <String>{};
    for (final arg in args) {
      final name = arg.name.value;
      if (!seen.add(name)) {
        _error(
          'duplicate-argument',
          'Argument "$name" is provided more than once.',
          scope.path,
          arg,
        );
        continue;
      }
      final def = defs[name];
      if (def == null) {
        _error(
          'unknown-argument',
          'Unknown argument "$name" on $owner.',
          scope.path,
          arg,
        );
        continue;
      }
      if (def.deprecationReason case final reason?) {
        _deprecated(
          scope,
          'deprecated-argument',
          'Argument "$name" of $owner is deprecated: $reason',
          arg,
        );
      }
      _value(
        scope,
        arg.value,
        def.type,
        arg,
        hasLocationDefault: def.defaultValue != null,
      );
    }
    for (final def in defs.values) {
      if (def.isRequired && !seen.contains(def.name)) {
        _error(
          'missing-argument',
          'Required argument "${def.name}: ${def.type}" of $owner is missing.',
          scope.path,
          at,
        );
      }
    }
  }

  void _directives(
    _Scope scope,
    List<ast.DirectiveNode> directives,
    ast.DirectiveLocation location,
  ) {
    final seen = <String>{};
    for (final d in directives) {
      final name = d.name.value;
      final def = schema.directives[name];
      if (def == null) {
        _error(
          'unknown-directive',
          'Unknown directive "@$name".',
          scope.path,
          d,
        );
        continue;
      }
      if (!def.locations.contains(location)) {
        _error(
          'misplaced-directive',
          'Directive "@$name" may not be used on ${location.name}.',
          scope.path,
          d,
        );
      }
      if (!seen.add(name) && !def.isRepeatable) {
        _error(
          'duplicate-directive',
          'Directive "@$name" may only be used once at this location.',
          scope.path,
          d,
        );
      }
      _arguments(scope, d.arguments, def.args, 'directive "@$name"', d);
    }
  }

  // ---------------------------------------------------------------------------
  // Values

  void _value(
    _Scope scope,
    ast.ValueNode value,
    TypeRef expected,
    ast.Node at, {
    bool hasLocationDefault = false,
    bool isConst = false,
  }) {
    void invalid(String reason) => _error(
      'invalid-value',
      'Expected a value of type $expected: $reason',
      scope.path,
      at,
    );

    if (value is ast.VariableNode) {
      if (isConst) {
        _error(
          'variable-in-const',
          'Variables are not allowed in default values.',
          scope.path,
          value,
        );
      } else {
        scope.variableUsages.add(
          _VariableUsage(value, expected, hasLocationDefault, scope.path),
        );
      }
      return;
    }
    if (value is ast.NullValueNode) {
      if (expected.isNonNull) invalid('null is not allowed.');
      return;
    }
    switch (expected) {
      case ListTypeRef(:final ofType):
        if (value is ast.ListValueNode) {
          for (final item in value.values) {
            _value(scope, item, ofType, at, isConst: isConst);
          }
        } else {
          _value(scope, value, ofType, at, isConst: isConst);
        }
        return;
      case NamedTypeRef(:final name):
        final type = schema[name];
        switch (type) {
          case ScalarType():
            final error = _checkScalarLiteral(type, value);
            if (error != null) invalid(error);
          case EnumType():
            if (value is! ast.EnumValueNode) {
              invalid('expected an enum value of "${type.name}".');
            } else if (type.values[value.name.value] case final enumValue?) {
              if (enumValue.deprecationReason case final reason?) {
                _deprecated(
                  scope,
                  'deprecated-enum-value',
                  'Enum value "${type.name}.${enumValue.name}" is deprecated: $reason',
                  value,
                );
              }
            } else {
              invalid(
                '"${value.name.value}" is not a value of enum "${type.name}".',
              );
            }
          case InputObjectType():
            _inputObject(scope, value, type, at, isConst: isConst);
          default:
            break; // Unknown/non-input types are reported elsewhere.
        }
    }
  }

  String? _checkScalarLiteral(ScalarType type, ast.ValueNode value) {
    final ok = switch (type.name) {
      'Int' => value is ast.IntValueNode && _isInt32(value.value),
      'Float' => value is ast.IntValueNode || value is ast.FloatValueNode,
      'String' => value is ast.StringValueNode,
      'Boolean' => value is ast.BooleanValueNode,
      'ID' => value is ast.StringValueNode || value is ast.IntValueNode,
      _ => true, // Custom scalars accept any literal; the server coerces.
    };
    if (ok) return null;
    if (type.name == 'Int' && value is ast.IntValueNode) {
      return '${value.value} is outside the 32-bit range of Int.';
    }
    return '${printExecutable(value)} is not a valid ${type.name}.';
  }

  static bool _isInt32(String literal) {
    final v = BigInt.tryParse(literal);
    return v != null &&
        v >= BigInt.from(-2147483648) &&
        v <= BigInt.from(2147483647);
  }

  void _inputObject(
    _Scope scope,
    ast.ValueNode value,
    InputObjectType type,
    ast.Node at, {
    required bool isConst,
  }) {
    if (value is! ast.ObjectValueNode) {
      _error(
        'invalid-value',
        'Expected an input object of type "${type.name}".',
        scope.path,
        at,
      );
      return;
    }
    final seen = <String>{};
    for (final field in value.fields) {
      final name = field.name.value;
      if (!seen.add(name)) {
        _error(
          'duplicate-input-field',
          'Input field "$name" is provided more than once.',
          scope.path,
          field,
        );
        continue;
      }
      final def = type.fields[name];
      if (def == null) {
        _error(
          'unknown-input-field',
          'Unknown field "$name" on input type "${type.name}".',
          scope.path,
          field,
        );
        continue;
      }
      if (def.deprecationReason case final reason?) {
        _deprecated(
          scope,
          'deprecated-input-field',
          'Input field "${type.name}.$name" is deprecated: $reason',
          field,
        );
      }
      _value(
        scope,
        field.value,
        def.type,
        field,
        hasLocationDefault: def.defaultValue != null,
        isConst: isConst,
      );
    }
    for (final def in type.fields.values) {
      if (def.isRequired && !seen.contains(def.name)) {
        _error(
          'missing-input-field',
          'Required field "${def.name}" of input type "${type.name}" is missing.',
          scope.path,
          at,
        );
      }
    }
    if (type.isOneOf) {
      final nonNullLiteral =
          value.fields.length == 1 &&
          value.fields.single.value is! ast.NullValueNode;
      if (!nonNullLiteral) {
        _error(
          'invalid-one-of',
          'Exactly one non-null field must be provided for @oneOf input "${type.name}".',
          scope.path,
          at,
        );
      } else if (!isConst && value.fields.single.value is ast.VariableNode) {
        // A @oneOf field may only be bound to a non-null variable; tighten the
        // recorded usage accordingly.
        final usage = scope.variableUsages.removeLast();
        scope.variableUsages.add(
          _VariableUsage(usage.node, usage.expected.nonNull, false, usage.path),
        );
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Field merging (5.3.2 "Field Selection Merging")

  final Set<(ast.FieldNode, ast.FieldNode)> _comparedPairs = {};

  void _checkFieldsCanMerge(
    _Scope scope,
    ast.SelectionSetNode set,
    SchemaType parent,
  ) {
    final fields = _collectFields(set, parent, {});
    for (final entry in fields.entries) {
      _checkFieldList(scope, entry.key, entry.value, mutuallyExclusive: false);
    }
  }

  void _checkFieldList(
    _Scope scope,
    String responseKey,
    List<_FieldInfo> fields, {
    required bool mutuallyExclusive,
  }) {
    for (var i = 0; i < fields.length; i++) {
      for (var j = i + 1; j < fields.length; j++) {
        _checkPair(
          scope,
          responseKey,
          fields[i],
          fields[j],
          mutuallyExclusive: mutuallyExclusive,
        );
      }
    }
  }

  void _checkPair(
    _Scope scope,
    String responseKey,
    _FieldInfo a,
    _FieldInfo b, {
    required bool mutuallyExclusive,
  }) {
    if (identical(a.node, b.node) || !_comparedPairs.add((a.node, b.node))) {
      return;
    }
    final exclusive =
        mutuallyExclusive ||
        (a.parent != b.parent &&
            a.parent is ObjectType &&
            b.parent is ObjectType);

    void conflict(String reason) => _error(
      'field-conflict',
      'Fields "$responseKey" conflict because $reason. Use different aliases.',
      scope.path,
      b.node,
    );

    if (!exclusive) {
      if (a.node.name.value != b.node.name.value) {
        conflict(
          '"${a.node.name.value}" and "${b.node.name.value}" are different fields',
        );
        return;
      }
      if (_argumentsKey(a.node.arguments) != _argumentsKey(b.node.arguments)) {
        conflict('they have differing arguments');
        return;
      }
    }
    final aType = a.def?.type;
    final bType = b.def?.type;
    if (aType != null && bType != null && !_sameResponseShape(aType, bType)) {
      conflict('they return conflicting types $aType and $bType');
      return;
    }
    final aSet = a.node.selectionSet;
    final bSet = b.node.selectionSet;
    if (aSet == null || bSet == null || aType == null || bType == null) return;
    final aParent = schema[aType.namedType];
    final bParent = schema[bType.namedType];
    if (aParent == null || bParent == null) return;
    final merged = <String, List<_FieldInfo>>{};
    for (final entry in [
      ..._collectFields(aSet, aParent, {}).entries,
      ..._collectFields(bSet, bParent, {}).entries,
    ]) {
      merged.putIfAbsent(entry.key, () => []).addAll(entry.value);
    }
    for (final entry in merged.entries) {
      _checkFieldList(
        scope,
        entry.key,
        entry.value,
        mutuallyExclusive: exclusive,
      );
    }
  }

  bool _sameResponseShape(TypeRef a, TypeRef b) {
    if (a.isNonNull || b.isNonNull) {
      if (a.isNonNull != b.isNonNull) return false;
      return _sameResponseShape(a.nullable, b.nullable);
    }
    if (a is ListTypeRef || b is ListTypeRef) {
      return a is ListTypeRef &&
          b is ListTypeRef &&
          _sameResponseShape(a.ofType, b.ofType);
    }
    final aType = schema[a.namedType];
    final bType = schema[b.namedType];
    if ((aType?.isLeaf ?? false) || (bType?.isLeaf ?? false)) {
      return a.namedType == b.namedType;
    }
    return true;
  }

  String _argumentsKey(List<ast.ArgumentNode> args) {
    final printed = args.map(printExecutable).toList()..sort();
    return printed.join(',');
  }

  Map<String, List<_FieldInfo>> _collectFields(
    ast.SelectionSetNode set,
    SchemaType parent,
    Set<String> visitedFragments,
  ) {
    final result = <String, List<_FieldInfo>>{};
    void collect(ast.SelectionSetNode set, SchemaType parent) {
      for (final selection in set.selections) {
        switch (selection) {
          case ast.FieldNode():
            final key = (selection.alias ?? selection.name).value;
            result
                .putIfAbsent(key, () => [])
                .add(
                  _FieldInfo(
                    parent,
                    selection,
                    schema.field(parent, selection.name.value),
                  ),
                );
          case ast.InlineFragmentNode():
            final type = selection.typeCondition == null
                ? parent
                : schema[selection.typeCondition!.on.name.value];
            if (type != null && type.isComposite) {
              collect(selection.selectionSet, type);
            }
          case ast.FragmentSpreadNode():
            final name = selection.name.value;
            if (!visitedFragments.add(name)) continue;
            final fragment = documents.fragments[name];
            if (fragment == null) continue;
            final type = schema[fragment.node.typeCondition.on.name.value];
            if (type != null && type.isComposite) {
              collect(fragment.node.selectionSet, type);
            }
          default:
            break;
        }
      }
    }

    collect(set, parent);
    return result;
  }
}
