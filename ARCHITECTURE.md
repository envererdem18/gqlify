# gqlify architecture

This document records how gqlify is structured and why. It is updated as each
milestone lands. **Current state: Milestone B (semantic coverage and modes).**

## Packages

| Package | Kind of dependency | Contents |
| --- | --- | --- |
| `gqlify` | `dev_dependencies` | Generator engine, CLI (`dart run gqlify`), and later the `build_runner` builder. |
| `gqlify_runtime` | `dependencies` | Small, pure-Dart runtime used by generated code: client base, transports, errors, decoding helpers. Depends only on `package:http`. |

This follows the `json_serializable`/`json_annotation` convention. Applications
never ship the generator (or its `analyzer`/`dart_style` dependencies), and
`dart run gqlify ...` works because the executable lives in the `gqlify`
package.

Dependency directions:

- `gqlify` → `gql`, `dart_style`, …
- `gqlify_runtime` → `http`
- generated code → `gqlify_runtime` only

`gqlify` does not depend on `gqlify_runtime` at runtime (only in tests).

The engine is not split into a separate package. If a third-party tool needs
it, `package:gqlify/gqlify.dart` already exposes it.

## Pipeline

```text
gqlify.yaml + pubspec.yaml + analysis_options.yaml
schema (.graphql SDL files or one introspection .json) + operation documents
        │  (adapter: discovery + reads; engine does no I/O)
        ▼
GenerationInput ──► GqlifyEngine.generate ──► GenerationResult
                     1. schema loading           (schema/loader.dart, sdl_builder.dart, introspection.dart)
                     2. documents → DocumentSet  (documents/document_set.dart)
                     3. validation               (documents/validator.dart)
                     4. __typename insertion     (documents/typename.dart)
                     5. typed model (IR)         (ir/builder.dart, ir/selections.dart, ir/model.dart)
                     6. Dart emission            (emit/dart_emitter.dart)
                     7. formatting               (emit/formatter.dart)
        │
        ▼
outputs: sorted map path → exact content; diagnostics: sorted list
        │  (adapter: reconcile files on disk)
        ▼
*.graphql.dart files
```

`GqlifyEngine.generate` is a pure function: it reads nothing, writes nothing,
keeps no state between calls, and sorts its inputs. Identical inputs give
identical outputs and diagnostics. A test checks this on realistic fixtures by
reversing the input order and repeating runs. Caching (Milestone C) will sit
outside the engine as a separate layer, and the engine will keep working
without it.

Generation is **all or nothing**: if any *error* is reported, the result has no
outputs and the CLI changes no file. Warnings do not block generation; they
cover deprecated fields, arguments, enum values and input fields used by
documents, and unused fragments.

## Inputs

### Schema

- **SDL:** one or more `.graphql`/`.gql` files, merged in configured order
  (type extensions supported).
- **Introspection:** a single `.json` file containing an introspection result
  (`{"data": {"__schema": …}}` or `{"__schema": …}`).

Introspection JSON is converted to an SDL AST (`introspection.dart`) and goes
through the same schema builder and validation as SDL, so the two cannot
drift apart. A test renders the shop fixture schema as introspection JSON and
checks that both inputs generate byte-identical code, apart from the source
path in the header. Default values are parsed with the GraphQL parser;
`isOneOf` maps to `@oneOf`; built-in directives are not redefined.

### Configuration (`gqlify.yaml`)

| Key | Meaning |
| --- | --- |
| `schema` | SDL path(s) or one introspection `.json`. |
| `documents` | Globs for operation documents; default `lib/**.graphql`, `lib/**.gql`. |
| `mode` | `operations` (default), `schema_only`, `both`. |
| `client_name` | Generated client class, default `GqlifyClient`. |
| `scalars` | Custom scalar mappings (see below). |

Unknown keys are errors. `GqlifyConfig.outputFingerprint` serializes every
output-affecting setting; it will become part of the Milestone C cache key.

### Modes

| | Schema library | Document libraries |
| --- | --- | --- |
| `operations` | Client, plus the enums and input objects that operations use (transitively) | Operations, fragments |
| `schema_only` | Every enum and input object; no client | None; documents are not read or validated |
| `both` | Client, every enum and input object | Operations, fragments |

Schema-only mode deliberately does **not** generate classes for object,
interface or union types. A response's shape is the projection chosen by a
selection set, not the schema type. A "full `Product` class" would claim
fields the server never sent, or force every field to be nullable. Response
types therefore only exist per operation and fragment. Opt-in schema object
representations may be added later if a concrete use case needs them.

If a mode produces nothing for a library (for example `schema_only` on a
schema without enums or inputs), that library is not generated. Mode switches
are reconciled by the CLI like any other change: outputs that are no longer
produced are deleted.

