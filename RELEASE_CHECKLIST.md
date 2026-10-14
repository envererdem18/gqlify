# Release checklist

Publishing to pub.dev is irreversible: a version can be retracted, but never
deleted. Only the maintainer publishes, after going through this list.

## Decisions (2026-10-14)

- **Name:** `gqlify` is kept. It is free on pub.dev. A JavaScript project
  ([`Gqlify/gqlify`](https://github.com/Gqlify/gqlify)) uses the same name in
  another ecosystem; this was considered and accepted.
- **First version:** `0.1.0` for both packages.
- **Publisher:** published by the maintainer's verified publisher, once CI is
  green on Linux, macOS and Windows.
- **Runtime compatibility:**
  - Before 1.0, `gqlify` and `gqlify_runtime` share the minor version
    (gqlify 0.1.x generates code for gqlify_runtime 0.1.x).
  - After 1.0, they share the major version.
  - The policy is enforced by the `runtime-version` warning
    (`compatibleRuntimeVersions` in `lib/src/runtime_version.dart`).
    Update that constraint whenever the minor or major version changes.

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
