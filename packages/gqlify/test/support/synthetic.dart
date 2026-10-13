import 'dart:math';

import 'sandbox.dart';

/// A generated GraphQL project of configurable size whose parts can be
/// mutated randomly, for differential fuzzing and large-fixture tests.
final class SyntheticProject {
  SyntheticProject({
    required this.random,
    int types = 12,
    int fragments = 8,
    int documents = 6,
    int operationsPerDocument = 3,
  }) {
    for (var t = 0; t < types; t++) {
      typeFields['T$t'] = {
        'id': 'ID!',
        'name': 'String',
        'count': 'Int!',
        'score': 'Float',
        'flag': 'Boolean!',
        'status': 'Status',
        'next': 'T${(t + 1) % types}',
        'items': '[T${(t + 2) % types}!]!',
      };
    }
    for (var f = 0; f < fragments; f++) {
      final type = 'T${random.nextInt(types)}';
      this.fragments['F$f'] = (
        type,
        _selection(type, depth: 1, allowFragments: f > 0 ? f : 0),
      );
    }
    for (var d = 0; d < documents; d++) {
      final ops = <String, String>{};
      for (var o = 0; o < operationsPerDocument; o++) {
        final type = 'T${random.nextInt(types)}';
        ops['Op${d}x$o'] = _selection(
          type,
          depth: 2,
          allowFragments: this.fragments.length,
        );
        setRoot('Op${d}x$o', type);
      }
      this.documents['lib/gql/d$d.graphql'] = ops;
    }
    // Fragment definitions live in their own documents.
    for (final name in this.fragments.keys) {
      fragmentHome[name] =
          'lib/gql/frag_${int.parse(name.substring(1)) % 3}.graphql';
    }
  }

  final Random random;
  final Map<String, Map<String, String>> typeFields = {};

  /// name -> (type condition, selection set body)
  final Map<String, (String, String)> fragments = {};
  final Map<String, String> fragmentHome = {};

  /// document path -> operation name -> (root type field 'tN' selection body)
  final Map<String, Map<String, String>> documents = {};
  String mode = 'operations';
  String clientName = 'GqlifyClient';

  String get schema {
    final out = StringBuffer('enum Status { ACTIVE ARCHIVED DRAFT }\n');
    for (final MapEntry(key: type, value: fields) in typeFields.entries) {
      out.writeln(
        'type $type { ${fields.entries.map((f) => '${f.key}: ${f.value}').join(' ')} }',
      );
    }
    out.writeln(
      'type Query { ${[for (final t in typeFields.keys) '${t.toLowerCase()}(id: ID): $t'].join(' ')} }',
    );
    return out.toString();
  }

  String _selection(
    String type, {
    required int depth,
    required int allowFragments,
  }) {
    final fields = typeFields[type]!;
    final parts = <String>['id'];
    for (final MapEntry(key: name, value: fieldType) in fields.entries) {
      if (name == 'id' || random.nextInt(3) == 0) continue;
      final target = fieldType.replaceAll(RegExp(r'[\[\]!]'), '');
      if (typeFields.containsKey(target)) {
        if (depth > 0) {
          parts.add(
            '$name { ${_selection(target, depth: depth - 1, allowFragments: allowFragments)} }',
          );
        }
      } else {
        parts.add(name);
      }
    }
    if (allowFragments > 0 && random.nextBool()) {
      final candidates = [
        for (final MapEntry(key: f, value: (cond, _)) in fragments.entries.take(
          allowFragments,
        ))
          if (cond == type) f,
      ];
      if (candidates.isNotEmpty) {
        parts.add('...${candidates[random.nextInt(candidates.length)]}');
      }
    }
    return parts.join(' ');
  }

