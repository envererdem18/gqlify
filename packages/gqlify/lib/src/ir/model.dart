/// Typed intermediate model between validated GraphQL and Dart emission.
///
/// Everything here is already named and resolved; emitters only render it.
library;

import 'package:gql/ast.dart' as ast;

/// A Dart-facing value type of a response field or variable.
sealed class ValueType {
  const ValueType({required this.nullable});

  final bool nullable;

  /// Whether encoding to JSON requires converting nested objects.
  bool get containsObject;

  String get dartType;
}

/// A leaf value: a scalar mapped to a Dart type.
final class ScalarValue extends ValueType {
  const ScalarValue(
    this.graphqlType,
    this.baseDartType, {
    required super.nullable,
  });

  final String graphqlType;

  /// `String`, `int`, `double`, `bool` or `Object` (unmapped custom scalar).
  final String baseDartType;

  bool get isFloat => baseDartType == 'double';

  @override
  bool get containsObject => false;

  @override
  String get dartType => nullable ? '$baseDartType?' : baseDartType;
}

/// A selection on a composite type, rendered as a generated class.
final class ObjectValue extends ValueType {
  const ObjectValue(this.selection, {required super.nullable});

  final SelectionClass selection;

  @override
  bool get containsObject => true;

  @override
  String get dartType =>
      nullable ? '${selection.dartName}?' : selection.dartName;
}

final class ListValue extends ValueType {
  const ListValue(this.item, {required super.nullable});

  final ValueType item;

  @override
  bool get containsObject => item.containsObject;

  @override
  String get dartType => 'List<${item.dartType}>${nullable ? '?' : ''}';
}

/// A generated response class for one selection set.
final class SelectionClass {
  SelectionClass(this.dartName, this.graphqlType, this.fields);

  final String dartName;
  final String graphqlType;
  final List<FieldModel> fields;
}

final class FieldModel {
  FieldModel({
    required this.responseKey,
    required this.dartName,
    required this.type,
    this.description,
    this.deprecationReason,
  });

  /// JSON key in the response (alias or field name).
  final String responseKey;
  final String dartName;
  final ValueType type;
  final String? description;
  final String? deprecationReason;
}

final class VariableModel {
  VariableModel({
    required this.graphqlName,
    required this.dartName,
    required this.type,
    required this.hasDefault,
  });

  final String graphqlName;
  final String dartName;

  /// Dart type of the variable *value*; for optional variables the parameter
  /// is nullable even when the GraphQL type is non-null (a default applies).
  final ValueType type;
  final bool hasDefault;

  /// Must be supplied by the caller (non-null without default).
  bool get isRequired => !type.nullable && !hasDefault;

  String get parameterType =>
      isRequired || type.nullable ? type.dartType : '${type.dartType}?';
}

final class OperationModel {
  OperationModel({
    required this.name,
    required this.type,
    required this.descriptorName,
    required this.methodName,
    required this.extensionName,
    required this.documentConstName,
    required this.data,
    required this.variables,
    required this.document,
  });

  final String name;
  final ast.OperationType type;
  final String descriptorName;
  final String methodName;
  final String extensionName;
  final String documentConstName;

  /// Root class; all nested classes are reachable from it.
  final SelectionClass data;
  final List<VariableModel> variables;

  /// Printed document: the operation plus transitive fragments.
  final String document;
}

/// The generated library for one operation document.
final class DocumentLibrary {
  DocumentLibrary({
    required this.sourcePath,
    required this.outputPath,
    required this.operations,
  });

  final String sourcePath;
  final String outputPath;
  final List<OperationModel> operations;
}

/// Everything one generation produces.
final class GenerationModel {
  GenerationModel({
    required this.schemaOutputPath,
    required this.schemaSourcePaths,
    required this.clientName,
    required this.documents,
  });

  final String schemaOutputPath;
  final List<String> schemaSourcePaths;
  final String clientName;
  final List<DocumentLibrary> documents;
}
