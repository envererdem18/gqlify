import 'package:gql/ast.dart' as ast;

import '../diagnostics.dart';
import '../emit/naming.dart';
import '../schema/schema.dart';
import '../schema/type_ref.dart';
import 'model.dart';
import 'naming_registry.dart';

/// Members of generated response classes and fragment interfaces that
/// fields must not shadow.
const selectionMembers = {...objectMembers, 'toJson', 'fromJson'};

/// Resolves leaf types for the selection builder.
abstract interface class LeafTypes {
  ValueType? leaf(
    SchemaType type, {
    required bool nullable,
    required ast.Node at,
  });
}

/// One occurrence of a field in a merged selection.
final class _Occurrence {
  _Occurrence(this.node, this.conditional);

  final ast.FieldNode node;

  /// Whether @skip/@include (on the field or an enclosing fragment) may
  /// exclude this occurrence from the response.
  final bool conditional;
}

/// A selection set to merge, with the conditionality inherited from its
/// enclosing field occurrence.
typedef SelectionSetRef = ({ast.SelectionSetNode set, bool conditional});

/// Types already built for a response key in a sibling case, reusable when a
/// variant has the same occurrences and the same field type (object types
/// may narrow interface field types covariantly).
typedef _Reuse =
    Map<
      String,
      ({
        List<_Occurrence> occurrences,
        TypeRef fieldType,
        ValueType type,
        InterfaceInfo? info,
      })
    >;

/// Fields and fragments that apply for one runtime type.
final class _Collected {
  final Map<String, List<_Occurrence>> fields = {};
  final List<String> fragments = [];

  bool sameAs(_Collected other) {
    if (fields.length != other.fields.length) return false;
    if (fragments.length != other.fragments.length) return false;
    for (var i = 0; i < fragments.length; i++) {
      if (fragments[i] != other.fragments[i]) return false;
    }
    for (final MapEntry(:key, :value) in fields.entries) {
      final theirs = other.fields[key];
      if (theirs == null || !_sameOccurrences(value, theirs)) return false;
    }
    return true;
  }
}

bool _sameOccurrences(List<_Occurrence> a, List<_Occurrence> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (!identical(a[i].node, b[i].node) ||
        a[i].conditional != b[i].conditional) {
      return false;
    }
  }
  return true;
}

/// A fragment interface (or a nested interface of one) that a selection may
/// have to implement.
final class InterfaceInfo {
  InterfaceInfo(this.name, this.library, this.source);

  final String name;

  /// Output path of the library declaring it.
  final String library;

  /// Source document defining the fragment.
  final String source;

  /// Narrower interfaces for specific runtime types (polymorphic fragments).
  final Map<String, InterfaceInfo> variants = {};

  /// Nested interfaces of object fields, by response key.
  final Map<String, InterfaceInfo> nested = {};

  InterfaceInfo forType(String? concreteType) =>
      (concreteType == null ? null : variants[concreteType]) ?? this;
}

/// Builds response classes, sealed hierarchies and fragment interfaces.
final class SelectionBuilder {
  SelectionBuilder({
    required this.schema,
    required this.fragments,
    required this.fragmentLibraries,
    required this.leafTypes,
    required this.names,
    required this.sink,
  });

  final Schema schema;

  /// Fragment definitions (with `__typename` added) by name.
  final Map<String, ast.FragmentDefinitionNode> fragments;

  /// Library output path and source path of each fragment.
  final Map<String, ({String output, String source, int index})>
  fragmentLibraries;
  final LeafTypes leafTypes;
  final NamingRegistry names;
  final DiagnosticSink sink;

  final Map<String, InterfaceInfo> _fragmentInfos = {};

  /// Libraries by output path, created by the caller.
  final Map<String, LibraryModel> libraries = {};

  /// Definition index (in its document) of the definition being built; see
  /// [SelectionType.group].
  int group = 0;
  int _seq = 0;

  void _add(String library, SelectionType type, {int? seq}) {
    type
      ..group = group
      ..seq = seq ?? _seq++;
    _library(library).selections.add(type);
  }

  // ---------------------------------------------------------------------------
  // Collection

