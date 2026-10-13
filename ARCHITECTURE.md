# gqlify architecture

This document records how gqlify is structured and why. It is updated as each
milestone lands. **Current state: Milestone A (working vertical slice).**

## Packages

| Package | Kind of dependency | Contents |
| --- | --- | --- |
| `gqlify` | `dev_dependencies` | Generator engine, CLI (`dart run gqlify`), and later the `build_runner` builder. |
| `gqlify_runtime` | `dependencies` | Small, pure-Dart runtime used by generated code: client base, transports, errors, decoding helpers. Depends only on `package:http`. |

This follows the `json_serializable`/`json_annotation` convention. Applications
never ship the generator (or its `analyzer`/`dart_style` dependencies), and
`dart run gqlify ...` works because the executable lives in the `gqlify`
package. Dependency direction: `gqlify` → `gql`, `dart_style`, …;
`gqlify_runtime` → `http`; generated code → `gqlify_runtime` only. `gqlify`
does not depend on `gqlify_runtime` at runtime (only in tests).

The engine is not split into a separate package. If a third-party tool needs
it, `package:gqlify/gqlify.dart` already exposes it.

## Pipeline

```text
gqlify.yaml + pubspec.yaml + analysis_options.yaml
schema .graphql files + operation .graphql/.gql files
        │  (adapter: discovery + reads; engine does no I/O)
        ▼
GenerationInput ──► GqlifyEngine.generate ──► GenerationResult
                     1. SDL → Schema               (schema/sdl_builder.dart)
                     2. documents → DocumentSet    (documents/document_set.dart)
                     3. validation                 (documents/validator.dart)
                     4. typed model (IR)           (ir/builder.dart, ir/model.dart)
                     5. Dart emission              (emit/dart_emitter.dart)
                     6. formatting                 (emit/formatter.dart)
        │
        ▼
outputs: sorted map path → exact content; diagnostics: sorted list
        │  (adapter: reconcile files on disk)
        ▼
*.graphql.dart files
```

`GqlifyEngine.generate` is a pure function: it reads nothing, writes nothing,
keeps no state between calls, and sorts its inputs. Identical inputs give
identical outputs and diagnostics. Caching (Milestone C) will sit outside the
engine as a separate layer, and the engine will keep working without it.

Generation is **all or nothing**. If any error diagnostic is reported, the
result has no outputs, and the CLI leaves every file as it was.

## Dependency audit: `package:gql` 1.0.1

gqlify uses `gql` only for lexing/parsing into its AST. The audit found:

- **Parser:** covers SDL and executable syntax, including extensions,
  `repeatable` directives and descriptions. Source spans are recorded **only
  on `NameNode`s**, so diagnostics point at the nearest name (field,
  argument, variable).
- **Printer:** does not re-escape string values. `"a\"b"` parses to `a"b`
  and prints as `"a"b"`, which is invalid GraphQL. gqlify uses its own
  executable printer (`documents/printer.dart`) for embedded documents. A
  round-trip test covers escapes.
- **Validation:** `validateRequest` runs an empty rule set, and the available
  rules are SDL-only. gqlify implements executable validation itself, covering
  section 5 of the GraphQL spec:
  - operation and fragment name uniqueness
  - field existence, leaf vs. composite selections
  - argument names, uniqueness and required arguments
  - literal value coercion, including Int range, enums, input objects and
    `@oneOf`
  - directive existence, location and uniqueness
  - variable uniqueness, input types, defined, used and allowed usages
    (including default-value relaxation), traversed through fragments
  - fragment existence, type conditions, spread possibility and cycles
  - field-selection merging (`SameResponseShape` plus name and argument
    equality for non-exclusive parents)

  Unused fragments are a *warning*, not an error: fragments also act as
  reusable types.
- **Schema building:** gqlify builds its own `Schema` model. It merges type
  extensions, defaults the root types, includes built-in scalars and
  directives, and validates type references, input/output positions,
  interface implementations (including transitive interfaces and argument
  compatibility) and union membership.

## Generated API design

Example (from `example/`):

