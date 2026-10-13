import 'package:gqlify_example/graphql/cart.graphql.dart';
import 'package:gqlify_example/graphql/products.graphql.dart';
import 'package:gqlify_example/graphql/schema.graphql.dart';
import 'package:gqlify_runtime/gqlify_runtime.dart';
import 'package:gqlify_runtime/testing.dart';
import 'package:test/test.dart';

const _product = {
  'sku': 'ABC123',
  'name': 'Espresso machine',
  'price': 249,
  'stock_quantity': 7,
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
    expect(product.stockQuantity, 7); // snake_case -> camelCase.
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

  test('aliases become field names', () async {
    respond({
      'data': {
        'results': [
          {'sku': 'A', 'name': 'a'},
        ],
      },
    });
    final data = await api.searchProducts(search: 'a', pageSize: 5);
    expect(data.results.single.sku, 'A');
    expect(transport.requests.single.variables, {'search': 'a', 'pageSize': 5});
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
          contains('GetProductProduct.name'),
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
          contains('GetProductProduct.categories[]'),
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
    expect(a.toJson()['product'], containsPair('stock_quantity', 7));
  });
}
