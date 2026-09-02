# Cardano CBOR dataset

This project generates deterministic Conway- and Dijkstra-era CBOR corpora
from the Cardano Ledger Huddle/CDDL generator and checks them with the matching
typed ledger decoders.

The Docker image exposes the Haskell executable through a small entrypoint that
automatically produces code-coverage reports for verification commands.

## Quick start

From the repository root, create a writable `dataset` directory and build the
image:

```
docker build --platform=linux/amd64 -t cbor .
```

Generate one hundred Conway samples for every rule/category combination with seed 123:
```
docker run --rm --platform=linux/amd64 -v "$PWD/dataset:/output" cbor generate --era conway /output 123 100
```
The output will be in the host's `$PWD/dataset/conway-123-100`.

Generate one hundred Dijkstra samples for every rule/category combination with seed 123:
```
docker run --rm --platform=linux/amd64 -v "$PWD/dataset:/output" cbor generate --era dijkstra /output 123 100
```
The output will be in the host's `$PWD/dataset/dijkstra-123-100`.

## Verification

Deserialize only:

```
docker run --rm --platform=linux/amd64 -v "$PWD/dataset:/output" cbor verify --era conway deserialize /output/conway-123-100
```

Deserialize, reserialize, and require byte-for-byte equality with each input:

```
docker run --rm --platform=linux/amd64 -v "$PWD/dataset:/output" cbor verify --era conway reserialize /output/conway-123-100
```

Create a reference tree containing the ledger reserialization of every valid input:

```
docker run --rm --platform=linux/amd64 -v "$PWD/dataset:/output" cbor emit-expected --era dijkstra /output/dijkstra-123-100 /output/dijkstra-123-100.expected
```

Then compare each valid input's reserialization with that reference tree:

```
docker run --rm --platform=linux/amd64 -v "$PWD/dataset:/output" cbor verify --era dijkstra expected /output/dijkstra-123-100 /output/dijkstra-123-100.expected
```

`emit-expected` creates missing parent directories for its destination. The
destination itself must be absent. Dataset and expected-output directories
must not overlap. Reference generation uses a sibling staging tree and
publishes all successfully produced outputs together after processing. If any
input fails, the partial reference tree is preserved and the command exits with
failure.

The verification modes are:

- `deserialize`: check decoder acceptance or rejection only.
- `reserialize`: additionally require accepted values to encode exactly as the
  input bytes.
- `expected`: instead compare accepted values with the corresponding file
  below `EXPECTED_DIR`.

Files under `valid` must deserialize. Files under `zap-1`, `zap-2`, and
`zap-3` must be rejected. This expectation applies in every verification mode.

### Coverage reports

Every `verify` invocation writes to
`/output/coverage/<dataset-name>-<verification-mode>-<UTC-timestamp>`. For
example, deserializing `dijkstra-123-100` can write to
`/output/coverage/dijkstra-123-100-deserialize-20260901T113859Z`. The final
command output prints the exact directory.

Each run contains:

- `cbor.tix`: raw GHC HPC execution counts.
- `report.txt`: per-module expression, alternatives, and boolean conditions
  (guards, `if` conditions, and qualifiers).
- `report.xml`: the same coverage data in HPC's XML format.
- `html/hpc_index.html`: the main source-coverage report.
- `html/hpc_index_alt.html`: alternative coverage by module.
- `html/hpc_index_exp.html`: expression coverage by module.
- `html/hpc_index_fun.html`: declaration coverage by module.

Reports are generated even when verification finds failures, after which the
container returns the verifier's exit status. Set `CBOR_COVERAGE_DIR` to put
reports elsewhere; the selected directory must be writable and outside the
dataset being verified. Concurrent runs receive separate directories.

Every `verify` invocation also writes its error messages to `failures.log`
inside that invocation's coverage directory. The verifier statistics and the
failure-log path are printed to standard output; individual errors remain in
the log instead of overwhelming the console output.

## CLI discovery

```
docker run --rm cbor --help
docker run --rm cbor list-eras
docker run --rm cbor list-rules --era conway
```

The era registry is shared by generation, verification, help, and rule
listing, so adding an era or rule does not require synchronizing wrapper
scripts.

## Generation parameters

`generate --era ERA OUTPUT_DIR SEED COUNT` requires an existing writable output
directory, a non-negative decimal seed, and a count from 1 through 99999. For
each rule the generator emits `valid`, `zap-1`, `zap-2`, and `zap-3`. Each
category receives an attempt budget of three times its requested count. If the
budget cannot produce enough unique samples, the final summary reports the
shortfall.

Batch seeds and filenames are derived with SHA-256, so identical pinned inputs
produce the same corpus. The ledger revision and native crypto revisions are
pinned in the Dockerfile.

## Output layout

```
dataset/<era>-<seed>-<count>/
  <rule>/
    valid/00001-<sha256-prefix>.cbor
    zap-1/00001-<sha256-prefix>.cbor
    zap-2/00001-<sha256-prefix>.cbor
    zap-3/00001-<sha256-prefix>.cbor
```

Generated corpus directories contain only CBOR samples. A corpus may contain
any nonempty subset of the selected era's supported rules, which keeps focused
and older corpora verifiable; generation always emits every current rule.
Verification rejects unsupported rules, missing or unexpected categories,
symbolic links, non-CBOR entries, and empty corpora.