  /// Writes the whole project into [sandbox], removing documents that no
  /// longer exist.
  void writeTo(Sandbox sandbox, Set<String> previousDocuments) {
    sandbox
      ..write(
        'gqlify.yaml',
        'schema: lib/gql/schema.graphql\nmode: $mode\nclient_name: $clientName\n',
      )
      ..write('lib/gql/schema.graphql', schema);
    final files = <String, StringBuffer>{};
    for (final MapEntry(key: path, value: ops) in documents.entries) {
      final buffer = files.putIfAbsent(path, StringBuffer.new);
      for (final MapEntry(key: name, value: body) in ops.entries) {
        buffer.writeln(
          'query $name { ${_rootField(name)}(id: "1") { $body } }',
        );
      }
    }
    for (final MapEntry(key: name, value: (type, body)) in fragments.entries) {
      files
          .putIfAbsent(fragmentHome[name]!, StringBuffer.new)
          .writeln('fragment $name on $type { $body }');
    }
    for (final path in previousDocuments.difference(files.keys.toSet())) {
      sandbox.delete(path);
    }
    for (final MapEntry(:key, :value) in files.entries) {
      sandbox.write(key, value.toString());
    }
    previousDocuments
      ..clear()
      ..addAll(files.keys);
  }

  final Map<String, String> _roots = {};
  String _rootField(String op) => _roots[op]!;

  /// Registers the root type of operation [name].
  void setRoot(String name, String type) => _roots[name] = type.toLowerCase();

  /// Applies one random mutation and returns its description.
  String mutate() {
    final kind = random.nextInt(9);
    switch (kind) {
      case 0: // Edit an operation.
        final doc = _pick(documents.keys);
        final op = _pick(documents[doc]!.keys);
        final type = _roots[op]!.toUpperCase();
        documents[doc]![op] = _selection(
          type,
          depth: 2,
          allowFragments: fragments.length,
        );
        return 'edit operation $op';
      case 1: // Edit a fragment.
        final f = _pick(fragments.keys);
        final (type, _) = fragments[f]!;
        fragments[f] = (
          type,
          _selection(type, depth: 1, allowFragments: int.parse(f.substring(1))),
        );
        return 'edit fragment $f';
      case 2: // Add an operation in a new or existing document.
        final doc = random.nextBool()
            ? _pick(documents.keys)
            : 'lib/gql/new${random.nextInt(1000)}.graphql';
        final type = _pick(typeFields.keys);
        final name = 'Added${random.nextInt(100000)}';
        documents.putIfAbsent(doc, () => {})[name] = _selection(
          type,
          depth: 2,
          allowFragments: fragments.length,
        );
        setRoot(name, type);
        return 'add operation $name to $doc';
      case 3: // Delete a document (operations only).
        if (documents.length < 2) return 'noop';
        final doc = _pick(documents.keys);
        documents.remove(doc);
        return 'delete $doc';
      case 4: // Schema: toggle nullability of a scalar field.
        final type = _pick(typeFields.keys);
        final fields = typeFields[type]!;
        fields['name'] = fields['name'] == 'String' ? 'String!' : 'String';
        return 'toggle nullability of $type.name';
      case 5: // Schema: remove a field (may break documents -> errors).
        final type = _pick(typeFields.keys);
        final removed = typeFields[type]!.remove('score') != null;
        return removed ? 'remove $type.score' : 'noop';
      case 6: // Schema: add a field.
        final type = _pick(typeFields.keys);
        typeFields[type]!['score'] = 'Float';
        typeFields[type]!['extra${random.nextInt(5)}'] = 'String';
        return 'add fields to $type';
      case 7: // Configuration.
        if (random.nextBool()) {
          mode = _pick(['operations', 'schema_only', 'both']);
          return 'mode $mode';
        }
        clientName = _pick(['GqlifyClient', 'Api', 'ShopClient']);
        return 'client $clientName';
      default: // Move a fragment to another document.
        final f = _pick(fragments.keys);
        fragmentHome[f] = 'lib/gql/frag_${random.nextInt(4)}.graphql';
        return 'move fragment $f';
    }
  }

  /// Undoes schema edits that break documents (removed fields), so that a
  /// fuzz sequence keeps alternating between failing and successful states.
  String repair() {
    for (final fields in typeFields.values) {
      fields['score'] = 'Float';
    }
    return 'repair: restore removed fields';
  }

  T _pick<T>(Iterable<T> items) {
    final list = items.toList();
    return list[random.nextInt(list.length)];
  }
}
