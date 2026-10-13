import 'package:gqlify/gqlify.dart';
import 'package:gqlify/src/schema/schema.dart';
import 'package:gqlify/src/schema/type_ref.dart';
import 'package:gqlify/src/schema/sdl_builder.dart';
import 'package:test/test.dart';

import 'support/helpers.dart';

List<String> schemaErrors(String sdl) {
  final sink = DiagnosticSink();
  parseSchema(sdl, sink);
  return [for (final d in sink.sorted()) d.code];
}

void main() {
  test('builds types, roots, extensions and deprecations', () {
    final sink = DiagnosticSink();
    final schema = parseSchema('''
      $shopSchema
      extend type Product { sku: String @deprecated(reason: "gone") }
      extend enum Status { DRAFT }
      schema { query: Query mutation: Mutation }
    ''', sink)!;
    expect(sink.items, isEmpty);
    expect(schema.queryType, 'Query');
    expect(schema.mutationType, 'Mutation');
    final product = schema['Product']! as ObjectType;
    expect(product.fields['sku']!.deprecationReason, 'gone');
    expect((schema['Status']! as EnumType).values.keys, [
      'ACTIVE',
      'ARCHIVED',
      'DRAFT',
    ]);
    expect(schema.possibleTypes(schema['Node']!), {'Product', 'Category'});
    expect(schema.possibleTypes(schema['SearchResult']!), {
      'Product',
      'Category',
    });
    expect((schema['Search']! as InputObjectType).isOneOf, isTrue);
  });

  test('defaults root types by name', () {
    final sink = DiagnosticSink();
    final schema = parseSchema(
      'type Query { a: Int } type Mutation { b: Int }',
      sink,
    )!;
    expect(schema.mutationType, 'Mutation');
    expect(schema.subscriptionType, isNull);
  });

  test('reports schema errors', () {
    expect(schemaErrors('type Query { a: Missing }'), ['unknown-type']);
    expect(schemaErrors('type Query { a: Int } type Query { b: Int }'), [
      'duplicate-type',
    ]);
    expect(schemaErrors('type Query { a: Int a: Int }'), ['duplicate-field']);
    expect(schemaErrors('type A { a: Int }'), ['missing-query-type']);
    expect(schemaErrors('input I { a: Int } type Query { a: I }'), [
      'invalid-output-type',
    ]);
    expect(schemaErrors('type O { a: Int } type Query { a(o: O): Int }'), [
      'invalid-input-type',
    ]);
    expect(
      schemaErrors(
        'interface N { id: ID! } type Query implements N { a: Int }',
      ),
      ['missing-interface-field'],
    );
    expect(
      schemaErrors(
        'interface N { id: ID! } type Query implements N { id: ID }',
      ),
      ['invalid-interface-field'],
    );
    expect(
      schemaErrors('type A { a: Int } union U = A | Int type Query { u: U }'),
      ['invalid-union-member'],
    );
    expect(schemaErrors('extend type Nope { a: Int } type Query { a: Int }'), [
      'unknown-type',
    ]);
    expect(schemaErrors('type Query { a: Int } query Q { a }'), [
      'executable-in-schema',
    ]);
    expect(schemaErrors('type Query { a: Int'), ['syntax-error']);
  });

  test('subtyping', () {
    final sink = DiagnosticSink();
    final schema = parseSchema(shopSchema, sink)!;
    expect(
      schema.isSubtype(
        const NamedTypeRef('Product', isNonNull: true),
        const NamedTypeRef('Node'),
      ),
      isTrue,
    );
  });
}
