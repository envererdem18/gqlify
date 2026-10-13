import 'package:gqlify_example/graphql/cart.graphql.dart';
import 'package:gqlify_example/graphql/products.graphql.dart';
import 'package:gqlify_example/graphql/schema.graphql.dart';
import 'package:gqlify_runtime/gqlify_runtime.dart';
import 'package:gqlify_runtime/testing.dart';

/// Runs the generated API against an in-memory server. Replace the transport
/// with `HttpTransport(Uri.parse('https://example.com/graphql'))` for a real
/// endpoint.
Future<void> main() async {
  final api = GqlifyClient(transport: MockTransport(_fakeServer));

  final product = await api.getProduct(sku: 'ABC123');
  print('Product: ${product.product?.name} (${product.product?.price})');

  final categories = await api.getCategories();
  print('Categories: ${categories.categories.map((c) => c.name).join(', ')}');

  final cart = await api.addToCart(
    cartId: 'cart-1',
    sku: 'ABC123',
    quantity: 2,
  );
  print('Cart ${cart.addToCart.id} has ${cart.addToCart.totalQuantity} items');

  try {
    await api.getProduct(sku: 'missing');
  } on GraphQLResponseException catch (e) {
    print('GraphQL error: ${e.message}');
  }

  await api.close();
}

Map<String, Object?> _fakeServer(GqlifyRequest request) =>
    switch (request.operationName) {
      'GetProduct' when request.variables['sku'] == 'ABC123' => {
        'data': {
          'product': {
            'sku': 'ABC123',
            'name': 'Espresso machine',
            'price': 249,
            'stock_quantity': 7,
            'categories': [
              {'id': '1', 'name': 'Kitchen'},
            ],
          },
        },
      },
      'GetProduct' => {
        'data': {'product': null},
        'errors': [
          {
            'message': 'Product not found',
            'path': ['product'],
          },
        ],
      },
      'GetCategories' => {
        'data': {
          'categories': [
            {'id': '1', 'name': 'Kitchen', 'children': <Object?>[]},
            {'id': '2', 'name': 'Garden', 'children': <Object?>[]},
          ],
        },
      },
      'AddToCart' => {
        'data': {
          'addToCart': {
            'id': request.variables['cartId'],
            'total_quantity': request.variables['quantity'],
            'items': [
              {
                'sku': request.variables['sku'],
                'quantity': request.variables['quantity'],
              },
            ],
          },
        },
      },
      _ => throw StateError('Unexpected operation ${request.operationName}'),
    };