  /// Whether a selection with type condition [condition], written in a
  /// context of static type [static], applies when the runtime type is
  /// [concrete] (`null`: a type without a dedicated variant, possibly unknown
  /// at build time).
  bool _applies(SchemaType condition, SchemaType static, String? concrete) {
    if (concrete != null) {
      return schema.possibleTypes(condition).contains(concrete);
    }
    if (condition.name == static.name) return true;
    if (static is ObjectType) {
      return schema.possibleTypes(condition).contains(static.name);
    }
    // An unknown implementation of interface [static] is guaranteed to
    // implement [condition] only if [static] itself does.
    return static is FieldsType && static.interfaces.contains(condition.name);
  }

  _Collected _collect(
    SchemaType static,
    String? concrete,
    List<SelectionSetRef> sets,
  ) {
    final result = _Collected();
    void visit(ast.SelectionSetNode set, bool conditional) {
      for (final selection in set.selections) {
        switch (selection) {
          case ast.FieldNode():
            final key = (selection.alias ?? selection.name).value;
            result.fields
                .putIfAbsent(key, () => [])
                .add(
                  _Occurrence(
                    selection,
                    conditional || isConditional(selection.directives),
                  ),
                );
          case ast.InlineFragmentNode():
            final condition = selection.typeCondition == null
                ? static
                : schema[selection.typeCondition!.on.name.value]!;
            if (_applies(condition, static, concrete)) {
              visit(
                selection.selectionSet,
                conditional || isConditional(selection.directives),
              );
            }
          case ast.FragmentSpreadNode():
            final fragment = fragments[selection.name.value]!;
            final condition = schema[fragment.typeCondition.on.name.value]!;
            if (_applies(condition, static, concrete)) {
              final spreadConditional =
                  conditional || isConditional(selection.directives);
              if (!spreadConditional &&
                  !result.fragments.contains(selection.name.value)) {
                result.fragments.add(selection.name.value);
              }
              visit(fragment.selectionSet, spreadConditional);
            }
          default:
            break;
        }
      }
    }

    for (final s in sets) {
      visit(s.set, s.conditional);
    }
    return result;
  }

  /// Runtime types that need their own variant, sorted, or empty if the
  /// selection is not polymorphic.
  Map<String, _Collected> _variants(
    SchemaType static,
    List<SelectionSetRef> sets,
    _Collected other,
  ) {
    if (!static.isAbstract) return const {};
    final variants = <String, _Collected>{};
    for (final type in schema.possibleTypes(static).toList()..sort()) {
      final collected = _collect(static, type, sets);
      if (!collected.sameAs(other)) variants[type] = collected;
    }
    return variants;
  }

  // ---------------------------------------------------------------------------
  // Fragment interfaces

  /// The interface of fragment [name], built on first use.
  InterfaceInfo fragmentInterface(String name) {
    final existing = _fragmentInfos[name];
    if (existing != null) return existing;
    final fragment = fragments[name]!;
    final location = fragmentLibraries[name]!;
    final type = schema[fragment.typeCondition.on.name.value]!;
    final outerGroup = group;
    group = location.index;
    final info = _interface(
      dartName: escapeType(pascalCase(name)),
      static: type,
      sets: [(set: fragment.selectionSet, conditional: false)],
      required: const [],
      library: location.output,
      origin: 'fragment "$name"',
      at: fragment.name,
      path: location.source,
      description: 'Fragment `$name` on `${type.name}`.',
    );
    group = outerGroup;
    _fragmentInfos[name] = info;
    return info;
  }

  InterfaceInfo _interface({
    required String dartName,
    required SchemaType static,
    required List<SelectionSetRef> sets,
    required List<InterfaceInfo> required,
    required String library,
    required String origin,
    required ast.Node at,
    required String path,
    String? description,
  }) {
    names.claim(dartName, origin, path: path, at: at);
    final other = _collect(static, null, sets);
    final info = InterfaceInfo(dartName, library, path);

    final common = FragmentInterface(
      dartName,
      static.name,
      [],
      description: description,
    );
    final commonRequired = [
      for (final r in required) r.forType(null),
      for (final f in other.fragments) fragmentInterface(f),
    ];
    _implement(common, commonRequired, library);
    final reuse = _Reuse();
    common.fields.addAll(
      _fields(
        collected: other,
        parent: static,
        prefix: dartName,
        required: commonRequired,
        library: library,
        origin: origin,
        path: path,
        asInterface: true,
        nested: info.nested,
        reuse: reuse,
      ),
    );
    _add(library, common);

    for (final MapEntry(key: type, value: collected) in _variants(
      static,
      sets,
      other,
    ).entries) {
      final variantName = '$dartName\$${pascalCase(type)}';
      names.claim(variantName, origin, path: path, at: at);
      final variant = FragmentInterface(variantName, type, []);
      final variantInfo = InterfaceInfo(variantName, library, path);
      final variantRequired = [
        info, // Variants refine the common interface.
        for (final r in required) r.forType(type),
        for (final f in collected.fragments) fragmentInterface(f).forType(type),
      ];
      _implement(variant, variantRequired, library);
      variant.fields.addAll(
        _fields(
          collected: collected,
          parent: schema[type]!,
          prefix: variantName,
          required: variantRequired,
          library: library,
          origin: origin,
          path: path,
          asInterface: true,
          nested: variantInfo.nested,
          reuse: reuse,
        ),
      );
      _add(library, variant);
      info.variants[type] = variantInfo;
    }
    return info;
  }

