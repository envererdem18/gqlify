import 'package:gql/ast.dart' as ast;

import 'type_ref.dart';

const builtInScalars = {'Int', 'Float', 'String', 'Boolean', 'ID'};

/// A named type of the schema.
sealed class SchemaType {
  SchemaType(this.name, {this.description, this.node});

  final String name;
  final String? description;

  /// Defining AST node, for diagnostics. `null` for built-ins/introspection.
  final ast.Node? node;

  bool get isInputType =>
      this is ScalarType || this is EnumType || this is InputObjectType;
  bool get isOutputType => this is! InputObjectType;
  bool get isLeaf => this is ScalarType || this is EnumType;
  bool get isComposite =>
      this is ObjectType || this is InterfaceType || this is UnionType;
  bool get isAbstract => this is InterfaceType || this is UnionType;
}

final class ScalarType extends SchemaType {
  ScalarType(super.name, {super.description, super.node});

  bool get isBuiltIn => builtInScalars.contains(name);
}

/// Shared shape of object and interface types.
sealed class FieldsType extends SchemaType {
  FieldsType(super.name, {super.description, super.node});

  final Map<String, FieldDef> fields = {};
  final List<String> interfaces = [];
}

final class ObjectType extends FieldsType {
  ObjectType(super.name, {super.description, super.node});
}

final class InterfaceType extends FieldsType {
  InterfaceType(super.name, {super.description, super.node});
}

final class UnionType extends SchemaType {
  UnionType(super.name, {super.description, super.node});

  final List<String> members = [];
}

final class EnumType extends SchemaType {
  EnumType(super.name, {super.description, super.node});

  final Map<String, EnumValueDef> values = {};
}

final class InputObjectType extends SchemaType {
  InputObjectType(super.name, {super.description, super.node});

  final Map<String, InputValueDef> fields = {};
  bool isOneOf = false;
}

final class FieldDef {
  FieldDef(
    this.name,
    this.type, {
    this.description,
    this.deprecationReason,
    this.node,
  });

  final String name;
  final TypeRef type;
  final String? description;
  final String? deprecationReason;
  final Map<String, InputValueDef> args = {};
  final ast.Node? node;
}

final class InputValueDef {
  InputValueDef(
    this.name,
    this.type, {
    this.defaultValue,
    this.description,
    this.deprecationReason,
    this.node,
  });

  final String name;
  final TypeRef type;
  final ast.ValueNode? defaultValue;
  final String? description;
  final String? deprecationReason;
  final ast.Node? node;

  bool get isRequired => type.isNonNull && defaultValue == null;
}

final class EnumValueDef {
  EnumValueDef(this.name, {this.description, this.deprecationReason});

  final String name;
  final String? description;
  final String? deprecationReason;
}

final class DirectiveDef {
  DirectiveDef(this.name, this.locations, {this.isRepeatable = false});

  final String name;
  final Set<ast.DirectiveLocation> locations;
  final bool isRepeatable;
  final Map<String, InputValueDef> args = {};
}

/// A validated, immutable-by-convention GraphQL schema.
final class Schema {
  Schema({
    required this.types,
    required this.directives,
    required this.queryType,
    this.mutationType,
    this.subscriptionType,
  });

  final Map<String, SchemaType> types;
  final Map<String, DirectiveDef> directives;
  final String queryType;
  final String? mutationType;
  final String? subscriptionType;

  SchemaType? operator [](String name) => types[name];

  String? rootTypeName(ast.OperationType type) => switch (type) {
    ast.OperationType.query => queryType,
    ast.OperationType.mutation => mutationType,
    ast.OperationType.subscription => subscriptionType,
  };

  final Map<String, Set<String>> _possibleTypes = {};

  /// Object types that [type] may resolve to at runtime.
  Set<String> possibleTypes(SchemaType type) => _possibleTypes.putIfAbsent(
    type.name,
    () => switch (type) {
      ObjectType() => {type.name},
      UnionType(:final members) => {...members},
      InterfaceType() => {
        for (final t in types.values)
          if (t is ObjectType && t.interfaces.contains(type.name)) t.name,
      },
      _ => const {},
    },
  );

  /// Field [name] of composite [type], including meta field `__typename`.
  FieldDef? field(SchemaType type, String name) {
    if (name == '__typename' && type.isComposite) return typenameField;
    return type is FieldsType ? type.fields[name] : null;
  }

  static final typenameField = FieldDef(
    '__typename',
    const NamedTypeRef('String', isNonNull: true),
  );
}

extension SchemaTyping on Schema {
  /// Whether [sub] may be used where [sup] is expected in output position
  /// (field type covariance for interface implementations).
  bool isSubtype(TypeRef sub, TypeRef sup) {
    if (sup.isNonNull) {
      return sub.isNonNull && isSubtype(sub.nullable, sup.nullable);
    }
    if (sub.isNonNull) return isSubtype(sub.nullable, sup);
    if (sup is ListTypeRef) {
      return sub is ListTypeRef && isSubtype(sub.ofType, sup.ofType);
    }
    if (sub is ListTypeRef) return false;
    final subName = (sub as NamedTypeRef).name;
    final supName = (sup as NamedTypeRef).name;
    if (subName == supName) return true;
    final supType = types[supName];
    final subType = types[subName];
    return switch (supType) {
      UnionType(:final members) => members.contains(subName),
      InterfaceType() =>
        subType is FieldsType && subType.interfaces.contains(supName),
      _ => false,
    };
  }
}
