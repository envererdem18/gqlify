/// Typed intermediate model between validated GraphQL and Dart emission.
///
/// Everything here is already named and resolved; emitters only render it.
library;

import 'package:gql/ast.dart' as ast;

import '../config.dart';

// -----------------------------------------------------------------------------
// Value types

/// A Dart-facing value type of a response field, variable or input field.
sealed class ValueType {
  const ValueType({required this.nullable});

  final bool nullable;

  /// The non-nullable Dart type.
  String get baseDartType;

  String get dartType => nullable ? '$baseDartType?' : baseDartType;

  ValueType asNullable();

  /// Whether encoding to JSON needs per-value conversion.
  bool get needsEncoding;
}

/// How a scalar maps to Dart.
final class ScalarMapping {
  const ScalarMapping({
    required this.dartType,
    required this.jsonType,
    this.fromJson,
    this.toJson,
    this.import,
  });

  final String dartType;
  final ScalarJsonType jsonType;
  final String? fromJson;
  final String? toJson;
  final String? import;

  static const string = ScalarMapping(
    dartType: 'String',
    jsonType: ScalarJsonType.string,
  );
  static const int_ = ScalarMapping(
    dartType: 'int',
    jsonType: ScalarJsonType.int_,
  );
  static const double_ = ScalarMapping(
    dartType: 'double',
    jsonType: ScalarJsonType.double_,
  );
  static const bool_ = ScalarMapping(
    dartType: 'bool',
    jsonType: ScalarJsonType.bool_,
  );
  static const json = ScalarMapping(
    dartType: 'Object',
    jsonType: ScalarJsonType.object,
  );
}

final class ScalarValue extends ValueType {
  const ScalarValue(this.graphqlType, this.mapping, {required super.nullable});

  final String graphqlType;
  final ScalarMapping mapping;

  @override
  String get baseDartType => mapping.dartType;

  @override
  bool get needsEncoding => mapping.toJson != null;

  @override
  ScalarValue asNullable() => ScalarValue(graphqlType, mapping, nullable: true);
}

final class EnumValue extends ValueType {
  const EnumValue(this.model, {required super.nullable});

  final EnumModel model;

  @override
  String get baseDartType => model.dartName;

  @override
  bool get needsEncoding => true;

  @override
  EnumValue asNullable() => EnumValue(model, nullable: true);
}

final class InputObjectValue extends ValueType {
  const InputObjectValue(this.model, {required super.nullable});

  final InputModel model;

  @override
  String get baseDartType => model.dartName;

  @override
  bool get needsEncoding => true;

  @override
  InputObjectValue asNullable() => InputObjectValue(model, nullable: true);
}

/// A selection on a composite type: a generated response class, sealed
/// hierarchy or fragment interface.
final class ObjectValue extends ValueType {
  const ObjectValue(this.dartName, {required super.nullable});

  final String dartName;

  @override
  String get baseDartType => dartName;

  @override
  bool get needsEncoding => true;

  @override
  ObjectValue asNullable() => ObjectValue(dartName, nullable: true);
}

final class ListValue extends ValueType {
  const ListValue(this.item, {required super.nullable});

  final ValueType item;

  @override
  String get baseDartType => 'List<${item.dartType}>';

  @override
  bool get needsEncoding => item.needsEncoding;

  @override
  ListValue asNullable() => ListValue(item, nullable: true);
}

// -----------------------------------------------------------------------------
// Schema types

final class EnumModel {
  EnumModel({
    required this.graphqlName,
    required this.dartName,
    required this.values,
    this.description,
  });

  final String graphqlName;
  final String dartName;
  final List<EnumValueModel> values;
  final String? description;
}

final class EnumValueModel {
  EnumValueModel({
    required this.graphqlName,
    required this.dartName,
    this.description,
    this.deprecationReason,
  });

  final String graphqlName;
  final String dartName;
  final String? description;
  final String? deprecationReason;
}

final class InputModel {
  InputModel({
    required this.graphqlName,
    required this.dartName,
    required this.isOneOf,
    this.description,
  });

  final String graphqlName;
  final String dartName;
  final bool isOneOf;
  final String? description;

  /// Filled after creation so that recursive input types can refer to their
  /// own model.
  final List<InputFieldModel> fields = [];
}

