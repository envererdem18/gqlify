# Benchmarks

These are measured results, not estimates. To reproduce them:

```bash
cd packages/gqlify
./benchmark/fetch_magento.sh            # optional: Magento 2.4 schema (not committed)
dart run benchmark/gqlify_benchmark.dart --iterations 3 --build-runner
dart run benchmark/gqlify_benchmark.dart --fixtures large,magento --iterations 3 --aot
dart run benchmark/profile_engine.dart large 3 [workers]   # in-process engine phases
```

## Method

- **Measured as users run it.** Each scenario is a separate CLI process,
  timed from the outside, so startup is included:
  - JIT: `dart run gqlify generate --explain --reporter json`
  - AOT: the same CLI compiled with `dart compile exe`
- **Phase timings and peak memory** come from the CLI's `--explain` report
  (`peakRssBytes` is the process's maximum resident set size).
- **Scenarios, per iteration:**
  - cold (no cache, no outputs)
  - warm (no change)
  - one operation document changed
  - a shared fragment changed
  - the schema changed
  - `--clean`
  - Iterations start from a fresh tree; the tables report the median and
    the min–max of 3 iterations.
- **Fixtures:**
  - **small:** `example/`, with 5 operations.
  - **medium:** synthetic; 69 types, 200 operations, 30 fragments.
  - **large:** synthetic; 409 types, 1,000 operations, 120 fragments. Deep
    selections (3 levels, interfaces and type conditions) produce about
    45 MiB of generated Dart.
  - **magento:** the open-source Magento 2.4 GraphQL schema, merged from its
    41 module schemas at commit `ef53290` (428 types, 2,001 fields), with
    300 generated operations and 60 fragments.
  - Operations are generated randomly with fixed seeds, and every one is
    validated by gqlify before use.
- **Environment:** Dart 3.12.2, macOS 27.0.1, Apple Silicon, 8 logical
  CPUs. Other applications were running; see the note at the end.

## Results (JIT, `dart run gqlify`)

These were measured with 4 formatting isolates, the default at the time. The
default is now 2 (see [Formatting isolates](#formatting-isolates)). This only
affects the **cold** and **`--clean`** rows: edits format one library at a
time, which is always sequential.

### small (example/)

| Scenario | Wall time | Engine | Formatting | Peak RSS |
| --- | --- | --- | --- | --- |
| cold | 1.07 s (1.04–1.07) | 298 ms | 250 ms | 154 MiB |
| warm | 766 ms (728–807) | — | — | 123 MiB |
| one operation changed | 1.05 s (1.04–1.12) | 276 ms | 229 ms | 155 MiB |
| shared fragment changed | 1.03 s (1.02–1.06) | 285 ms | 239 ms | 155 MiB |
| schema changed | 787 ms (785–809) | 47 ms | 2 ms | 131 MiB |
| `--clean` | 1.05 s (1.05–1.06) | 304 ms | 255 ms | 154 MiB |

For small projects, about 0.7 s of every run is JIT start-up of `dart run`.

### medium (synthetic, 200 operations)

| Scenario | Wall time | Engine | Formatting | Peak RSS |
| --- | --- | --- | --- | --- |
| cold | 4.08 s (4.06–26.94*) | 3.17 s | 2.84 s | 362 MiB |
| warm | 899 ms (889–957) | — | — | 135 MiB |
| one operation changed | 1.82 s (1.78–1.83) | 951 ms | 627 ms | 227 MiB |
| shared fragment changed | 2.65 s (2.49–2.77) | 1.66 s | 1.30 s | 307 MiB |
| schema changed | 1.52 s (1.46–1.53) | 606 ms | 244 ms | 227 MiB |
| `--clean` | 3.99 s (3.84–4.16) | 3.20 s | 2.87 s | 458 MiB |

\* One outlier in the first iteration. It was not reproduced, and its cause is
unknown.

### large (synthetic, 1,000 operations, ~45 MiB of output)

| Scenario | Wall time | Engine | Formatting | Peak RSS |
| --- | --- | --- | --- | --- |
| cold | 13.21 s (12.86–13.28) | 12.00 s | 10.64 s | 580 MiB |
| warm | 1.30 s (1.28–1.34) | — | — | 141 MiB |
| one operation changed | 4.12 s (4.04–4.17) | 3.07 s | 1.67 s | 333 MiB |
| shared fragment changed | 4.76 s (4.69–4.77) | 3.67 s | 2.32 s | 368 MiB |
| schema changed | 3.61 s (3.60–3.62) | 2.60 s | 1.26 s | 325 MiB |
| `--clean` | 13.34 s (12.81–13.46) | 12.33 s | 10.99 s | 656 MiB |

Cold phases: discovery 60 ms, hashing 31 ms, ownership scan 4 ms, schema
63 ms, parse 174 ms, validation 126 ms, IR 648 ms, emission 338 ms,
**formatting 10.64 s**, write 202 ms, verification 158 ms.

### magento (Magento 2.4 schema, 300 operations)

| Scenario | Wall time | Engine | Formatting | Peak RSS |
| --- | --- | --- | --- | --- |
| cold | 3.02 s (2.94–3.04) | 2.17 s | 1.89 s | 366 MiB |
| warm | 835 ms (833–837) | — | — | 135 MiB |
| one operation changed | 1.53 s (1.52–1.54) | 704 ms | 428 ms | 225 MiB |
| shared fragment changed | 1.33 s (1.32–1.34) | 504 ms | 236 ms | 225 MiB |
| schema changed | 1.26 s (1.20–1.27) | 413 ms | 140 ms | 225 MiB |
| `--clean` | 3.04 s (2.98–3.11) | 2.23 s | 1.95 s | 374 MiB |

Loading, parsing and validating the merged Magento schema takes about 57 ms.

## Results (AOT executable)

These were also measured with 4 formatting isolates.

| Fixture | Scenario | Wall time | Peak RSS |
| --- | --- | --- | --- |
| magento | cold | 1.30 s (1.24–1.33) | 253 MiB |
| magento | warm | 88 ms (88–89) | 30 MiB |
| magento | one operation changed | 332 ms (327–334) | 82 MiB |
| magento | shared fragment changed | 305 ms (301–307) | 78 MiB |
| magento | schema changed | 302 ms (299–308) | 78 MiB |
| large | cold | 13.67 s (13.40–13.88) | 2,538 MiB |
| large | warm | 490 ms (489–494) | 62 MiB |
| large | one operation changed | 2.79 s (2.79–2.84) | 168 MiB |
| large | shared fragment changed | 3.05 s (3.00–3.07) | 245 MiB |
| large | schema changed | 2.70 s (2.69–2.71) | 165 MiB |

AOT removes about 0.7 s of start-up and JIT warm-up from every run:

- On Magento, edits take about 0.3 s instead of 1.3–1.5 s.
- On the large fixture, edits are 1.4–1.5x faster.

The large cold run's 2.5 GiB peak with 4 isolates led to the new default
(next section).

## Formatting isolates

Cold runs of the large fixture with `-j`, run separately under the same
conditions:

| Isolates | JIT wall time | JIT peak RSS | AOT wall time | AOT peak RSS |
| --- | --- | --- | --- | --- |
| 1 | 19.7 s | 364 MiB | 16.5 s | 217 MiB |
| 2 (default) | 14.2 s | 435 MiB | 12.2 s | 285 MiB |
| 4 | 12.6 s | 505 MiB | 12.9–14.1 s | 2.7–2.9 GiB |

Isolates share one heap and the formatter allocates heavily, so garbage
collection limits scaling. With AOT, 4 isolates were no faster than 2 and
used ten times the memory. The default is therefore 2. `-j 4` is about 12%
faster under JIT on this fixture.

## Optimizations driven by these measurements

| Change | Before | After |
| --- | --- | --- |
| Parallel formatting (2 isolates), large cold, JIT | 19.7 s | 14.2 s |
| Generated `fromJson` via shared runtime decoders: code size, large fixture | 50.4 MiB | 45.6 MiB |
| Same change: single-isolate formatting, large, in-process | 22.0 s | 18.1 s |
| Explanation no longer hashes every output, one edit on large | 410 ms | 4 ms |
| Manifest reuses artifact digests, one edit on large | 500 ms | 3 ms |
| One-operation edit on large, end to end (AOT) | 3.6 s | 2.7 s |

What remains:

- **Formatting dominates.** It is 80–90% of every cold run.
- **IR building and emission run for all libraries.** On an edit this is
  about 1 s on the large fixture. Skipping unchanged libraries would need
  differential proof.
- **Rust is not justified by these numbers.** A native engine would not
  remove the cost of formatting, unless it also reimplemented `dart format`
  byte for byte. That is a large compatibility risk.

## build_runner

These are single runs with 4 formatting isolates. Every `build_runner build`
is a new process, so the builder's in-memory formatting memo starts empty.

| Fixture | First build (incl. compiling builders) | No-op build | Shared fragment changed |
| --- | --- | --- | --- |
| small | 13.43 s | 934 ms | 928 ms |
| medium | 17.01 s | 1.02 s | 3.37 s |
| magento | 15.07 s | 982 ms | 2.48 s |
| large | 30.10 s | 1.49 s | 15.16 s |

On the large fixture, a fragment change under `build_runner build` reformats
every library, because every step depends on every document and the process
has no memo. That takes 15 s, against 4.8 s for the CLI. `build_runner watch`
keeps the memo between builds. For very large projects, the CLI (ideally
AOT) is faster.

## Note on measurement conditions

A later attempt to re-run the full suite with the new default was discarded.
The machine was swapping heavily because of other applications (load
average up to 29, 7.6–8.5 GB of swap in use), and single runs took up to
15 minutes. A spot check after it stopped, a large cold run with the default
2 isolates, took 15.9 s and 438 MiB, consistent with the table above.