## Validation

`package:gql` 1.0.1 audit:

- **Parser:** covers SDL and executable syntax, including extensions,
  `repeatable` directives and descriptions. Source spans are recorded **only
  on `NameNode`s**, so diagnostics point at the nearest name.
- **Printer:** does not re-escape string values. gqlify uses its own
  executable printer (`documents/printer.dart`), with round-trip tests.
- **Validation:** `validateRequest` runs an empty rule set, so gqlify
  implements executable validation itself, covering section 5 of the spec:
  - operation and fragment name uniqueness
  - field existence and leaf/composite selections
  - arguments: known, unique, required
  - literal coercion (Int range, enums, input objects, `@oneOf`)
  - directives: defined, location, uniqueness
  - variables: unique, input types, defined/used/allowed usages, traced
    through fragments across files
  - fragments: existence, type conditions, spread possibility, cycles
  - field-selection merging (`SameResponseShape`, plus name and argument
    equality for non-exclusive parents)

  On top of the spec rules, gqlify adds deprecation warnings.
- **Schema:** gqlify's own builder merges extensions, defaults the root
  types, includes built-in scalars and directives, and validates type
  references, input/output positions, interface implementations (including
  transitive interfaces, covariant field types and arguments) and union
  membership.

Subscriptions are rejected with `unsupported-subscription`.

## Generated API design

```dart
final api = GqlifyClient(transport: HttpTransport(endpoint));
final data = await api.getProduct(sku: 'ABC123');      // GetProductData
for (final hit in (await api.search(text: 'mug')).search) {
  switch (hit) {                                        // sealed by __typename
    SearchSearch$Product() => showCard(hit),            // implements ProductSummary
    SearchSearch$Category(:final name) => print(name),
    SearchSearch$Other() => {},                          // unknown/other types
  }
}
```

### Output layout

Each output is its source path with `.dart` appended:

- Each operation document gets a library with its operations and fragments.
- The schema file gets the schema library (client, enums, input objects).

Every output is owned by exactly one input, so the future `build_runner`
builder can be a plain per-input builder with no global aggregate file.
Document libraries *read* the schema and the fragments of other documents. In
builder mode those reads will go through `BuildStep`, which makes them
tracked dependencies.

Generated libraries import:

- the runtime (`gqlify_runtime.dart`, `internal.dart`)
- the schema library
- the libraries of fragments whose interfaces they implement
- custom scalar libraries

### Client methods as extensions

The schema library declares `class GqlifyClient extends GqlifyClientBase`.
Each document library adds its operations through
`extension GetProductQueryCall on GqlifyClient`.

- **No global file:** nothing has to list every operation.
- **Per-schema client:** a project with two APIs gets two client types.
- **Shadowing check:** extension members are silently shadowed by instance
  members, so method names that collide with `execute`, `close`, `transport`
  or `Object` members are `name-collision` errors.

### Names

| GraphQL | Dart |
| --- | --- |
| `query GetProduct` | `GetProductQuery` (operation), `GetProductData` (data), `getProduct` (method) |
| field `product` under `GetProduct` | `GetProductProduct`; nested `GetProductProductCategories` |
| polymorphic field `search` | sealed `SearchSearch`, variants `SearchSearch$Product`, …, fallback `SearchSearch$Other` |
| `fragment ProductCard` | `abstract interface class ProductCard`; nested `ProductCardPrice`; per-type `ProductCard$Image` |
| `enum StockStatus { IN_STOCK }` | `enum StockStatus { inStock, …, $unknown }` |
| `input ProductFilter` | `final class ProductFilter` |
| `stock_quantity`, `URL`, `IN_STOCK` | `stockQuantity`, `url`, `inStock` |
| `class`, `in`, `await` | `$class`, `$in`, `$await` |
| type `Object`, `Function` | `Object$`, `Function$` |

- **Variant separator:** variant names use a `$` separator. GraphQL names
  cannot contain `$`, so variant names never collide with field-path names.
- **Stable names:** names depend only on the definition and its selection
  path, never on generation order or other documents.
- **Collisions are errors:** two names mapping to one Dart identifier are
  reported, never renamed. All top-level names are registered in one
  registry (`ir/naming_registry.dart`), because every generated library may
  be imported together.
- **Contextual keywords are kept** (`type`, `get`, `required`).
- **Shadowing `dart:core` is safe:** explicitly imported declarations take
  precedence over it.

### Selection merging, fragments and polymorphism (`ir/selections.dart`)

#### `__typename`