```dart
final api = GqlifyClient(transport: HttpTransport(endpoint));
final data = await api.getProduct(sku: 'ABC123');      // GetProductData
data.product?.categories.first.name;
await api.addToCart(cartId: 'c1', sku: 'ABC123', quantity: 2);
```

### Output layout

Each output is its source path with `.dart` appended:

- `lib/graphql/products.graphql` → `lib/graphql/products.graphql.dart`, which
  holds the operations defined in that document.
- `lib/graphql/schema.graphql` → `lib/graphql/schema.graphql.dart`, which
  holds the client class (and, from Milestone B, schema types such as enums
  and inputs).

Every output is owned by exactly one input. A future `build_runner` builder can
therefore be a plain per-input builder (`.graphql` → `.graphql.dart`) with a
deterministic output set and no global aggregate file. A builder cannot safely
own an aggregate file. Each document library still needs to *read* the schema
(and later, fragments from other files). In builder mode that read goes
through `BuildStep`, so the dependency is tracked.

### Client methods as extensions

The schema library declares `class GqlifyClient extends GqlifyClientBase`.
Each document library adds its operations through
`extension GetProductQueryCall on GqlifyClient`.

- **No global file:** nothing has to list every operation (see output layout
  above).
- **Per-schema client:** the name is configurable with `client_name`. A
  project with two APIs gets two client types, so operations of one API never
  appear on the other's client.
- **Shadowing check:** extension members are silently shadowed by instance
  members. Operations whose method name would collide with `execute`,
  `close`, `transport` or `Object` members are reported as `name-collision`
  errors.

### Names

| GraphQL | Dart |
| --- | --- |
| `query GetProduct` | `GetProductQuery` (operation class), `GetProductData` (data), `getProduct` (method) |
| `query GetProductQuery` | same names; the operation-kind suffix is not doubled |
| field `product` under `GetProduct` | class `GetProductProduct`; nested: `GetProductProductCategories` |
| `stock_quantity`, `URL` | `stockQuantity`, `url` |
| `class`, `in`, `await` | `$class`, `$in`, `$await` |
| type `Object`, `Function` | `Object$`, `Function$` |

- **Stable names:** names depend only on the operation and its selection
  path, never on generation order or other documents.
- **Collisions are errors:** two names mapping to the same Dart identifier
  (for example `sale_price` and `salePrice`) produce a diagnostic that
  suggests an alias, instead of a numeric suffix that could change when an
  unrelated file is edited.
- **Contextual keywords are kept:** `type`, `get`, `required` and similar are
  valid member names and are not escaped.
- **Shadowing `dart:core` is safe:** explicitly imported declarations take
  precedence over `dart:core`, so a schema type named `Error` or `Duration`
  is fine. Only names that generated code itself references unqualified
  (`String`, `Map`, `Object`, runtime types, …) are escaped.

### Nullability and response semantics

- Nullable GraphQL types become nullable Dart types.
- Fields under `@skip`/`@include` with a non-constant condition become
  nullable, because they may be absent from the response.
- `Float` decodes from any JSON number.
- Unmapped custom scalars are `Object`/`Object?` (raw JSON). Configurable
  mappings arrive in Milestone B.
- Decoding is eager and validated. A missing non-null field or a wrong type
  throws `GqlifyDecodingException` with a location such as
  `GetProductProduct.categories[]`. It never fails lazily or coerces a value.

### Variables

- **Required:** non-null without a default becomes a `required` parameter.
- **Optional:** everything else is an optional, nullable parameter. It is
  omitted from `variables` when `null`, so server-side defaults apply.
- **Limitation (scoped to Milestone B):** an explicit `null` cannot yet be
  sent for a nullable variable. For variables this rarely matters, because
  an omitted nullable variable and `null` have the same effect unless the
  argument has a non-null default. Input object fields will need explicit
  null support.

### Errors