  // ---------------------------------------------------------------------------
  // Response classes

  /// Builds the response type for [sets] on [static] and returns its name.
  String responseType({
    required String dartName,
    required String nestedPrefix,
    required SchemaType static,
    required List<SelectionSetRef> sets,
    required List<InterfaceInfo> required,
    required String library,
    required String origin,
    required ast.Node at,
    required String path,
  }) {
    names.claim(dartName, origin, path: path, at: at);
    final other = _collect(static, null, sets);
    final variants = _variants(static, sets, other);

    if (variants.isEmpty) {
      final concrete = static is ObjectType ? static.name : null;
      final caseRequired = [
        for (final r in required) r.forType(concrete),
        for (final f in other.fragments) fragmentInterface(f).forType(concrete),
      ];
      final cls = SelectionClass(dartName, static.name, []);
      _implement(cls, caseRequired, library);
      _add(library, cls);
      cls.fields.addAll(
        _fields(
          collected: other,
          parent: static,
          prefix: nestedPrefix,
          required: caseRequired,
          library: library,
          origin: origin,
          path: path,
          asInterface: false,
        ),
      );
      return dartName;
    }

    // Polymorphic: sealed base + one class per variant + fallback.
    final reuse = _Reuse();
    final baseRequired = [
      for (final r in required) r.forType(null),
      for (final f in other.fragments) fragmentInterface(f),
    ];
    final otherName = '$dartName\$Other';
    names.claim(otherName, origin, path: path, at: at);
    final otherClass = SelectionClass(
      otherName,
      static.name,
      [],
      superclass: dartName,
    );
    final sealedSeq = _seq++;
    _add(library, otherClass);
    otherClass.fields.addAll(
      _fields(
        collected: other,
        parent: static,
        prefix: nestedPrefix,
        required: baseRequired,
        library: library,
        origin: origin,
        path: path,
        asInterface: false,
        reuse: reuse,
      ),
    );

    final variantClasses = <String, SelectionClass>{};
    for (final MapEntry(key: type, value: collected) in variants.entries) {
      final variantName = '$dartName\$${pascalCase(type)}';
      names.claim(variantName, origin, path: path, at: at);
      final caseRequired = [
        for (final r in required) r.forType(type),
        for (final f in collected.fragments) fragmentInterface(f).forType(type),
      ];
      final cls = SelectionClass(variantName, type, [], superclass: dartName);
      _implement(cls, caseRequired, library);
      _add(library, cls);
      cls.fields.addAll(
        _fields(
          collected: collected,
          parent: schema[type]!,
          prefix: variantName,
          required: caseRequired,
          library: library,
          origin: origin,
          path: path,
          asInterface: false,
          reuse: reuse,
        ),
      );
      variantClasses[type] = cls;
    }

    // Getters on the base for fields every variant types identically.
    final all = [otherClass, ...variantClasses.values];
    final baseFields = [
      for (final field in otherClass.fields)
        if (all.every(
          (c) => c.fields.any(
            (f) =>
                f.responseKey == field.responseKey &&
                f.type.dartType == field.type.dartType,
          ),
        ))
          field,
    ];
    final sealed = SealedSelection(
      dartName,
      static.name,
      baseFields: baseFields,
      variants: variantClasses,
      other: otherClass,
    );
    _implement(sealed, baseRequired, library);
    _add(library, sealed, seq: sealedSeq);
    return dartName;
  }

  // ---------------------------------------------------------------------------
  // Fields

