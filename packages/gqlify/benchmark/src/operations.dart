import 'dart:math';

import 'package:gqlify/gqlify.dart';
import 'package:gqlify/src/documents/document_set.dart';
import 'package:gqlify/src/documents/validator.dart';
import 'package:gqlify/src/schema/schema.dart';

/// Generates realistic, *valid* operation documents for any schema:
/// queries over root fields with variables for required arguments, nested
/// selections, inline fragments on abstract types and shared named
/// fragments. Every operation is checked with gqlify's validator; invalid
/// candidates are discarded, so benchmarks only measure valid input.
final class OperationGenerator {
  OperationGenerator(this.schema, this.random);

  final Schema schema;
  final Random random;
  final Map<String, ({String type, String body})> _fragments = {};
  int _alias = 0;

  /// Returns document path -> content.
  Map<String, String> generate({
    required int documents,
    required int operationsPerDocument,
    required int fragments,
  }) {
    final candidates = _compositeTypes();
    for (var i = 0; _fragments.length < fragments && i < fragments * 20; i++) {
      final type = candidates[random.nextInt(candidates.length)];
      final body = _selection(type, depth: 2, spreads: false);
      if (body.isEmpty) continue;
      final name = 'Frag${_fragments.length}';
      if (_valid(
        'fragment $name on ${type.name} { $body }',
        withOperation: false,
      )) {
        _fragments[name] = (type: type.name, body: body);
      }
    }

    final out = <String, String>{};
    var f = 0;
    for (final MapEntry(key: name, value: frag) in _fragments.entries) {
      final path = 'lib/graphql/fragments/f${f++ % 10}.graphql';
      out[path] =
          '${out[path] ?? ''}fragment $name on ${frag.type} { ${frag.body} }\n';
    }

    final root = schema[schema.queryType]! as ObjectType;
    final roots = [
      for (final field in root.fields.values)
        if (schema[field.type.namedType]!.isComposite) field,
    ];
    var op = 0;
    for (var d = 0; d < documents; d++) {
      final ops = StringBuffer();
      var made = 0;
      for (
        var attempt = 0;
        made < operationsPerDocument && attempt < operationsPerDocument * 30;
        attempt++
      ) {
        final field = roots[random.nextInt(roots.length)];
        final text = _operation('Op$op', field);
        if (text == null || !_valid(text, withOperation: true)) continue;
        ops.writeln(text);
        op++;
        made++;
      }
      out['lib/graphql/ops/d$d.graphql'] = ops.toString();
    }
    return out;
  }

  List<SchemaType> _compositeTypes() => [
    for (final t in schema.types.values)
      if ((t is ObjectType || t is InterfaceType) &&
          !t.name.startsWith('__') &&
          t.name != schema.queryType &&
          t.name != schema.mutationType)
        t,
  ];

  String? _operation(String name, FieldDef field) {
    final variables = <String>[];
    final args = <String>[];
    for (final arg in field.args.values) {
      if (!arg.isRequired && random.nextInt(3) > 0) continue;
      variables.add('\$${arg.name}: ${arg.type}');
      args.add('${arg.name}: \$${arg.name}');
    }
    final type = schema[field.type.namedType]!;
    final body = _selection(type, depth: 3, spreads: true);
    if (body.isEmpty) return null;
    final vars = variables.isEmpty ? '' : '(${variables.join(', ')})';
    final call = args.isEmpty
        ? field.name
        : '${field.name}(${args.join(', ')})';
    return 'query $name$vars { $call { $body } }';
  }

  String _selection(
    SchemaType type, {
    required int depth,
    required bool spreads,
  }) {
    final parts = <String>[];
    if (type is FieldsType) {
      final fields = type.fields.values.toList()..shuffle(random);
      var leaves = 0;
      var objects = 0;
      for (final field in fields) {
        if (field.args.values.any((a) => a.isRequired)) continue;
        final target = schema[field.type.namedType]!;
        if (target.isLeaf && leaves < 6) {
          parts.add(field.name);
          leaves++;
        } else if (target.isComposite && depth > 0 && objects < 2) {
          final nested = _selection(target, depth: depth - 1, spreads: spreads);
          if (nested.isNotEmpty) {
            parts.add('${field.name} { $nested }');
            objects++;
          }
        }
      }
    } else {
      parts.add('__typename');
    }
    if (type.isAbstract) {
      final possible = schema.possibleTypes(type).toList()..sort();
      possible.shuffle(random);
      for (final concrete in possible.take(2)) {
        final t = schema[concrete]! as ObjectType;
        // Aliased leaves avoid merge conflicts between type conditions.
        final leaves = [
          for (final f in t.fields.values)
            if (schema[f.type.namedType]!.isLeaf && f.args.isEmpty) f.name,
        ]..shuffle(random);
        if (leaves.isEmpty) continue;
        parts.add(
          '... on $concrete { ${[for (final l in leaves.take(3)) 'a${_alias++}: $l'].join(' ')} }',
        );
      }
    }
    if (spreads && random.nextBool()) {
      final matching = [
        for (final MapEntry(:key, :value) in _fragments.entries)
          if (value.type == type.name) key,
      ];
      if (matching.isNotEmpty) {
        parts.add('...${matching[random.nextInt(matching.length)]}');
      }
    }
    return parts.join(' ');
  }

  bool _valid(String text, {required bool withOperation}) {
    final sink = DiagnosticSink();
    final fragments = [
      for (final MapEntry(:key, :value) in _fragments.entries)
        'fragment $key on ${value.type} { ${value.body} }',
    ].join('\n');
    final document = withOperation
        ? '$text\n$fragments'
        : '$text\nquery Probe { __typename }';
    final set = DocumentSet.parse([
      GqlifySource('probe.graphql', document),
    ], sink);
    validateDocuments(schema, set, sink);
    return !sink.hasErrors;
  }
}

/// A synthetic schema with [types] object types in a ring of references,
/// interfaces and enums, sized like large real-world APIs.
String syntheticSchema({required int types}) {
  final out = StringBuffer(
    'enum Status { ACTIVE ARCHIVED DRAFT }\n'
    'interface Node { id: ID! }\n'
    'interface Named { id: ID! name: String }\n',
  );
  for (var t = 0; t < types; t++) {
    final iface = t % 3 == 0 ? ' implements Node & Named' : ' implements Node';
    out.writeln(
      'type T$t$iface { id: ID! name: String count: Int! score: Float flag: Boolean! '
      'status: Status note${t % 7}: String next: T${(t + 1) % types} '
      'items(first: Int = 10): [T${(t + 2) % types}!]! named: Named }',
    );
  }
  out.writeln('type Query {');
  for (var t = 0; t < types; t++) {
    out.writeln('  t$t(id: ID!): T$t');
  }
  out.writeln('  node(id: ID!): Node\n  search(text: String): [Named!]!\n}');
  return out.toString();
}