Before building the IR, `__typename` is added to every selection set on an
interface or union type, both in fields and in fragment definitions on
abstract types (`documents/typename.dart`). Validation always runs on the
documents as written, so diagnostics point at user source. The request sends
the transformed document, and polymorphic results decode by `__typename`.

#### Field collection

For a selection set on a static type `P`, fields are collected *per runtime
type case*:

- **Object `P`:** there is one case, `P`.
- **Interface or union `P`:** there is one case per concrete possible type
  `T` (sorted), plus an **Other** case for types without a variant of their
  own, including types added to the schema after generation.

An inline fragment or fragment spread with type condition `C` applies:

- to case `T` if `T ∈ possibleTypes(C)`.
- to Other only if `C` is `P` itself or an interface `P` declares. For
  unknown types nothing else is guaranteed.

Each collected field occurrence keeps a *conditional* flag:
`@skip`/`@include` on the field, or on any enclosing fragment or spread.
Nested selections inherit their parent occurrence's flag. A field whose
occurrences are all conditional becomes nullable.

#### Polymorphic selections

A selection is polymorphic if some concrete case collects different fields
or fragments than Other. It is emitted as:

- **A sealed base class** with a `fromJson` factory that switches on
  `__typename`. It exposes getters for fields that have the same Dart type
  in every variant.
- **A `final class` per differing concrete type**, extending the base.
- **A `$Other` fallback class.**

Users get exhaustive `switch`es, and an unknown type decodes to `$Other`
instead of failing.

Fields whose type differs between variants are not on the base. This happens
when a variant selects more subfields of an object field, or when an object
type narrows an interface field covariantly (`title: String` →
`title: String!`). Putting them on the base would require variant-specific
nested classes to implement the base's nested class. That breaks exhaustive
switching on sealed nested hierarchies (an extra direct subtype appears).

#### Fragments become `abstract interface class`es

- **Nested selections** of a fragment become nested interfaces.
- **Polymorphic fragments** get per-type variant interfaces
  (`MediaFields$Image implements MediaFields`). Interfaces, unlike sealed
  classes, may be implemented from other libraries.
- **Which classes implement a fragment:** every response class whose case
  includes an **unconditional** spread of the fragment implements its
  interface, or the variant interface for that runtime type. Requirements
  propagate down the selection tree: a nested class implements the matching
  nested interfaces of every fragment interface its parent implements. This
  makes the overrides type-check, since nested classes are subtypes and Dart
  `List` is covariant.
- **Conditional spreads:** `...F @include(if: $x)` does **not** make the
  class implement `F`, because its fields may be absent. They are merged as
  nullable fields instead.

Fragments generate only interfaces, not standalone concrete classes. Tests
and widgets construct the operation classes, which implement the
interfaces. A concrete per-fragment class can be added if a use case
appears.

#### Reuse

A concrete case reuses the type built for Other at the same response key
when it has the *same occurrences and the same schema field type*. The
field-type check matters for covariant interface fields. Otherwise the case
gets its own nested type (`Base$TypeKey`).

### Schema types

#### Enums

- **Shape:** Dart enums with the GraphQL name in `value`, plus `$unknown`
  for values the client does not know. Decoding never fails on schema
  growth.
- **Encoding `$unknown`:** throws `UnsupportedError`. The raw value is not
  kept, so it cannot be sent back to the server.
- **Annotations:** deprecated values get `@Deprecated`.

#### Input objects

`final class`es with a const constructor:

- **Required fields:** non-null without a default.
- **Optional fields:** may be `null`, in which case they are *omitted* and
  server defaults apply.

`withNull(field: true)` returns a copy that sends an explicit `null`, so the
three states (omitted, `null`, value) stay type safe without wrapper types.
Operation variables use the same scheme: the short method omits optional
variables, and `execute(SomeQuery(...).withNull(x: true))` sends `null`.

`@oneOf` inputs get one named constructor per field
(`Lookup.sku('MUG')`), so invalid states cannot be built.

Inputs and operation classes have value equality; operations compare by
encoded variables.

#### Custom scalars

```yaml
scalars:
  DateTime:
    type: DateTime                         # Dart type
    json_type: String                      # wire type, checked before conversion
    from_json: DateTime.parse              # (json_type) -> type
    to_json: encodeDateTime                # optional; (type) -> JSON
    import: package:app/scalars.dart
```

- **Decoding:** the generated code checks the wire value against
  `json_type`, then calls `from_json`. Exceptions thrown by `from_json` are
  reported as `GqlifyDecodingException`.
- **Without `from_json`:** `type` must itself be a JSON type.
- **Unmapped custom scalars** are raw JSON (`Object`).
- **Config errors:** mapping a built-in scalar, or a scalar the schema does
  not define, is an error.

