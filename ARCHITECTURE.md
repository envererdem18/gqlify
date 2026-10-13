# gqlify architecture

This document records how gqlify is structured and why. It is updated as each
milestone lands. **Current state: Milestone D (build_runner support).**

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

### Configuration (`gqlify.yaml` or `pubspec.yaml`)

Settings are read from `gqlify.yaml` or from the `gqlify:` section of
`pubspec.yaml`. Having both is an `ambiguous-config` error. One function
(`resolveConfig`) locates and parses them for both adapters.

`pubspec.yaml` is supported because it is always visible to `build_runner`,
while root files such as `gqlify.yaml` are not part of build_runner's default
sources.

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

- `gqlify generate [--clean] [--explain]`
  - Writes only files whose bytes changed, each through a temporary file and
    a rename.
  - Deletes stale outputs.
  - Refuses to overwrite files it did not generate.
- `gqlify check [--clean] [--explain]`
  - Writes nothing: no outputs and no cache files.
  - Fails on errors or on missing, outdated, stale or conflicting outputs.
- `gqlify cache verify` and `gqlify cache clear`
  - Act on the CLI cache only, never on `.dart_tool/build/` and never on
    generated files.
- `--reporter json`
  - Prints one JSON object: command, success, diagnostics, affected files by
    category, cache status, and with `--explain` per-output reasons and
    per-phase timings.
- **Ownership without a cache:** a file is a gqlify output if its name ends
  in `.graphql.dart`/`.gql.dart`/`.json.dart` and it starts with the
  generated-code marker. Stale outputs are found even with no cache at all.

## build_runner adapter (`builder/gqlify_builder.dart`)

### Builder shape

The builder is a **plain per-input builder** with
`build_extensions: {.graphql: [.graphql.dart], .gql: [.gql.dart], .json: [.json.dart]}`.
It is applied to dependents and runs on `lib/**` by default.

Every output is owned by exactly one input:

- a document's library is owned by the document;
- the schema library is owned by the first schema file.

No global aggregate file exists; the extension-based client design made this
possible (see "Client methods as extensions"). Inputs that are neither
documents nor the first schema file (unrelated `.json` files, extra schema
files) produce nothing.

### Dependency tracking

Each step reads, through `BuildStep`:

- the configuration (`pubspec.yaml`, `gqlify.yaml` if visible)
- every schema file
- every document found with `findAssets` for the configured globs
- `analysis_options.yaml` if visible

`build_runner` therefore records all of them as dependencies. A step's output
can depend on any document (fragments, global validation, name collisions),
so editing any document reruns every step. Unchanged outputs are recognized
by digest and do not invalidate anything downstream.

The builder reads nothing behind build_runner's back. There is one exception,
used only to *refuse to proceed*, never as an input:

- **`gqlify.yaml` exists on disk but is invisible:** the builder warns once
  and stays inactive, so CLI-only users can still run build_runner for other
  generators.
- **`analysis_options.yaml` has invisible `formatter:` settings:** the
  builder fails with instructions instead of silently formatting differently
  from the CLI.

### One engine run per build

Steps share results through a `Resource`: a map from the input digest to
`Future<GenerationResult>`. The engine therefore runs once per distinct input
set per build, not once per step. A bounded in-memory formatting memo keeps
formatter results across `watch` rebuilds. Formatting is a pure function of
the memo key, so sharing it cannot change results. The builder keeps **no
persistent cache**: build_runner owns incrementality in `.dart_tool/build/`.

### Diagnostics

Every diagnostic is logged by exactly one step: the step whose input
contains it. Diagnostics located elsewhere (configuration, other schema
files) go to the schema step. Errors make the build fail and no output is
written.

On a failure, build_runner removes the outputs of that build until the error
is fixed. The CLI keeps the previous files instead. This is the one
documented behavioral difference between the adapters, and it is inherent to
build_runner owning its outputs.

### Equivalence with the CLI

Both adapters build the same `GenerationInput`:

- the same configuration resolution
- the same document globs
- schema files in configured order
- documents sorted by path
- format settings from the same files

They call the same engine, so outputs are byte-identical. This is checked at
three levels:

- **`builder_test.dart`** (`build_test`): outputs equal the engine's for the
  shop fixture (via `gqlify.yaml`, via `pubspec.yaml`, and with
  `analysis_options.yaml`). It also checks schema-only mode, that each error
  is reported once, and the tracked inputs of a step.
- **`build_runner_integration_test.dart`** (tag `integration`):
  - Runs the real `build_runner build` and compares it with a clean CLI
    generation.
  - Runs the real `build_runner watch` and, after each of these, compares
    again with a clean CLI generation:
    - an operation change
    - a shared fragment change
    - a schema change
    - a new document in a new directory
    - an invalid document (both adapters must fail)
    - deleting that document (recovery)
