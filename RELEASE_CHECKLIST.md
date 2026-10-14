# Release checklist

Publishing to pub.dev is irreversible: a version can be retracted, but never
deleted. Only the maintainer publishes, after going through this list.

## Before 1.0.0 (one-time decisions)

- [ ] **Name.** `gqlify` and `gqlify_runtime` were unused on pub.dev on
  2026-10-14. The name is also used by
  [`Gqlify/gqlify`](https://github.com/Gqlify/gqlify), a JavaScript GraphQL
  framework with 177 stars and the site docs.gqlify.com, and by a 2022 npm
  package. Decide whether that is acceptable (this is not legal advice).
- [ ] **Version numbers.** Both packages are `0.1.0-dev.*`. Choose the first
  public version, for example `0.1.0`.
- [ ] **Runtime compatibility.** Generated code calls `gqlify_runtime`
  helpers. State the supported runtime range in the `gqlify` README, for
  example "generator 0.x requires runtime 0.x".
- [ ] **Verified publisher.** Optionally create a pub.dev verified publisher.

## Every release

1. [ ] `main` is green on CI on Linux, macOS and Windows. CI runs format,
   strict analysis, all tests (including differential, concurrency and real
   `build_runner` integration tests), `gqlify check` in `example/`, and the
   `build_runner` ≡ CLI comparison.
2. [ ] Run long fuzzing locally:
   `GQLIFY_FUZZ_SEEDS=1-200 dart test packages/gqlify/test/cache_fuzz_test.dart`.
3. [ ] Re-run the benchmarks (`packages/gqlify/benchmark/`) and update
   `BENCHMARKS.md` if performance changed.
4. [ ] Update `CHANGELOG.md` of each package being released. List breaking
   changes to generated code first.
5. [ ] Bump the versions in both `pubspec.yaml` files. Release `gqlify_runtime`
   first if the generator needs new runtime helpers.
6. [ ] `dart pub publish --dry-run` in `packages/gqlify_runtime` and
   `packages/gqlify`: zero warnings, clean git state.
7. [ ] Tag the release (`gqlify-vX.Y.Z`, `gqlify_runtime-vX.Y.Z`) and push
   the tags.
8. [ ] `dart pub publish` (maintainer only): `gqlify_runtime` first, then
   `gqlify`.
9. [ ] Smoke test from pub.dev in a fresh package:
   - add the packages
   - generate with the CLI and with `build_runner`
   - run the example against `MockTransport`

## Breaking-change policy for generated code

Generated names, types and runtime helper signatures are public API of the
user's package:

- Renaming a generated name, changing a nullability rule or changing the
  decoding error format is a breaking change. It needs a new minor version
  before 1.0 and a new major version after.
- Changes that only alter the formatting of generated files are
  non-breaking, but must be called out: they change files that users commit.
