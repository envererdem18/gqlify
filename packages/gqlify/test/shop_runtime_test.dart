import 'package:gqlify_runtime/gqlify_runtime.dart';
import 'package:gqlify_runtime/testing.dart';
import 'package:test/test.dart';

import 'fixtures/shop/fragments.graphql.dart';
import 'fixtures/shop/products.graphql.dart';
import 'fixtures/shop/schema.graphql.dart';

/// Accepts any selection that spreads `ProductCard`.
String describe(ProductCard card) =>
    '${card.name} ${card.status.value} ${card.price?.amount} ${card.price?.currency.value}';

const _card = {
  'id': 'p1',
  'name': 'Mug',
  'status': 'ACTIVE',
  'price': {'amount': 9, 'currency': 'EUR'},
};

void main() {
  late MockTransport transport;
  late GqlifyClient api;

  void respond(Map<String, Object?> data) {
    transport = MockTransport.fixed({'data': data});
    api = GqlifyClient(transport: transport);
  }

  group('fragments', () {
    test(
      'selections implement fragment interfaces, including nested ones',
      () async {
        respond({
          'product': {
            ..._card,
            'createdAt': '2026-01-02T03:04:05Z',
            'updatedAt': null,
            'legacyCode': 'L1',
            'usd': {'amount': 10.5},
            'localPrice': {'amount': 9, 'currency': 'EUR'},
            'owner': {'email': 'a@b.c'},
          },
        });
        final product = (await api.productDetails(
          lookup: const Lookup.sku('MUG'),
        )).product!;

        expect(describe(product), 'Mug ACTIVE 9.0 EUR');
        final MoneyFields money = product.price!;
        expect(money.amount, 9.0);
        expect(product.createdAt, DateTime.utc(2026, 1, 2, 3, 4, 5));
        expect(product.updatedAt, isNull);
        expect(product.usd?.amount, 10.5);
        expect(product.owner?.email, 'a@b.c');

        final request = transport.requests.single;
        expect(request.variables, {
          'lookup': {'sku': 'MUG'},
        });
        expect(request.document, contains('fragment ProductCard on Product'));
        expect(request.document, contains('fragment MoneyFields on Money'));
      },
    );
  });

  group('polymorphism', () {
    test(
      'union results decode by __typename into a sealed hierarchy',
      () async {
        respond({
          'search': [
            {'__typename': 'Product', ..._card},
            {'__typename': 'Category', 'name': 'Kitchen'},
            {'__typename': 'User', 'id': 'u1', 'email': 'a@b.c'},
            {'__typename': 'Brand'}, // Added to the schema after generation.
          ],
        });
        final results = (await api.search(text: 'm')).search;

        final described = [
          for (final r in results)
            switch (r) {
              SearchSearch$Product() => 'product ${describe(r)}',
              SearchSearch$Category(:final name) => 'category $name',
              SearchSearch$User(:final email) => 'user $email',
              SearchSearch$Other(:final typename) => 'other $typename',
            },
        ];
        expect(described, [
          'product Mug ACTIVE 9.0 EUR',
          'category Kitchen',
          'user a@b.c',
          'other Brand',
        ]);
        expect(results.first.typename, 'Product');
        expect(
          transport.requests.single.document,
          contains('search(text: \$text) { __typename'),
        );
      },
    );

    test('interface fields and polymorphic fragments', () async {
      respond({
        'node': {
          '__typename': 'Product',
          'id': 'p1',
          'name': 'Mug',
          'tags': ['a'],
        },
      });
      final node = (await api.getNode(id: 'p1')).node!;
      final NodeSummary summary = node;
      expect(summary.id, 'p1');
      expect(node, isA<GetNodeNode$Product>());
      expect((node as NodeSummary$Product).tags, ['a']);

      respond({
        'node': {'__typename': 'Category', 'id': 'c1'},
      });
      expect((await api.getNode(id: 'c1')).node, isA<GetNodeNode$Other>());
    });

    test('missing __typename is a decoding error', () async {
      respond({
        'node': {'id': 'p1'},
      });
      await expectLater(
        api.getNode(id: 'p1'),
        throwsA(
          isA<GqlifyDecodingException>().having(
            (e) => e.message,
            'message',
            contains('Missing required field node.__typename'),
          ),
        ),
      );
    });
  });

  group('enums', () {
    test('unknown values decode to \$unknown and cannot be sent', () {
      final product = ProductListProducts.fromJson({
        ..._card,
        'status': 'BRAND_NEW',
        'related': <Object?>[],
      });
      expect(product.status, ProductStatus.$unknown);
      expect(product.toJson, throwsUnsupportedError);
      expect(ProductStatus.fromJson('ARCHIVED'), ProductStatus.archived);
      expect(Currency.usd.toJson(), 'USD');
    });
  });

  group('inputs and variables', () {
    test('omitted vs explicit null vs value', () async {
      respond({'products': <Object?>[]});
      final filter = ProductFilter(
        search: 'mug',
        tags: const ['a'],
        createdAfter: DateTime.utc(2026),
        price: const PriceRange(min: 1).withNull(max: true),
      ).withNull(minPrice: true);

      await api.productList(filter: filter);

      expect(transport.requests.single.variables, {
        'filter': {
          'search': 'mug',
          'minPrice': null,
          'tags': ['a'],
          'createdAfter': '2026-01-01T00:00:00.000Z',
          'price': {'min': 1.0, 'max': null},
        },
      });
    });

    test('explicit null variables and server defaults', () async {
      respond({'products': <Object?>[]});
      await api.execute(
        const ProductListQuery(first: 5).withNull(filter: true),
      );
      await api.productList();
      expect(transport.requests.map((r) => r.variables), [
        {'filter': null, 'first': 5},
        <String, Object?>{},
      ]);
    });

    test('withNull overrides a value and keeps value equality', () {
      const a = ProductFilter(search: 'x');
      expect(a.withNull(search: true).toJson(), {'search': null});
      expect(const ProductFilter(search: 'x'), a);
      expect(a.withNull(search: true), isNot(a));
      expect(
        const ProductListQuery(first: 1),
        const ProductListQuery(first: 1),
      );
    });

    test('required input fields, enums and @oneOf', () async {
      respond({'updateProduct': _card});
      final updated = await api.updateProduct(
        id: 'p1',
        input: const ProductInput(name: 'Mug', status: ProductStatus.archived),
      );
      expect(updated.updateProduct.name, 'Mug');
      expect(transport.requests.single.variables, {
        'id': 'p1',
        'input': {'name': 'Mug', 'status': 'ARCHIVED'},
      });
      expect(const Lookup.id('1').toJson(), {'id': '1'});
    });
  });
}