- **CI** runs `build_runner build` in `example/` and fails if any committed
  (CLI-generated) file changes.

## Incremental caching (CLI)

**Invariant:** `GeneratedFiles(incremental) == GeneratedFiles(clean)`, for the
whole mapping of output paths to bytes, including removed files, plus
identical diagnostics and exit codes.

The cache is an optimization only. It lives in `.dart_tool/gqlify/`
(`cache/cache_store.dart`) and may be deleted at any time:

```text
.dart_tool/gqlify/
  manifest.json                 last successful run
  artifacts/<generator>/<key>   memoized formatter output
  tmp/                          files being written
  lock                          inter-process lock
```

### What is cached, and why that is safe

1. **Warm hit (nothing to do).**
   - **The input key.** A run hashes, with SHA-256:
     - the cache format version
     - the generator fingerprint
     - the raw `gqlify.yaml`
     - the format settings (from `pubspec.yaml` and `analysis_options.yaml`)
     - every schema file and every discovered document, path plus content
   - **Conditions for a hit.** The input key must equal the manifest's, every
     recorded output must exist with its recorded digest, and no other
     gqlify-owned file may exist.
   - **On a hit**, the engine is skipped entirely and the recorded
     diagnostics (warnings) are replayed. Equal input keys mean equal engine
     input, and the engine is a pure function, so this is the clean result.
   - **On any doubt** (missing, corrupt or incompatible manifest, a missing
     or modified output, an unexpected generated file), the run falls back
     to the next step and reports why.
2. **Everything else.**
   - The engine runs **in full**: schema loading, parsing and validation of
     every document, IR building and emission. A cache therefore can never
     hide a new error.
   - **Only formatting is memoized** (`FormatMemo`). It is by far the most
     expensive phase (more than 80% of engine time in the `--explain`
     timings of the example package; Milestone E will benchmark properly).
     Formatting is a pure function of the unformatted source and the format
     settings. The memo key is the SHA-256 of exactly that input, and
     artifacts are namespaced by the generator fingerprint, which covers the
     `dart_style` version. A memo hit is therefore the formatter's output for
     that exact input and can never be stale.
   - **Self-verifying artifacts.** Each artifact stores
     `<sha256 of content>\n<content>`, so truncated or corrupted artifacts
     are detected and ignored.

### Why the dependency graph is not part of invalidation

The engine reports, per output, which documents can affect it
(`GenerationResult.dependencies`):

- **A document library** depends on its own document and on the documents
  of all transitively spread fragments.
- **The schema library**, in operations mode, depends on every document,
  because it holds the enums and inputs that operations use.

gqlify uses this graph for **explanations** (`--explain`), not to skip
work. Invalidation is content-addressed, so a missing edge in the graph
cannot produce stale output. A graph-based skip would save only IR building
and emission, which are cheap next to formatting and validation. Validation
must stay global anyway, because a schema change can invalidate any
document. Graph-based skipping of IR/emission is a possible later
optimization; it would need differential tests proving it equivalent.

To make the graph exact, emission order inside a library is canonical:
definition index in the document, then creation order. Without this, the
order would depend on which document first triggered a fragment, so editing
one document could reorder another file.

### Generator fingerprint

The fingerprint (`cache/fingerprint.dart`) is the SHA-256 of:

- the complete source of `package:gqlify` (not just its version, so local
  development edits invalidate caches)
- the resolved versions and locations of `gql`, `dart_style` and `analyzer`
- the Dart SDK version

If it cannot be determined, for example in an AOT build without package
resolution, caching is disabled and reported as such. This is never a
silent hit.

### Crash safety and concurrency

- **Write ordering.** The manifest is deleted *before* outputs change. It is
  written atomically (temporary file plus rename), *after* every output has
  been written and re-read with a matching digest. A manifest therefore
  always describes a complete, verified state.
- **Interruption.** If a run dies midway, the next run sees no manifest, or
  an old one whose key or output digests do not match, and recomputes.
- **Leftover temporary files.** `.<name>.<pid>.gqlify-tmp` files from killed
  processes are deleted by the next run.
- **Failed runs** (invalid inputs, write errors, a full disk, read-only
  directories) never write a manifest. Errors are reported as `write-failed`
  with the OS error, and the next successful run repairs partially updated
  outputs.
- **Locking.** `generate` and `cache clear` take an exclusive OS file lock;
  `check` and `cache verify` take a shared one.
  - The OS releases the lock when a process exits or crashes, so stale locks
    cannot occur.
  - Waiting is announced on stderr, and `--lock-timeout` bounds it (default
    120 s).
  - Limitation: OS locks exclude processes, not isolates of one process.