/// An input-object field or an operation variable.
final class InputFieldModel {
  InputFieldModel({
    required this.graphqlName,
    required this.dartName,
    required this.type,
    required this.hasDefault,
    this.description,
    this.deprecationReason,
  });

  final String graphqlName;
  final String dartName;

  /// Type of the GraphQL value (non-null for `T!`).
  final ValueType type;
  final bool hasDefault;
  final String? description;
  final String? deprecationReason;

  /// Must be supplied: non-null without a default.
  bool get isRequired => !type.nullable && !hasDefault;

  /// May be sent as an explicit `null`.
  bool get acceptsNull => type.nullable;

  /// Dart type of the constructor parameter and field.
  String get parameterType =>
      isRequired ? type.dartType : type.asNullable().dartType;
}

// -----------------------------------------------------------------------------
// Selections

/// A field of a response class or fragment interface.
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

/// A generated type for a selection set.
sealed class SelectionType {
  SelectionType(this.dartName, this.graphqlType);

  final String dartName;

  /// The GraphQL type the selection is made on.
  final String graphqlType;

  /// Fragment interfaces (and, for variants, nothing else) implemented.
  final List<String> implements = [];

  /// Canonical emission order within a library: the index of the definition
  /// (operation or fragment) in its document, then creation order while
  /// building that definition. Independent of other documents.
  int group = 0;
  int seq = 0;
}

/// A concrete, decodable response class.
final class SelectionClass extends SelectionType {
  SelectionClass(
    super.dartName,
    super.graphqlType,
    this.fields, {
    this.superclass,
  });

  final List<FieldModel> fields;

  /// Sealed base this class is a variant of.
  final String? superclass;
}

/// A sealed hierarchy decoded by `__typename`.
final class SealedSelection extends SelectionType {
  SealedSelection(
    super.dartName,
    super.graphqlType, {
    required this.baseFields,
    required this.variants,
    required this.other,
  });

  /// Fields with one type in every variant, exposed as abstract getters.
  final List<FieldModel> baseFields;

  /// Variant per object type with a type-specific selection, by type name.
  final Map<String, SelectionClass> variants;

  /// Variant for every other type, including types unknown at build time.
  final SelectionClass other;
}

/// An `abstract interface class` for a fragment (or a nested selection of
/// one). Response classes implement it when they spread the fragment.
final class FragmentInterface extends SelectionType {
  FragmentInterface(
    super.dartName,
    super.graphqlType,
    this.fields, {
    this.description,
  });

  final List<FieldModel> fields;
  final String? description;
}

// -----------------------------------------------------------------------------
// Libraries

final class OperationModel {
  OperationModel({
    required this.name,
    required this.type,
    required this.descriptorName,
    required this.methodName,
    required this.extensionName,
    required this.documentConstName,
    required this.dataName,
    required this.variables,
    required this.document,
    required this.clientName,
  });

  /// The generated client class the method is added to.
  final String clientName;

  final String name;
  final ast.OperationType type;
  final String descriptorName;
  final String methodName;
  final String extensionName;
  final String documentConstName;

  /// Root response class.
  final String dataName;
  final List<InputFieldModel> variables;

  /// Printed document: the operation plus transitive fragments.
  final String document;
}

/// A generated library.
final class LibraryModel {
  LibraryModel({required this.outputPath, required this.sourcePaths});

  final String outputPath;
  final List<String> sourcePaths;

  /// Other generated libraries referenced by this one (output paths).
  final Set<String> imports = {};

  /// Source documents (besides the schema and configuration, which every
  /// library depends on) whose content can affect this library.
  final Set<String> dependencies = {};

  /// Extra imports for custom scalars.
  final Set<String> scalarImports = {};

  final List<OperationModel> operations = [];

  /// Response classes, sealed hierarchies and fragment interfaces, in
  /// emission order.
  final List<SelectionType> selections = [];

  // Schema library only.
  String? clientName;
  final List<EnumModel> enums = [];
  final List<InputModel> inputs = [];

  bool get isEmpty =>
      operations.isEmpty &&
      selections.isEmpty &&
      clientName == null &&
      enums.isEmpty &&
      inputs.isEmpty;
}

/// Everything one generation produces.
final class GenerationModel {
  GenerationModel(this.libraries);

  final List<LibraryModel> libraries;
}
