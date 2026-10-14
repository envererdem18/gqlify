# gqlify example

A complete, runnable example lives in the repository's
[`example/`](https://github.com/envererdem18/gqlify/tree/main/example)
package. In short:

```yaml
# pubspec.yaml
dependencies:
  gqlify_runtime: ^0.1.0
dev_dependencies:
  gqlify: ^0.1.0

gqlify:
  schema: lib/graphql/schema.graphql
```

```graphql
# lib/graphql/products.graphql
query GetProduct($sku: ID!) {
  product(sku: $sku) { sku name price }
}
```

```bash
dart run gqlify generate      # or: dart run build_runner build
```

```dart
import 'package:gqlify_runtime/gqlify_runtime.dart';
import 'graphql/schema.graphql.dart';
import 'graphql/products.graphql.dart';

Future<void> main() async {
  final api = GqlifyClient(
    transport: HttpTransport(Uri.parse('https://shop.example/graphql')),
  );
  final data = await api.getProduct(sku: 'ABC123');
  print(data.product?.name);
}
```