### Nullability and decoding

Decoding is eager and validated. A missing non-null field, a wrong JSON type
or a missing `__typename` throws `GqlifyDecodingException` with a location
such as `GetProductProduct.categories[]`. It never fails lazily or coerces a
value.

### Errors

| Situation | Short method (`api.getProduct`) | `api.execute(GetProductQuery(...))` |
| --- | --- | --- |
| `data` only | returns data | `GqlifyResponse` with data |
| `errors` (with or without partial data) | throws `GraphQLResponseException` (partial data attached) | returns response with `errors` and decoded `data` |
| errors, and partial data that does not decode | throws `GraphQLResponseException` | response with `dataDecodingError` |
| data that does not decode, no errors | throws `GqlifyDecodingException` | throws `GqlifyDecodingException` |
| neither `data` nor `errors` | throws `GqlifyDecodingException` | throws `GqlifyDecodingException` |
| network failure, timeout, non-GraphQL HTTP error | throws `GqlifyTransportException` | throws `GqlifyTransportException` |

### Embedded documents

Each operation embeds a `const String` with the operation followed by every
transitively spread fragment (sorted by name). Everything is printed
canonically from the transformed AST, so `__typename` additions are
included and comments and formatting are not.

### Formatting

Generated code is formatted with `dart_style`, using the consuming package's
language version (from `pubspec.yaml`) and its `analysis_options.yaml`
`formatter:` settings (`page_width`, `trailing_commas`). Line endings are
always `\n`. As a result, `dart format` in the consuming package leaves
generated files unchanged; this was found and fixed in Milestone A.

Remaining risk: the formatter bundled with the SDK can differ from the
`dart_style` version resolved for gqlify.

## CLI adapter

- `gqlify generate`
  - Writes only files whose bytes changed, each through a temporary file and
    a rename.
  - Deletes stale outputs.
  - Refuses to overwrite files it did not generate.
- `gqlify check`
  - Writes nothing.
  - Fails on errors or on missing, outdated, stale or conflicting outputs.
- `--reporter json`
  - Prints one JSON object with the command, success, diagnostics (severity,
    code, message, path, line, column), affected files by category, and
    elapsed time.
- **Ownership without a cache:** a file is a gqlify output if its name ends
  in `.graphql.dart`/`.gql.dart`/`.json.dart` and it starts with the
  generated-code marker.

Not yet implemented (Milestone C): the `.dart_tool/gqlify/` cache, locking,
`--clean`, `--explain`, `cache verify` and `cache clear`.

## Testing

- **Runtime:** client semantics and `HttpTransport` behavior.
- **Schema and validation:** schema building, every validation rule, and
  deprecation warnings.
- **Printer and naming:** printer round-trips and naming rules.
- **Engine:** modes, scalar config validation, collisions, determinism.
- **Introspection:** introspection ≡ SDL equivalence, and malformed input.
- **CLI integration:** no-op runs, `check`, stale removal, conflicts, mode
  switches, the JSON reporter, and warnings.
- **Golden fixtures** (`packages/gqlify/test/fixtures/*`): committed outputs
  are regenerated and compared byte for byte. Root `dart analyze`
  (`strict-casts`, `strict-inference`, `strict-raw-types`) covers them, which
  proves the generated code compiles. The fixtures are:
  - `edge_cases`: escaped names, nested nullable lists, conditional fields,
    custom JSON scalars
  - `shop`: fragments across files, nested fragment interfaces, enums,
    inputs, `@oneOf`, custom scalar mapping, union and interface fields
  - `polymorphism`: interfaces implementing interfaces, interface fragments
    inside unions, conditional spreads, nested polymorphism inside
    fragments, covariant fields, aliased `__typename`
  - `schema_only`: every enum and input, recursive inputs, reserved enum
    value names
- **Runtime tests on fixture output:** they execute `edge_cases`, `shop` and
  `polymorphism` against `MockTransport`, including unknown types, unknown
  enum values, explicit nulls and fragment-typed parameters.
- **`example/`:** the generated API is used like an application would use
  it, and its outputs are checked for freshness.

## Known limitations (after Milestone B)

- **Subscriptions:** not supported (`unsupported-subscription`).
- **Unknown enum values:** `$unknown` cannot be encoded, so a response
  containing it cannot be round-tripped through `toJson`.
- **Fragment classes:** fragments produce interfaces only, not concrete
  classes.
- **Schema-only object types:** schema-only mode does not generate object,
  interface or union types (see Modes).
- **Introspection diagnostics:** errors in an introspection schema have no
  line and column information.
- **Not yet built:** the CLI cache (Milestone C) and the `build_runner`
  builder (Milestone D).
