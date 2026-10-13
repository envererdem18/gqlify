import 'package:gql/ast.dart' as ast;

/// A GraphQL type reference such as `[String!]!`.
sealed class TypeRef {
  const TypeRef(this.isNonNull);

  factory TypeRef.fromAst(ast.TypeNode node) => switch (node) {
    ast.NamedTypeNode(:final name, :final isNonNull) => NamedTypeRef(
      name.value,
      isNonNull: isNonNull,
    ),
    ast.ListTypeNode(:final type, :final isNonNull) => ListTypeRef(
      TypeRef.fromAst(type),
      isNonNull: isNonNull,
    ),
    _ => throw ArgumentError('Unknown type node $node'),
  };

  final bool isNonNull;

  /// The innermost named type.
  String get namedType;

  TypeRef get nullable;
  TypeRef get nonNull;

  @override
  String toString();
}

final class NamedTypeRef extends TypeRef {
  const NamedTypeRef(this.name, {bool isNonNull = false}) : super(isNonNull);

  final String name;

  @override
  String get namedType => name;

  @override
  TypeRef get nullable => isNonNull ? NamedTypeRef(name) : this;

  @override
  TypeRef get nonNull => isNonNull ? this : NamedTypeRef(name, isNonNull: true);

  @override
  bool operator ==(Object other) =>
      other is NamedTypeRef &&
      other.name == name &&
      other.isNonNull == isNonNull;

  @override
  int get hashCode => Object.hash(name, isNonNull);

  @override
  String toString() => isNonNull ? '$name!' : name;
}

final class ListTypeRef extends TypeRef {
  const ListTypeRef(this.ofType, {bool isNonNull = false}) : super(isNonNull);

  final TypeRef ofType;

  @override
  String get namedType => ofType.namedType;

  @override
  TypeRef get nullable => isNonNull ? ListTypeRef(ofType) : this;

  @override
  TypeRef get nonNull =>
      isNonNull ? this : ListTypeRef(ofType, isNonNull: true);

  @override
  bool operator ==(Object other) =>
      other is ListTypeRef &&
      other.ofType == ofType &&
      other.isNonNull == isNonNull;

  @override
  int get hashCode => Object.hash(ofType, isNonNull, 'list');

  @override
  String toString() => isNonNull ? '[$ofType]!' : '[$ofType]';
}
