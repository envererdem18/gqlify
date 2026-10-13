import 'dart:io';

import 'package:gqlify/gqlify.dart';
import 'package:gqlify/src/cli/project.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/helpers.dart';

const _schema = r'''
type Product { id: ID! name: String! price: Float sale_price: Float tags: [String!] meta: JSON }
scalar JSON
type Query { product(id: ID!): Product products(first: Int = 10): [Product!]! }
type Mutation { touch(id: ID!): Product! }
''';

void main() {
  test('generates the schema library and one library per document', () {
    final result = generate(_schema, {
      'lib/b.graphql': r'query B($id: ID!) { product(id: $id) { id } }',
      'lib/a.graphql': 'query A { products { id name } }',
      'lib/empty.graphql': '# only a comment',
    });
    expect(result.diagnostics, isEmpty);
    expect(result.outputs.keys, [
      'lib/a.graphql.dart',
      'lib/b.graphql.dart',
      'lib/schema.graphql.dart',
    ]);
    expect(
      result.outputs['lib/a.graphql.dart'],
      contains("import 'schema.graphql.dart';"),
    );
  });

  test('is deterministic regardless of input order', () {
    final docs = {
      'lib/x/b.graphql': r'query B($id: ID!) { product(id: $id) { id meta } }',
      'lib/a.graphql':
          'query A { products { id name tags } } mutation T { touch(id: "1") { id } }',
    };
    final first = generate(_schema, docs);
    final reversed = generate(
      _schema,
      Map.fromEntries(docs.entries.toList().reversed),
    );
    expect(reversed.outputs, first.outputs);
    expect(
      first.outputs['lib/x/b.graphql.dart'],
      contains("import '../schema.graphql.dart';"),
    );
  });

  test('fails all-or-nothing on any error', () {
    final result = generate(_schema, {
      'lib/a.graphql': 'query A { products { id } }',
      'lib/b.graphql': 'query B { products { nope } }',
    });
    expect(result.hasErrors, isTrue);
    expect(result.outputs, isEmpty);
  });

  group('modes', () {
    GenerationResult run(GenerationMode mode, Map<String, String> docs) =>
        generate(
          shopSchema,
          docs,
          config: GqlifyConfig(schema: [testSchemaPath], mode: mode),
        );
    const docs = {'lib/a.graphql': 'query A { products { id status } }'};

    test('operations: only the schema types operations use', () {
      final result = run(GenerationMode.operations, docs);
      expect(result.outputs.keys, [
        'lib/a.graphql.dart',
        'lib/schema.graphql.dart',
      ]);
      final schema = result.outputs['lib/schema.graphql.dart']!;
      expect(schema, contains('class GqlifyClient'));
      expect(schema, contains('enum Status'));
      expect(schema, isNot(contains('class ProductFilter')));
    });

    test('schema_only: every enum and input, no client, documents ignored', () {
      final result = run(GenerationMode.schemaOnly, {
        ...docs,
        'lib/broken.graphql': 'query Broken { nope }',
      });
      expect(result.diagnostics, isEmpty);
      expect(result.outputs.keys, ['lib/schema.graphql.dart']);
      final schema = result.outputs['lib/schema.graphql.dart']!;
      expect(schema, isNot(contains('class GqlifyClient')));
      expect(schema, contains('enum Status'));
      expect(schema, contains('final class ProductFilter'));
      expect(schema, contains('final class Search'));
      // Object, interface and union types are not generated in schema mode.
      expect(schema, isNot(contains('class Product ')));
    });

    test('schema_only works without any documents', () {
      expect(run(GenerationMode.schemaOnly, {}).outputs.keys, [
        'lib/schema.graphql.dart',
      ]);
    });

    test('both: all schema types plus operations', () {
      final result = run(GenerationMode.both, docs);
      expect(result.outputs.keys, [
        'lib/a.graphql.dart',
        'lib/schema.graphql.dart',
      ]);
      final schema = result.outputs['lib/schema.graphql.dart']!;
      expect(schema, contains('class GqlifyClient'));
      expect(schema, contains('final class ProductFilter'));
      expect(
        result.outputs['lib/a.graphql.dart'],
        run(GenerationMode.operations, docs).outputs['lib/a.graphql.dart'],
      );
    });
  });

  test('custom scalar mappings are validated', () {
    List<String> errors(Map<String, ScalarConfig> scalars) => [
      for (final d in generate(
        shopSchema,
        const {},
        config: GqlifyConfig(schema: [testSchemaPath], scalars: scalars),
      ).diagnostics)
        if (d.isError) d.message,
    ];
    expect(errors({'DateTime': const ScalarConfig(type: 'String')}), isEmpty);
    expect(
      errors({'Nope': const ScalarConfig(type: 'String')}).single,
      contains('no scalar "Nope"'),
    );
    expect(
      errors({'Int': const ScalarConfig(type: 'BigInt')}).single,
      contains('cannot be remapped'),
    );
    expect(
      errors({'DateTime': const ScalarConfig(type: 'DateTime')}).single,
      contains('"from_json" is required'),
    );
  });

  test('reports naming collisions instead of renaming', () {
    List<String> codes(Map<String, String> docs) => [
      for (final d in generate(_schema, docs).diagnostics)
        if (d.isError) d.code,
    ];
    expect(
      codes({
        'lib/a.graphql':
            'query GetX { products { id } } query GetXQuery { products { id } }',
      }),
      contains('name-collision'),
    );
    expect(codes({'lib/a.graphql': 'query Execute { products { id } }'}), [
      'name-collision',
    ]);
    expect(
      codes({
        'lib/a.graphql': 'query A { products { sale_price salePrice: price } }',
      }),
      ['name-collision'],
    );
  });

  test('maps types, nullability and conditional fields', () {
    final out = generate(_schema, {
      'lib/a.graphql':
          r'query A($full: Boolean!) { products { id price tags meta name @include(if: $full) } }',
    }).outputs['lib/a.graphql.dart']!;
    expect(out, contains('final String id;'));
    expect(out, contains('final double? price;'));
    expect(out, contains('final List<String>? tags;'));
    expect(out, contains('final Object? meta;'));
    expect(out, contains('final String? name;')); // @include makes it optional
  });

  test('escapes reserved words and member names', () {
    final result = generate(
      'type T { class: Int, toJson: Int, hashCode: Int } type Query { t(in: Int): T }',
      {
        'lib/a.graphql':
            r'query Q($in: Int, $document: Int) { t(in: $in) { class toJson hashCode a: class } q: t(in: $document) { class } }',
      },
    );
    expect(result.diagnostics, isEmpty);
    final out = result.outputs['lib/a.graphql.dart']!;
    expect(out, contains(r'final int? $class;'));
    expect(out, contains(r'final int? $toJson;'));
    expect(out, contains(r'final int? $hashCode;'));
    expect(out, contains(r'final int? $in;'));
    expect(out, contains(r'final int? $document;'));
  });

  test('format settings follow the consuming package', () {
    final settings = FormatSettings.fromProjectFiles(
      pubspecYaml: 'name: x\nenvironment:\n  sdk: ">=3.6.0 <4.0.0"\n',
      analysisOptionsYaml:
          'formatter:\n  page_width: 120\n  trailing_commas: preserve\n',
    );
    expect(settings.languageVersion.toString(), '3.6.0');
    expect(settings.pageWidth, 120);
    expect(settings.preserveTrailingCommas, isTrue);
    expect(
      FormatSettings.fromProjectFiles(
        pubspecYaml: 'environment:\n  sdk: ^2.12.0',
      ).languageVersion.toString(),
      '3.0.0',
    );
    expect(FormatSettings.fromProjectFiles().pageWidth, 80);

    final wide = GqlifyEngine().generate(
      GenerationInput(
        config: GqlifyConfig(schema: [testSchemaPath]),
        schema: [GqlifySource(testSchemaPath, _schema)],
        documents: [
          GqlifySource(
            'lib/a.graphql',
            'query A { products { id name price } }',
          ),
        ],
        format: settings,
      ),
    );
    final narrow = generate(_schema, {
      'lib/a.graphql': 'query A { products { id name price } }',
    });
    expect(
      wide.outputs['lib/a.graphql.dart'],
      isNot(narrow.outputs['lib/a.graphql.dart']),
    );
  });

  test('custom client name', () {
    final result = generate(
      _schema,
      {'lib/a.graphql': 'query A { products { id } }'},
      config: GqlifyConfig(schema: [testSchemaPath], clientName: 'ShopClient'),
    );
    expect(
      result.outputs['lib/schema.graphql.dart'],
      contains('class ShopClient extends GqlifyClientBase'),
    );
    expect(
      result.outputs['lib/a.graphql.dart'],
      contains('extension AQueryCall on ShopClient'),
    );
  });

  test('example package outputs match a fresh generation (golden)', () {
    // Loads inputs exactly like the CLI does.
    final project = Project(
      p.normalize(p.join(Directory.current.path, '..', '..', 'example')),
    );
    final sink = DiagnosticSink();
    final input = project.loadInput(project.loadConfig(sink)!, sink)!;
    final result = GqlifyEngine().generate(input);
    expect(result.hasErrors, isFalse);
    for (final MapEntry(key: path, value: content) in result.outputs.entries) {
      expect(
        File(project.absolute(path)).readAsStringSync(),
        content,
        reason:
            '$path is out of date; run `dart run gqlify generate` in example/',
      );
    }
  });
}
