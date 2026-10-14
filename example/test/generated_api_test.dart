import 'package:gqlify_example/graphql/cart.graphql.dart';
import 'package:gqlify_example/graphql/fragments.graphql.dart';
import 'package:gqlify_example/graphql/products.graphql.dart';
import 'package:gqlify_example/graphql/schema.graphql.dart';
import 'package:gqlify_runtime/gqlify_runtime.dart';
import 'package:gqlify_runtime/testing.dart';
import 'package:test/test.dart';

const _product = {
  'sku': 'ABC123',
  'name': 'Espresso machine',
  'price': 249,
  'stock_status': 'IN_STOCK',
  'created_at': '2026-03-01T10:00:00Z',
  'categories': [
    {'id': '1', 'name': 'Kitchen'},
  ],
};

void main() {
  late MockTransport transport;
  late GqlifyClient api;

  void respond(Map<String, Object?> body) {
    transport = MockTransport.fixed(body);
    api = GqlifyClient(transport: transport);
  }

  test('query: sends the embedded document and decodes typed data', () async {
    respond({
      'data': {'product': _product},
    });

    final data = await api.getProduct(sku: 'ABC123');

    final product = data.product!;
    expect(product.sku, 'ABC123');
    expect(product.price, 249.0); // Float accepts JSON integers.
    expect(
      product.stockStatus,
      StockStatus.inStock,
    ); // snake_case -> camelCase.
    expect(product.createdAt, DateTime.utc(2026, 3, 1, 10)); // Custom scalar.
    final ProductSummary summary = product; // Fragment interface.
    expect(summary.name, 'Espresso machine');
    expect(product.categories.single.name, 'Kitchen');

    final request = transport.requests.single;
    expect(request.operationName, 'GetProduct');
    expect(request.operationType, GqlifyOperationType.query);
    expect(request.variables, {'sku': 'ABC123'});
    expect(request.document, startsWith(r'query GetProduct($sku: ID!)'));
  });

  test('nullable variables are omitted unless provided', () async {
    respond({
      'data': {'categories': <Object?>[]},
    });
    await api.getCategories();
    await api.getCategories(parentId: '5');
    expect(transport.requests.map((r) => r.variables), [
      <String, Object?>{},
      {'parentId': '5'},
    ]);
  });

  test('aliases, input objects and enums', () async {
    respond({
      'data': {
        'results': [
          {
            'sku': 'A',
            'name': 'a',
            'price': null,
            'stock_status': 'OUT_OF_STOCK',
          },
        ],
      },
    });
    final data = await api.searchProducts(
      filter: const ProductFilter(
        search: 'a',
        stockStatus: StockStatus.inStock,
      ).withNull(minPrice: true),
      pageSize: 5,
    );
    expect(data.results.single.sku, 'A');
    expect(data.results.single.stockStatus, StockStatus.outOfStock);
    expect(transport.requests.single.variables, {
      'filter': {'search': 'a', 'stock_status': 'IN_STOCK', 'min_price': null},
      'pageSize': 5,
    });
  });

  test('union results', () async {
    respond({
      'data': {
        'search': [
          {'__typename': 'Category', 'id': '1', 'name': 'Kitchen'},
          {'__typename': 'Product', ..._product},
        ],
      },
    });
    final results = (await api.search(text: 'k')).search;
    expect(results.first, isA<SearchSearch$Category>());
    expect((results.last as ProductSummary).name, 'Espresso machine');
  });

  test('mutation', () async {
    respond({
      'data': {
        'addToCart': {
          'id': 'c1',
          'total_quantity': 2,
          'items': [
            {'sku': 'ABC123', 'quantity': 2},
          ],
        },
      },
    });
    final data = await api.addToCart(cartId: 'c1', sku: 'ABC123', quantity: 2);
    expect(data.addToCart.totalQuantity, 2.0);
    expect(data.addToCart.items.single.quantity, 2.0);
    expect(
      transport.requests.single.operationType,
      GqlifyOperationType.mutation,
    );
    expect(transport.requests.single.variables, {
      'cartId': 'c1',
      'sku': 'ABC123',
      'quantity': 2.0,
    });
  });

  test('GraphQL errors throw, with partial data attached', () async {
    respond({
      'data': {'product': null},
      'errors': [
        {
          'message': 'Not found',
          'path': ['product'],
        },
      ],
    });
    await expectLater(
      api.getProduct(sku: 'x'),
      throwsA(
        isA<GraphQLResponseException>()
            .having((e) => e.errors.single.message, 'message', 'Not found')
            .having((e) => e.data, 'data', isA<GetProductData>()),
      ),
    );
  });

  test('execute returns errors without throwing', () async {
    respond({
      'data': {'product': null},
      'errors': [
        {'message': 'Not found'},
      ],
    });
    final response = await api.execute(const GetProductQuery(sku: 'x'));
    expect(response.data?.product, isNull);
    expect(response.errors.single.message, 'Not found');
  });

  test('missing non-null fields fail with a located decoding error', () async {
    respond({
      'data': {
        'product': {..._product}..remove('name'),
      },
    });
    await expectLater(
      api.getProduct(sku: 'x'),
      throwsA(
        isA<GqlifyDecodingException>().having(
          (e) => e.message,
          'message',
          contains('Missing required field product.name'),
        ),
      ),
    );
  });

  test('wrong list element types fail with a located decoding error', () async {
    respond({
      'data': {
        'product': {
          ..._product,
          'categories': [1],
        },
      },
    });
    await expectLater(
      api.getProduct(sku: 'x'),
      throwsA(
        isA<GqlifyDecodingException>().having(
          (e) => e.message,
          'message',
          contains('Expected object at product.categories[0], got int'),
        ),
      ),
    );
  });

  test('transport failures propagate', () async {
    transport = MockTransport(
      (_) => throw const GqlifyTransportException('offline'),
    );
    api = GqlifyClient(transport: transport);
    await expectLater(
      api.getCategories(),
      throwsA(isA<GqlifyTransportException>()),
    );
  });

  test('value semantics and JSON round trip', () {
    final a = GetProductData.fromJson({'product': _product});
    final b = GetProductData.fromJson(a.toJson());
    expect(b, a);
    expect(b.hashCode, a.hashCode);
    expect(a.toString(), contains('Espresso machine'));
    expect(a.toJson()['product'], containsPair('stock_status', 'IN_STOCK'));
  });
}
