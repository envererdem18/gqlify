# gqlify

**GraphQL, simplified for Dart.**

gqlify generates a small, strongly typed Dart API from a GraphQL schema and
your `.graphql` operations, at build time:

```dart
final api = GqlifyClient(transport: HttpTransport(Uri.parse('https://shop.example/graphql')));

final data = await api.getProduct(sku: 'ABC123');
print(data.product?.name);

await api.addToCart(cartId: cartId, sku: 'ABC123', quantity: 2);
```

There are no `Options$Query$...` or `Variables$Query$...` wrappers to build, no
`.graphql` assets read at runtime, and no query strings parsed at runtime.

> **Status: all five milestones complete; pre-release (`0.1.0-dev`), not yet
> published to pub.dev.** Queries, mutations, fragments, enums, input objects,
> interfaces/unions, custom scalars, introspection input, schema-only mode, a
> correctness-first incremental CLI and a `build_runner` builder work end to
> end. See [Supported today](#supported-today) and [BENCHMARKS.md](BENCHMARKS.md).

## Packages

| Package | Add as | Purpose |
| --- | --- | --- |
| [`gqlify`](packages/gqlify) | `dev_dependencies` | Generator and `gqlify` command line tool |
| [`gqlify_runtime`](packages/gqlify_runtime) | `dependencies` | Tiny pure-Dart runtime used by generated code (works with Flutter, server and CLI apps) |

## Getting started

1. Add the packages. They are not on pub.dev yet; use path or git
   dependencies for now:

   ```yaml
   dependencies:
     gqlify_runtime: ^0.1.0
   dev_dependencies:
     gqlify: ^0.1.0
   ```

2. Add your schema (SDL, or an introspection `.json`) and operations:

   ```graphql
   # lib/graphql/products.graphql
   query GetProduct($sku: ID!) {
     product(sku: $sku) {
       ...ProductSummary
       categories { id name }
     }
   }

   fragment ProductSummary on Product {
     sku
     name
     price
   }
   ```

3. Configure gqlify in a `gqlify:` section of `pubspec.yaml`:

   ```yaml
   gqlify:
     schema: lib/graphql/schema.graphql
   ```

   A separate `gqlify.yaml` with the same settings (without the `gqlify:`
   key) works too. Use one or the other, not both.

4. Generate with the CLI or with `build_runner`. Both produce byte-identical
   files:

   ```bash
   dart run gqlify generate        # or: dart run gqlify check (CI)
   dart run build_runner build     # or: dart run build_runner watch
   ```

   This writes `lib/graphql/schema.graphql.dart` (client, enums, inputs) and one
   `*.graphql.dart` library next to each operation document. Import the
   libraries whose operations you call.

## Configuration

Settings go in the `gqlify:` section of `pubspec.yaml` or in `gqlify.yaml`:

```yaml
schema: lib/graphql/schema.graphql   # or a list of SDL files, or one introspection .json
documents:                           # optional, default: lib/**.graphql and lib/**.gql
  - lib/graphql/**.graphql
mode: operations                     # operations | schema_only | both
client_name: GqlifyClient            # optional
scalars:                             # optional custom scalar mappings
  DateTime:
    type: DateTime
    json_type: String                # String, int, double, num, bool, Map, List, Object
    from_json: DateTime.parse
    to_json: encodeDateTime          # optional
    import: package:my_app/scalars.dart
```

Unknown settings are errors, so typos never pass silently.

SDL schemas may use the legacy `implements A, B` interface syntax used by some
large schemas, for example Magento's, as well as the current `implements A & B`.

### Modes

| Mode | Generates |
| --- | --- |
| `operations` (default) | Client, operations and fragments, plus the enums and inputs they use |
| `schema_only` | Every enum and input object of the schema. No operations are read. |
| `both` | Everything from `operations` plus every enum and input object |

Response classes only exist for operations and fragments. A response contains
exactly the fields you selected, so gqlify does not generate a "full" class per
schema object type that would pretend otherwise.

### Formatting

Generated code is formatted to match `dart format` in your package. gqlify uses
your `pubspec.yaml` SDK constraint and the `formatter:` section of
`analysis_options.yaml`.

## Command line

| Command | What it does |
| --- | --- |
| `dart run gqlify generate` | Validates and generates. It writes only files whose content changed, removes outputs that are no longer produced (for example after deleting a document or switching mode), and never overwrites files it did not generate. On any error, no file is changed. |
| `dart run gqlify generate --explain` | Also reports, for each output, why it was regenerated, reused or removed, and the time spent per phase. |
| `dart run gqlify generate --clean` | Recomputes everything without using cached results, reconciles outputs and rebuilds the cache. It never deletes unrelated files. |
| `dart run gqlify check` | Validates and verifies that generated files are up to date without writing anything, not even cache files. Exits with `1` otherwise. Use this in CI. |
| `dart run gqlify cache verify` | Checks the integrity of the CLI cache. Exits with `1` if it is corrupt. |
| `dart run gqlify cache clear` | Deletes the CLI cache. Generated files are kept. |
| `--reporter json` | Prints one machine-readable JSON object (diagnostics, files, cache status, and with `--explain` the reasons and timings) to stdout. |
| `-C <dir>` | Runs for the package in `<dir>`. |
| `--lock-timeout <s>` | Sets how long to wait for another gqlify process on the same package (default 120). |

### build_runner

The builder is applied automatically to packages that depend on `gqlify`, and
it runs on `lib/**.graphql`, `lib/**.gql` and `lib/**.json`:

```bash
dart run build_runner build
dart run build_runner watch
```

`build_runner` tracks every input that can affect the output: the
configuration, the schema, every operation and fragment document, and the
format settings. A change to a shared fragment or to the schema therefore
regenerates every affected file, and `watch` stays correct.

- **Configuration in `pubspec.yaml` is the simplest setup.** `build_runner`
  always sees that file. It does not see `gqlify.yaml` or
  `analysis_options.yaml` unless you add them to the target sources in
  `build.yaml`:

  ```yaml
  targets:
    $default:
      sources:
        include: [$package$, lib/**, pubspec.yaml, gqlify.yaml, analysis_options.yaml]
  ```

- **Inactive builder:** if your configuration lives only in an invisible
  `gqlify.yaml`, the builder stays inactive and warns once. CLI users can
  still run `build_runner` for other generators.
- **Hidden formatter settings:** if `analysis_options.yaml` has `formatter:`
  settings that the build cannot see, the builder fails with instructions
  instead of formatting differently from the CLI.
- **Failed builds:** if a GraphQL document has an error, `build_runner`
  reports it and removes the generated files of that build. They come back
  once the error is fixed. This is standard `build_runner` behavior. The CLI
  instead leaves the previous files untouched on errors.
- **Older `build_runner` versions** need `--delete-conflicting-outputs` once,
  if files were previously generated by the CLI.
- **Only one generator should own the files:** use either the CLI or
  `build_runner` for a package, not both on the same files. Their output is
  identical, but `build_runner` keeps its own record of generated outputs.

### Performance

- **Day-to-day runs.** Unchanged inputs are verified, not regenerated. After
  an edit, only libraries whose generated source changed are reformatted.
  Formatting is the dominant cost; see [BENCHMARKS.md](BENCHMARKS.md).
- **Parallel formatting.** Large runs format libraries on 2 isolates.
  `-j/--jobs <n>` changes this: `-j 1` uses the least memory. More jobs can
  be slightly faster under JIT, but can use several GiB of memory (see
  [BENCHMARKS.md](BENCHMARKS.md)).
- **AOT executable.** On large projects, an ahead-of-time compiled CLI
  avoids start-up and JIT warm-up on every run (edits measured 1.5x faster
  on a 1,000-operation project and ~4.6x faster on the Magento schema, see
  [BENCHMARKS.md](BENCHMARKS.md)):

  ```dart
  // tool/gqlify.dart
  import 'package:gqlify/cli.dart';

  Future<void> main(List<String> args) => runGqlify(args);
  ```

  ```bash
  dart compile exe tool/gqlify.dart -o build/gqlify
  ./build/gqlify generate
  ```

  Recompile after upgrading gqlify. The cache keys on the executable's
  digest, so a stale executable never reuses results from a different
  version.

### Caching

The CLI keeps a disposable cache in `.dart_tool/gqlify/`. The cache never
changes results; deleting it only costs time:

- **Nothing changed:** if no input changed since the last successful run and
  every generated file still has the recorded content, gqlify verifies this
  and exits without regenerating.
- **Anything changed:** gqlify validates every document against the schema
  again (a cache can never hide an error). It then reuses previously
  formatted code for libraries whose generated source is identical, which
  is the expensive part.
- **On doubt:** a corrupt, outdated or inconsistent cache is ignored and
  rebuilt, and `--explain` reports why.
- **Safe under failure:** concurrent `gqlify` processes on one package wait
  for each other, and interrupted runs repair themselves on the next run.

`.dart_tool/` should not be committed.

Diagnostics use the format
`lib/graphql/products.graphql:3:5: error[unknown-field]: Cannot query field "nme" on type "Product".`
Warnings, for example `warning[deprecated-field]`, do not fail generation.

## Using the generated API

```dart
import 'package:gqlify_runtime/gqlify_runtime.dart';
import 'graphql/schema.graphql.dart';
import 'graphql/products.graphql.dart';

final api = GqlifyClient(
  transport: HttpTransport(
    Uri.parse('https://shop.example/graphql'),
    headersBuilder: (_) async => {'authorization': 'Bearer ${await token()}'},
    timeout: const Duration(seconds: 15),
  ),
);

// Short form: returns typed data, throws on any GraphQL error.
final data = await api.getProduct(sku: 'ABC123');

// Full form: errors, partial data, extensions, per-request options.
final response = await api.execute(
  const GetProductQuery(sku: 'ABC123'),
  options: const GqlifyRequestOptions(headers: {'x-store': 'de'}),
);
if (response.hasErrors) print(response.errors);
```

### Fragments

Every fragment becomes an `abstract interface class`. Every generated class
that spreads the fragment implements it, so you can write code against the
fragment once:

```dart
Widget productTile(ProductSummary p) => Text('${p.name} – ${p.price}');

productTile(data.product!);                 // from GetProduct
productTile(searchData.results.first);      // from SearchProducts
```

Fragments can live in any document and spread other fragments. Nested
selections and type conditions are typed too.

### Interfaces and unions

Fields of interface or union type decode by `__typename` into a sealed class
hierarchy. gqlify adds `__typename` to the request automatically. Every
hierarchy has an `$Other` class for types without their own selection,
including types added to the server later, so switches are exhaustive and
decoding never breaks on schema growth:

```dart
for (final hit in (await api.search(text: 'mug')).search) {
  switch (hit) {
    SearchSearch$Product() => productTile(hit),
    SearchSearch$Category(:final name) => print('Category $name'),
    SearchSearch$Other(:final typename) => print('Unhandled $typename'),
  }
}
```

### Enums

```dart
product.stockStatus == StockStatus.inStock;   // IN_STOCK -> inStock
StockStatus.inStock.value;                    // 'IN_STOCK'
```

Values unknown to the client decode to `$unknown` instead of failing.
Encoding `$unknown` throws, because it cannot be sent to the server.

### Input objects, variables and `null`

Optional fields and variables are **omitted** when you leave them `null`, so
server defaults apply. To send an explicit `null`, use `withNull`:

```dart
const filter = ProductFilter(search: 'mug', stockStatus: StockStatus.inStock);
await api.searchProducts(filter: filter);                     // {search, stock_status}
await api.searchProducts(filter: filter.withNull(minPrice: true)); // + "min_price": null
await api.execute(const SearchProductsQuery().withNull(filter: true)); // "filter": null
```

`@oneOf` inputs get one constructor per field, for example
`Lookup.sku('MUG')`.

### Custom scalars

Unmapped custom scalars are passed through as JSON (`Object`). Map them in
`gqlify.yaml` (see [Configuration](#configuration)). gqlify checks the wire
type, then calls `from_json`. A failing conversion surfaces as a
`GqlifyDecodingException`.

### Errors

| Exception | When |
| --- | --- |
| `GraphQLResponseException` | The response has GraphQL `errors`, even with partial `data`. It carries the `errors`, the partial `data` and `extensions`. |
| `GqlifyTransportException` | No GraphQL response was received: network error, timeout, or an HTTP error without a GraphQL body. |
| `GqlifyDecodingException` | The response does not match the generated types: a missing non-null field, a wrong type, a missing `__typename`, or a failing custom scalar conversion. The message names the response path, like GraphQL errors do, e.g. `Expected String at product.categories[2].name, got int`. |

All three extend the sealed `GqlifyException`.

### Types and naming

- `Int` → `int`, `Float` → `double`, `String`/`ID` → `String`, `Boolean` →
  `bool`.
- Nullable GraphQL types are nullable in Dart. Fields under `@skip`/`@include`
  are nullable because they may be absent.
- Field names become `lowerCamelCase` (`stock_quantity` → `stockQuantity`).
  Aliases become field names.
- Response classes, inputs and operations have value equality and
  `toString`. Response classes also have `toJson`/`fromJson`.
- Generated names never depend on other files. Name clashes are reported as
  errors with a suggestion (usually an alias) instead of being renamed.

### Testing without a server

```dart
import 'package:gqlify_runtime/testing.dart';

final transport = MockTransport((request) => {
  'data': {'product': {'sku': 'A', 'name': 'Mug', 'price': 9.5}},
});
final api = GqlifyClient(transport: transport);
expect((await api.getProduct(sku: 'A')).product?.name, 'Mug');
expect(transport.requests.single.variables, {'sku': 'A'});
```

## Supported today

| Feature | Status |
| --- | --- |
| Queries, mutations, variables (defaults, lists, non-null), aliases, nested selections | ✅ |
| Fragments (named, inline, nested, across files) as interfaces | ✅ |
| Interfaces and unions, sealed classes decoded by `__typename`, unknown-type fallback | ✅ |
| Enums (with unknown-value fallback), input objects, `@oneOf`, explicit `null` vs omitted | ✅ |
| Custom scalar mappings | ✅ |
| `@skip`/`@include` (optional fields), deprecation annotations and warnings | ✅ |
| SDL (multiple files, extensions) and introspection JSON schemas | ✅ |
| Modes `operations`, `schema_only`, `both` | ✅ |
| Full executable-document validation against the schema | ✅ |
| CLI `generate`, `check`, JSON reporter | ✅ |
| Incremental cache, `--clean`, `--explain`, `cache verify/clear`, process locking, crash recovery | ✅ |
| `build_runner` builder (`build`/`watch`), byte-identical to the CLI | ✅ |
| Benchmarks (incl. the Magento 2.4 schema), parallel formatting, AOT support | ✅ |
| pub.dev publication | Pending maintainer decision ([RELEASE_CHECKLIST.md](RELEASE_CHECKLIST.md)) |
| Subscriptions, persisted queries | Later |

## Development

```bash
dart pub get                     # resolves the whole workspace
dart analyze                     # strict analysis, including generated goldens
dart test packages/gqlify packages/gqlify_runtime example   # includes real build_runner runs
dart test packages/gqlify -x integration                      # skip the slow build_runner tests
(cd example && dart run gqlify check)
GQLIFY_UPDATE_GOLDENS=1 dart test packages/gqlify/test/golden_test.dart  # refresh goldens
GQLIFY_FUZZ_SEEDS=1-200 dart test packages/gqlify/test/cache_fuzz_test.dart  # longer fuzzing
```

See [ARCHITECTURE.md](ARCHITECTURE.md) for the design.