- **Manually edited outputs** are detected by digest and regenerated. Files
  without the generated-code marker are never overwritten
  (`output-conflict`).
- **Durability.** Files are flushed before the rename. Directory entries are
  not fsynced, because Dart has no API for it. After a power loss a rename
  may be lost; the next run then detects missing or old outputs by digest.

### `--explain`

For every output, `--explain` reports:

- **Status:** `created`, `updated`, `unchanged`, `removed` or `conflict`.
- **Reasons**, for example:
  - `no previous cache`
  - `cache ignored: generator changed`
  - `configuration changed`
  - `format settings changed`
  - `schema changed`
  - `document changed`
  - `transitive fragment document changed: lib/…`
  - `new output`
  - `output modified on disk`
  - `no longer generated …`
- **Formatting:** whether it was reused from the cache.

It also prints the cache status (hit, or miss with its cause) and timings per
phase (discovery, hashing, scan, engine phases, write, verify, cache).

## Testing

- **Runtime:** client semantics and `HttpTransport` behavior.
- **Schema and validation:** schema building, every validation rule, and
  deprecation warnings.
- **Printer and naming:** printer round-trips and naming rules.
- **Engine:** modes, scalar config validation, collisions, determinism.
- **Introspection:** introspection ≡ SDL equivalence, and malformed input.
- **CLI integration:** no-op runs, `check`, stale removal, conflicts, mode
  switches, the JSON reporter, and warnings.
- **Differential cache tests** (`cache_*_test.dart`, tag `differential`):
  after every step, the incremental tree in one sandbox is compared with a
  clean generation in a fresh copy of the sources: exit code, diagnostics,
  and the full path → bytes mapping. Failed runs must leave files unchanged.
  - **Scenarios.** They cover cold, warm and single-operation changes, plus:
    - fragments: shared, nested or transitive, moved, renamed (dangling),
      cycles, invalid spreads, deleted
    - schema: field added, removed or renamed, nullability, enums, inputs,
      a type renamed, a swap to introspection JSON
    - configuration: mode switches, client name, scalar mapping, format
      settings, a moved schema (output location), narrowed document globs
    - failures: duplicate operations, invalid variables, syntax errors
    - disturbed state: deleted or edited outputs, a truncated or garbage
      manifest, format and generator mismatches, corrupt artifacts, an
      unexpected generated file, a deleted cache, `--clean`
    - reproducible ordering
  - **Failure injection:** an interrupted multi-file write, a full disk,
    leftover temporary files, a read-only directory.
  - **Concurrency (separate processes):** two simultaneous `generate` runs,
    a lock held by a process killed with SIGKILL, waiting for a running
    process.
  - **Property-based fuzzing:** seeded random edit sequences on a synthetic
    project, mixed with cache and output disturbances and `--clean`, check
    the invariant after every step and require a warm hit when re-run
    unchanged. By default 4 seeds × 14 steps run;
    `GQLIFY_FUZZ_SEEDS=1-200` runs more. 40 seeds (560 steps) passed locally.
  - **Large fixture:** 240 operations, 40 fragments and 40 documents (cold,
    warm, shared fragment change, schema change).
  - **Harness self-test:** a deliberately lying cache (a tampered output
    with a consistent manifest) must be caught by the comparison.
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

## Known limitations (after Milestone D)

- **Subscriptions:** not supported (`unsupported-subscription`).
- **Unknown enum values:** `$unknown` cannot be encoded, so a response
  containing it cannot be round-tripped through `toJson`.
- **Fragment classes:** fragments produce interfaces only, not concrete
  classes.
- **Schema-only object types:** schema-only mode does not generate object,
  interface or union types (see Modes).
- **Introspection diagnostics:** errors in an introspection schema have no
  line and column information.
- **Output scan cost:** the ownership scan walks the whole package (except
  `build/`, `.dart_tool/` and hidden directories) on every run, so that
  stale outputs are found even without a cache. This may be slow in very
  large repositories; Milestone E will measure it.
- **Artifact pruning:** formatting artifacts are pruned to those of the last
  successful run, so undoing an edit reformats once.
- **Unverified on this machine:** Windows file locking and path handling are
  covered by CI only.
- **Failed builds under build_runner:** they remove generated files until
  fixed (see build_runner adapter). The CLI keeps them.
- **Rerun scope:** under build_runner every step depends on every document,
  so one edit reruns all steps. The engine still runs only once, and
  unchanged outputs do not propagate.
- **`analysis_options.yaml` includes:** only the top-level file's
  `formatter:` section is read, by both adapters.