  List<FieldModel> _fields({
    required _Collected collected,
    required SchemaType parent,
    required String prefix,
    required List<InterfaceInfo> required,
    required String library,
    required String origin,
    required String path,
    required bool asInterface,
    Map<String, InterfaceInfo>? nested,
    _Reuse? reuse,
  }) {
    final fields = <FieldModel>[];
    final dartNames = <String, String>{};
    for (final MapEntry(key: responseKey, value: occurrences)
        in collected.fields.entries) {
      final first = occurrences.first.node;
      final def = schema.field(parent, first.name.value)!;
      final dartName = escapeMember(camelCase(responseKey), selectionMembers);
      final previous = dartNames[dartName];
      if (previous != null) {
        sink.error(
          'name-collision',
          'Response keys "$previous" and "$responseKey" both map to Dart field '
              '"$dartName" in $origin. Use an alias for one of them.',
          path: path,
          at: first,
        );
        continue;
      }
      dartNames[dartName] = responseKey;

      ValueType? type;
      final reused = reuse?[responseKey];
      if (reused != null &&
          reused.fieldType == def.type &&
          _sameOccurrences(reused.occurrences, occurrences)) {
        type = reused.type;
        if (reused.info case final info?) nested?[responseKey] = info;
      } else {
        final childRequired = [
          for (final r in required) ?r.nested[responseKey],
        ];
        final childSets = [
          for (final o in occurrences)
            if (o.node.selectionSet case final set?)
              (set: set, conditional: o.conditional),
        ];
        InterfaceInfo? nestedInfo;
        type = _valueType(
          def.type,
          className: '$prefix${pascalCase(responseKey)}',
          childSets: childSets,
          required: childRequired,
          library: library,
          origin: 'field "$responseKey" of $origin',
          path: path,
          at: first,
          asInterface: asInterface,
          onInterface: (info) => nestedInfo = info,
        );
        if (type == null) continue;
        if (occurrences.every((o) => o.conditional)) type = type.asNullable();
        if (nestedInfo case final info?) nested?[responseKey] = info;
        reuse?.putIfAbsent(
          responseKey,
          () => (
            occurrences: occurrences,
            fieldType: def.type,
            type: type!,
            info: nestedInfo,
          ),
        );
      }
      fields.add(
        FieldModel(
          responseKey: responseKey,
          dartName: dartName,
          type: type,
          description: def.description,
          deprecationReason: def.deprecationReason,
        ),
      );
    }
    return fields;
  }

  ValueType? _valueType(
    TypeRef ref, {
    required String className,
    required List<SelectionSetRef> childSets,
    required List<InterfaceInfo> required,
    required String library,
    required String origin,
    required String path,
    required ast.Node at,
    required bool asInterface,
    required void Function(InterfaceInfo) onInterface,
  }) {
    final nullable = !ref.isNonNull;
    switch (ref) {
      case ListTypeRef(:final ofType):
        final item = _valueType(
          ofType,
          className: className,
          childSets: childSets,
          required: required,
          library: library,
          origin: origin,
          path: path,
          at: at,
          asInterface: asInterface,
          onInterface: onInterface,
        );
        return item == null ? null : ListValue(item, nullable: nullable);
      case NamedTypeRef(:final name):
        final type = schema[name]!;
        if (type.isLeaf) {
          return leafTypes.leaf(type, nullable: nullable, at: at);
        }
        final dartName = escapeType(className);
        if (asInterface) {
          final info = _interface(
            dartName: dartName,
            static: type,
            sets: childSets,
            required: required,
            library: library,
            origin: origin,
            at: at,
            path: path,
          );
          onInterface(info);
          return ObjectValue(dartName, nullable: nullable);
        }
        responseType(
          dartName: dartName,
          nestedPrefix: dartName,
          static: type,
          sets: childSets,
          required: required,
          library: library,
          origin: origin,
          at: at,
          path: path,
        );
        return ObjectValue(dartName, nullable: nullable);
    }
  }

  void _implement(
    SelectionType type,
    List<InterfaceInfo> interfaces,
    String library,
  ) {
    for (final i in interfaces) {
      if (type.implements.contains(i.name) || i.name == type.dartName) continue;
      type.implements.add(i.name);
      if (i.library != library) _library(library).imports.add(i.library);
    }
  }

  LibraryModel _library(String outputPath) => libraries[outputPath]!;

  /// Starts a selection set list for [set].
  static List<SelectionSetRef> rootSets(ast.SelectionSetNode set) => [
    (set: set, conditional: false),
  ];
}

/// Whether [directives] contain @skip/@include that may exclude the node.
bool isConditional(List<ast.DirectiveNode> directives) {
  for (final d in directives) {
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
