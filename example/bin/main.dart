import 'package:gqlify_example/graphql/cart.graphql.dart';
import 'package:gqlify_example/graphql/fragments.graphql.dart';
import 'package:gqlify_example/graphql/products.graphql.dart';
import 'package:gqlify_example/graphql/schema.graphql.dart';
import 'package:gqlify_runtime/gqlify_runtime.dart';
import 'package:gqlify_runtime/testing.dart';

/// Runs the generated API against an in-memory server. Replace the transport
/// with `HttpTransport(Uri.parse('https://example.com/graphql'))` for a real
/// endpoint.
Future<void> main() async {
  final api = GqlifyClient(transport: MockTransport(_fakeServer));

  final product = (await api.getProduct(sku: 'ABC123')).product!;
  print('Product: ${summary(product)}, added ${product.createdAt.year}');

  final categories = await api.getCategories();
  print('Categories: ${categories.categories.map((c) => c.name).join(', ')}');

  final inStock = await api.searchProducts(
    filter: const ProductFilter(stockStatus: StockStatus.inStock),
  );
  print('In stock: ${inStock.results.map(summary).join('; ')}');

  for (final result in (await api.search(text: 'e')).search) {
    print(switch (result) {
      SearchSearch$Product() => 'Found product ${summary(result)}',
      SearchSearch$Category(:final name) => 'Found category $name',
      SearchSearch$Other(:final typename) => 'Found something new: $typename',
    });
  }

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

/// Accepts any generated class that spreads the `ProductSummary` fragment.
String summary(ProductSummary p) =>
    '${p.name} (${p.price ?? 'n/a'}, ${p.stockStatus.value})';

const _espresso = {
  'sku': 'ABC123',
  'name': 'Espresso machine',
  'price': 249,
  'stock_status': 'IN_STOCK',
};

Map<String, Object?> _fakeServer(GqlifyRequest request) =>
    switch (request.operationName) {
      'GetProduct' when request.variables['sku'] == 'ABC123' => {
        'data': {
          'product': {
            ..._espresso,
            'created_at': '2026-03-01T10:00:00Z',
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
      'SearchProducts' => {
        'data': {
          'results': [_espresso],
        },
      },
      'Search' => {
        'data': {
          'search': [
            {'__typename': 'Product', ..._espresso},
            {'__typename': 'Category', 'id': '1', 'name': 'Kitchen'},
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
