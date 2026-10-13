@Tags(['differential'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:gqlify/src/schema/sdl_builder.dart';
import 'package:gqlify/gqlify.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/introspection_writer.dart';
import 'support/sandbox.dart';

const _schema = '''
type Product { id: ID! name: String! price: Float status: Status! tags: [String!]! owner: User }
type User { id: ID! email: String! }
enum Status { ACTIVE ARCHIVED }
input Filter { search: String status: Status }
scalar DateTime
type Query { product(id: ID!): Product products(filter: Filter): [Product!]! me: User now: DateTime }
type Mutation { rename(id: ID!, name: String!): Product! }
''';

const _fragments = '''
fragment UserFields on User { id email }
fragment ProductFields on Product { id name owner { ...UserFields } }
''';

const _products = r'''
query GetProduct($id: ID!) { product(id: $id) { ...ProductFields price } }
query ListProducts($f: Filter) { products(filter: $f) { ...ProductFields status } }
''';

const _me = 'query Me { me { ...UserFields } }';
const _rename =
    r'mutation Rename($id: ID!, $name: String!) { rename(id: $id, name: $name) { id name } }';

/// A sandbox with the base project, plus a step runner that compares every
/// state against a clean generation.
final class Scenario {
  Scenario() {
    sandbox
      ..write('gqlify.yaml', 'schema: lib/graphql/schema.graphql\n')
      ..write('lib/graphql/schema.graphql', _schema)
      ..write('lib/graphql/fragments.graphql', _fragments)
      ..write('lib/graphql/products.graphql', _products)
      ..write('lib/graphql/me.graphql', _me)
      ..write('lib/graphql/rename.graphql', _rename);
  }

  final sandbox = Sandbox();

  /// Applies [edit], generates incrementally and compares with clean.
  Future<Snapshot> step(
    String reason, [
    void Function(Sandbox)? edit,
    List<String> args = const [],
  ]) async {
    edit?.call(sandbox);
    final snapshot = await expectMatchesClean(
      sandbox,
      args: [...args, '--explain'],
      reason: reason,
    );
    return snapshot;
  }

  void dispose() => sandbox.dispose();
}

String _cache(Snapshot s) => s.report['cache'] as String? ?? '';

List<Map<String, Object?>> _explain(Snapshot s) => [
  for (final e in s.report['explain']! as List<Object?>)
    e! as Map<String, Object?>,
];

Map<String, Object?> _explained(Snapshot s, String path) =>
    _explain(s).singleWhere((e) => e['path'] == path);

void main() {
  late Scenario scenario;
  setUp(() => scenario = Scenario());
  tearDown(() => scenario.dispose());

  test('1. cold, warm, single operation change', () async {
    final cold = await scenario.step('cold');
    expect(cold.exitCode, 0);
    expect(_cache(cold), 'no previous cache');

    final warm = await scenario.step('warm');
    expect(_cache(warm), startsWith('hit'));

    final changed = await scenario.step('operation changed', (s) {
      s.write(
        'lib/graphql/me.graphql',
        'query Me { me { ...UserFields } now }',
      );
    });
    expect(_cache(changed), 'miss: inputs changed');
    expect(
      _explained(changed, 'lib/graphql/me.graphql.dart')['status'],
      'updated',
    );
    expect(_explained(changed, 'lib/graphql/me.graphql.dart')['reasons'], [
      'document changed',
    ]);
    // Unaffected libraries reuse their formatting.
    expect(
      _explained(changed, 'lib/graphql/rename.graphql.dart')['formatCached'],
      isTrue,
    );
    expect(
      _explained(changed, 'lib/graphql/rename.graphql.dart')['status'],
      'unchanged',
    );
  });

  test('2. fragments: shared, transitive, renamed, deleted, cycles', () async {
    await scenario.step('cold');
    final shared = await scenario.step('shared fragment modified', (s) {
      s.write(
        'lib/graphql/fragments.graphql',
        _fragments.replaceFirst('id name', 'id name tags'),
      );
    });
    expect(
      _explained(shared, 'lib/graphql/products.graphql.dart')['reasons'],
      contains(
        'transitive fragment document changed: lib/graphql/fragments.graphql',
      ),
    );

    await scenario.step('nested transitive fragment modified', (s) {
      s.write(
        'lib/graphql/fragments.graphql',
        _fragments.replaceFirst('{ id email }', '{ id }'),
      );
    });
    await scenario.step('fragment moved to another file', (s) {
      s
        ..write(
          'lib/graphql/fragments.graphql',
          'fragment ProductFields on Product { id name owner { ...UserFields } }',
        )
        ..write(
          'lib/graphql/user.graphql',
          'fragment UserFields on User { id email }',
        );
    });
    final renamedBroken = await scenario.step(
      'fragment renamed (dangling spread)',
      (s) {
        s.write(
          'lib/graphql/user.graphql',
          'fragment UserInfo on User { id email }',
        );
      },
    );
    expect(renamedBroken.exitCode, 1);
    await scenario.step('spreads updated', (s) {
      s
        ..write(
          'lib/graphql/fragments.graphql',
          'fragment ProductFields on Product { id name owner { ...UserInfo } }',
        )
        ..write('lib/graphql/me.graphql', 'query Me { me { ...UserInfo } }');
    });
    final cycle = await scenario.step('cycle', (s) {
      s.write(
        'lib/graphql/user.graphql',
        'fragment UserInfo on User { id ...UserMore } fragment UserMore on User { email ...UserInfo }',
      );
    });
    expect(cycle.exitCode, 1);
    final invalid = await scenario.step('invalid spread', (s) {
      s.write(
        'lib/graphql/user.graphql',
        'fragment UserInfo on User { id ...ProductFields }',
      );
    });
    expect(invalid.exitCode, 1);
    await scenario.step('fixed', (s) {
      s.write('lib/graphql/user.graphql', 'fragment UserInfo on User { id }');
    });
    await scenario.step('fragment file deleted (and its users)', (s) {
      s
        ..delete('lib/graphql/user.graphql')
        ..write(
          'lib/graphql/fragments.graphql',
          'fragment ProductFields on Product { id name }',
        )
        ..write('lib/graphql/me.graphql', 'query Me { me { id } }');
    });
  });

  test('3. schema changes and introspection', () async {
    await scenario.step('cold');
    final added = await scenario.step('field added', (s) {
      s.write(
        'lib/graphql/schema.graphql',
        _schema.replaceFirst('owner: User }', 'owner: User sku: String }'),
      );
    });
    expect(
      _explained(added, 'lib/graphql/me.graphql.dart')['reasons'],
      contains('schema changed'),
    );
    await scenario.step('nullability changed', (s) {
      s.write(
        'lib/graphql/schema.graphql',
        _schema.replaceFirst('name: String!', 'name: String'),
      );
    });
    await scenario.step('enum value added', (s) {
      s.write(
        'lib/graphql/schema.graphql',
        _schema.replaceFirst('ACTIVE ARCHIVED', 'ACTIVE ARCHIVED DRAFT'),
      );
    });
    await scenario.step('input changed', (s) {
      s.write(
        'lib/graphql/schema.graphql',
        _schema.replaceFirst('search: String', 'search: String! limit: Int'),
      );
    });
    final removed = await scenario.step('selected field removed', (s) {
      s.write(
        'lib/graphql/schema.graphql',
        _schema.replaceFirst('price: Float ', ''),
      );
    });
    expect(removed.exitCode, 1);
    expect(removed.diagnostics.toString(), contains('unknown-field'));
    await scenario.step('type renamed', (s) {
      s.write(
        'lib/graphql/schema.graphql',
        _schema
            .replaceAll('User', 'Account')
            .replaceFirst('me: Account', 'me: Account'),
      );
      s.write(
        'lib/graphql/fragments.graphql',
        _fragments.replaceAll('on User', 'on Account'),
      );
    });
    await scenario.step(
      'restored',
      (s) => s.write('lib/graphql/schema.graphql', _schema),
    );
    await scenario.step('swapped to introspection JSON', (s) {
      s.write('lib/graphql/fragments.graphql', _fragments);
      final sink = DiagnosticSink();
      s
        ..write(
          'lib/graphql/schema.json',
          jsonEncode(introspectionOf(parseSchema(_schema, sink)!)),
        )
        ..delete('lib/graphql/schema.graphql')
        ..write('gqlify.yaml', 'schema: lib/graphql/schema.json\n');
    });
    expect(scenario.sandbox.exists('lib/graphql/schema.graphql.dart'), isFalse);
    expect(scenario.sandbox.exists('lib/graphql/schema.json.dart'), isTrue);
  });

  test('4. modes and configuration', () async {
    await scenario.step('cold');
    final schemaOnly = await scenario.step('schema_only', (s) {
      s.write(
        'gqlify.yaml',
        'schema: lib/graphql/schema.graphql\nmode: schema_only\n',
      );
    });
    expect(schemaOnly.outputs.keys, ['lib/graphql/schema.graphql.dart']);
    await scenario.step('operations', (s) {
      s.write(
        'gqlify.yaml',
        'schema: lib/graphql/schema.graphql\nmode: operations\n',
      );
    });
    await scenario.step('both', (s) {
      s.write(
        'gqlify.yaml',
        'schema: lib/graphql/schema.graphql\nmode: both\n',
      );
    });
    final renamed = await scenario.step('client name', (s) {
      s.write(
        'gqlify.yaml',
        'schema: lib/graphql/schema.graphql\nclient_name: ShopClient\n',
      );
    });
    expect(
      _explained(renamed, 'lib/graphql/me.graphql.dart')['reasons'],
      contains('configuration changed'),
    );
    await scenario.step('scalar mapping', (s) {
      s.write('gqlify.yaml', '''
schema: lib/graphql/schema.graphql
scalars:
  DateTime:
    type: DateTime
    json_type: String
    from_json: DateTime.parse
''');
      s.write(
        'lib/graphql/me.graphql',
        'query Me { me { ...UserFields } now }',
      );
    });
    await scenario.step('format settings', (s) {
      s.write('analysis_options.yaml', 'formatter:\n  page_width: 120\n');
    });
    await scenario.step('output location (schema moved)', (s) {
      s
        ..write('lib/api/schema.graphql', s.read('lib/graphql/schema.graphql'))
        ..delete('lib/graphql/schema.graphql')
        ..write('gqlify.yaml', 'schema: lib/api/schema.graphql\n');
    });
    expect(scenario.sandbox.exists('lib/graphql/schema.graphql.dart'), isFalse);
    await scenario.step('documents glob narrowed', (s) {
      s.write(
        'gqlify.yaml',
        'schema: lib/api/schema.graphql\ndocuments: lib/graphql/r*.graphql\n',
      );
    });
    expect(scenario.sandbox.exists('lib/graphql/me.graphql.dart'), isFalse);
  });

  test('5. invalid inputs never leave a success-marked cache', () async {
    await scenario.step('cold');
    final duplicate = await scenario.step('duplicate operation names', (s) {
      s.write('lib/graphql/me2.graphql', 'query Me { me { id } }');
    });
    expect(duplicate.exitCode, 1);
    final variables = await scenario.step('invalid variables', (s) {
      s
        ..delete('lib/graphql/me2.graphql')
        ..write(
          'lib/graphql/me.graphql',
          r'query Me($x: Product) { me { id } }',
        );
    });
    expect(variables.exitCode, 1);
    final syntax = await scenario.step('syntax error', (s) {
      s.write('lib/graphql/me.graphql', 'query Me { me { id }');
    });
    expect(syntax.exitCode, 1);
    // Back to the last successful inputs: the cache may be used again, and
    // must agree with a clean build.
    final restored = await scenario.step(
      'restored',
      (s) => s.write('lib/graphql/me.graphql', _me),
    );
    expect(_cache(restored), startsWith('hit'));
    // A failing run repeated: still reports the error (never cached).
    void broken(Sandbox s) =>
        s.write('lib/graphql/me.graphql', 'query Me { me { nope } }');
    expect((await scenario.step('error again', broken)).exitCode, 1);
    expect((await scenario.step('error again (2)')).exitCode, 1);
  });

  test('6. manual output edits and cache corruption', () async {
    await scenario.step('cold');
    final deleted = await scenario.step(
      'output deleted',
      (s) => s.delete('lib/graphql/me.graphql.dart'),
    );
    expect(
      _cache(deleted),
      'miss: output missing: lib/graphql/me.graphql.dart',
    );
    final edited = await scenario.step('output edited', (s) {
      s.write(
        'lib/graphql/me.graphql.dart',
        '${s.read('lib/graphql/me.graphql.dart')}\n// edit',
      );
    });
    expect(
      _cache(edited),
      'miss: output modified on disk: lib/graphql/me.graphql.dart',
    );
    expect(
      _explained(edited, 'lib/graphql/me.graphql.dart')['reasons'],
      contains('output modified on disk'),
    );

    final manifest = scenario.sandbox.path('.dart_tool/gqlify/manifest.json');
    final content = File(manifest).readAsStringSync();
    final truncated = await scenario.step(
      'manifest truncated',
      (_) => File(
        manifest,
      ).writeAsStringSync(content.substring(0, content.length ~/ 2)),
    );
    expect(
      _cache(truncated),
      startsWith('cache ignored: manifest is not valid JSON'),
    );
    final garbage = await scenario.step(
      'manifest garbage',
      (_) => File(manifest).writeAsStringSync('[]'),
    );
    expect(_cache(garbage), 'cache ignored: manifest is not a JSON object');
    final version = await scenario.step('cache format mismatch', (_) {
      final json =
          jsonDecode(File(manifest).readAsStringSync()) as Map<String, Object?>;
      File(manifest).writeAsStringSync(jsonEncode({...json, 'format': 999}));
    });
    expect(_cache(version), 'cache ignored: cache format 999 is not 1');
    final generator = await scenario.step('generator mismatch', (_) {
      final json =
          jsonDecode(File(manifest).readAsStringSync()) as Map<String, Object?>;
      File(
        manifest,
      ).writeAsStringSync(jsonEncode({...json, 'generator': '0' * 64}));
    });
    expect(_cache(generator), 'cache ignored: generator changed');

    // Corrupt every artifact: formatting must be recomputed, not trusted.
    await scenario.step('artifacts corrupted', (s) {
      s.write('lib/graphql/me.graphql', 'query Me { me { id } }');
    });
    for (final f in Directory(
      scenario.sandbox.path('.dart_tool/gqlify/artifacts'),
    ).listSync(recursive: true).whereType<File>()) {
      f.writeAsStringSync(
        '${f.readAsStringSync().substring(0, 64)}\nclass Corrupt {}',
      );
    }
    final corrupt = await scenario.step('generate with corrupt artifacts', (s) {
      s.write('lib/graphql/me.graphql', _me);
    });
    expect(_explain(corrupt).every((e) => e['formatCached'] != true), isTrue);

    final unexpected = await scenario.step('stale generated file appears', (s) {
      s.write(
        'lib/old.graphql.dart',
        '// GENERATED CODE - DO NOT MODIFY BY HAND.\n// Generated by gqlify from lib/old.graphql.\n',
      );
    });
    expect(
      _cache(unexpected),
      'miss: unexpected generated file: lib/old.graphql.dart',
    );
    expect(scenario.sandbox.exists('lib/old.graphql.dart'), isFalse);

    await scenario.step(
      'cache deleted',
      (s) => Directory(s.path('.dart_tool')).deleteSync(recursive: true),
    );
    final clean = await scenario.step('--clean', null, ['--clean']);
    expect(_cache(clean), 'bypassed: clean build requested');
  });

  test('8. reproducible ordering', () async {
    await scenario.step('cold');
    final again = scenario.sandbox.cloneSources();
    try {
      // Same sources written in a different order on disk.
      for (final name in ['rename', 'me', 'products', 'fragments']) {
        again.delete('lib/graphql/$name.graphql');
      }
      for (final name in ['fragments', 'products', 'me', 'rename']) {
        again.write(
          'lib/graphql/$name.graphql',
          scenario.sandbox.read('lib/graphql/$name.graphql'),
        );
      }
      expect(
        (await again.run(['generate'])).outputs,
        scenario.sandbox.generatedFiles(),
      );
      expect(Directory(p.join(again.dir.path, 'lib')).existsSync(), isTrue);
    } finally {
      again.dispose();
    }
  });
}