| Situation | Short method (`api.getProduct`) | `api.execute(GetProductQuery(...))` |
| --- | --- | --- |
| `data` only | returns data | `GqlifyResponse` with data |
| `errors` (with or without partial data) | throws `GraphQLResponseException` (partial data attached) | returns response with `errors` and decoded `data` |
| errors, and partial data that does not decode | throws `GraphQLResponseException` | response with `dataDecodingError` |
| data that does not decode, no errors | throws `GqlifyDecodingException` | throws `GqlifyDecodingException` |
| neither `data` nor `errors` | throws `GqlifyDecodingException` | throws `GqlifyDecodingException` |
| network failure, timeout, non-GraphQL HTTP error | throws `GqlifyTransportException` | throws `GqlifyTransportException` |

A response with errors is never silently treated as success. `HttpTransport`
treats a non-2xx response that has a GraphQL-shaped body as a GraphQL
response, following GraphQL over HTTP.

### Embedded documents

Each operation class embeds its document as a `const String`. The document is
printed canonically (compact, no comments) from the AST, so formatting-only
changes to a `.graphql` file do not change the request. No `.graphql` file is
read and nothing is parsed at runtime.

### Formatting

Generated code is formatted with `dart_style`, using the consuming package's
language version (the lower bound of `environment.sdk` in `pubspec.yaml`) and
the `formatter:` options in its `analysis_options.yaml` (`page_width`,
`trailing_commas`). Line endings are always `\n`.

The goal is that `dart format` in the consuming package never changes
generated files, so `dart format --set-exit-if-changed` in CI and
`gqlify check` agree. This was found in testing: with a fixed formatter
language version, files formatted as 3.7 were reformatted by a 3.8 package.
These settings are part of the generation input, and the Milestone C cache
key will include them.

Remaining risk: if the SDK's bundled formatter differs from the `dart_style`
version resolved for gqlify, their output can still differ in rare cases.

## CLI adapter (Milestone A)

- `gqlify generate`
  - Loads `gqlify.yaml`, discovers documents with globs, runs the engine and
    reconciles files on disk.
  - Writes only files whose bytes changed, each through a temporary sibling
    file and a rename.
  - Deletes stale outputs.
  - Refuses to overwrite a file that gqlify did not generate.
- `gqlify check`
  - Same as `generate`, but writes nothing.
  - Exits with 1 on invalid input, or on missing, changed, stale or
    conflicting outputs.
- **Ownership is decided without a cache.** A file is a gqlify output if its
  name ends in `.graphql.dart`/`.gql.dart` *and* it starts with the
  generated-code marker. Stale outputs are therefore found even if every cache
  is deleted, which supports the invariant "deleting caches changes speed
  only".

Not yet implemented (Milestone C): the `.dart_tool/gqlify/` cache, process
locking, `--clean`, `--explain`, `cache verify` and `cache clear`.

## Testing strategy so far

- `gqlify_runtime`:
  - client semantics: data, errors, partial data, decoding failures,
    extensions, options
  - `HttpTransport` with `MockClient`: headers, non-2xx, invalid JSON,
    network failures, timeout
- `gqlify`:
  - schema building and its errors
  - every validation rule, with positive and negative cases
  - printer round-trip and escaping
  - naming rules
  - engine determinism (input order), all-or-nothing failure, explicit
    unsupported-feature diagnostics, collisions, format settings
  - CLI integration in temporary directories: no-op runs, `check`, stale
    removal, conflicts, invalid input leaving files untouched
- Golden fixtures (`packages/gqlify/test/fixtures/*`): committed outputs are
  regenerated and compared byte for byte. Because they are committed, root
  `dart analyze` (strict casts, inference and raw types) proves they compile.
  A runtime test then executes the edge-case output (escaped names, nested
  nullable lists, conditional fields, custom scalars).
- `example/`: the generated API runs against `MockTransport`. The engine test
  `example package outputs match a fresh generation` keeps the committed
  outputs fresh.

## Milestone A scope and known limitations

Explicitly reported as `unsupported-feature` diagnostics (never silently
mis-generated):

- fragments (named and inline)
- enum fields and variables
- input-object variables
- interface and union fields
- the `schema_only` and `both` modes
- introspection JSON schemas
- subscriptions
- configurable scalar mappings

Planned for Milestone B (subscriptions later). Also pending:

- explicit `null` for nullable variables and input fields
- deprecation warnings for selected deprecated fields
- the `build_runner` builder (Milestone D)
- the CLI cache (Milestone C)
