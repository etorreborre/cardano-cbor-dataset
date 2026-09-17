# Cardano CBOR dataset

This project generates deterministic CBOR corpora for Conway and Dijkstra eras
from the Cardano Ledger Huddle/CDDL generator. This test data can be used by any Cardano node implementation
to check its conformance with respect to the decoding of on chain data.

The two intended users for this project are:

 1. Dataset maintainers

They are responsible for making sure that the latest generated data covers as much as possible of the CDDL specification
for Cardano data but also any edge cases that could see different node implementations diverge in their decoding of
the data.

 2. Dataset users

They are node implementors who want to generate conformance reports and attest that their node implementation decodes
all the test data correctly.

## Cardano CBOR dataset for maintainers

### Data generation

From the repository root, create a writable `dataset` directory and build the image:
```
docker build --platform=linux/amd64 -t cbor .
```

Generate one hundred Conway samples for every rule/category combination with seed `123`:
```
docker run --rm --platform=linux/amd64 -v "$PWD/dataset:/output" cbor generate --era conway /output 123 100
```
The output will be in the host's `$PWD/dataset/conway-123-100`.

Generate one hundred Dijkstra samples for every rule/category combination with seed `123`:
```
docker run --rm --platform=linux/amd64 -v "$PWD/dataset:/output" cbor generate --era dijkstra /output 123 100
```
The output will be in the host's `$PWD/dataset/dijkstra-123-100`:

 - Every file under `valid` must deserialize, and its normalized re-serialization must equal the `expected` file of the
   same name. There is one such file for every `valid` sample.
 - Every file under `invalid` must be rejected, whichever severity it sits at.

#### Generation parameters

`generate --era ERA OUTPUT_DIR SEED COUNT` requires:

 - An existing writable output directory.
 - A non-negative decimal seed.
 - A count from 1 through 99999.

For each rule the generator produces one batch of CDDL samples and one batch per mutation severity. Each batch receives
an attempt budget of three times its requested count. If the budget cannot produce enough unique samples, the final
summary reports the shortfall.

Every sample is then decoded, and where it lands follows from that. A CDDL sample the Haskell decoder accepts goes to
`valid`; one it rejects goes to `invalid/zap-0`, since satisfying the CDDL is not the same as being decodable. A
mutation goes to `invalid/zap-<n>` at its severity, unless the decoder accepts it, in which case it is dropped and
reported: a mutation that decodes tests nothing, because the corpus would be demanding a rejection that is correct not
to happen.

The generator then writes one `expected` file per `valid` sample, under the same name. The sample decoded with the
Haskell decoder, is re-encoded and normalized by the rules below (see the Normalization section). Every `valid` sample
has one, which is what makes `valid` mean valid.

For the rules whose bytes are hashed, listed further down, the `expected` file is the re-encoding **without**
normalization. There the container form is part of the format, so normalizing the reference would discard the very
thing it exists to pin down. Those `expected` files therefore hold the bytes an implementation must reproduce exactly,
and in practice equal the `valid` bytes.

Batch seeds and filenames are derived with SHA-256, so identical pinned inputs produce the same corpus.
The ledger revision and native crypto revisions are pinned in the Dockerfile.

####  Output layout

```
dataset/<era>-<seed>-<count>/
  <rule>/
    valid/00001-<sha256-prefix>.cbor
    expected/00001-<sha256-prefix>.cbor
    invalid/
      zap-0/00001-<sha256-prefix>.cbor
      zap-1/00001-<sha256-prefix>.cbor
      zap-2/00001-<sha256-prefix>.cbor
      zap-3/00001-<sha256-prefix>.cbor
```

Severity zero is the one that is not a mutation: it holds the generator's own samples, unaltered, that the decoder
rejects. The higher severities hold mutations of increasing aggressiveness. Each directory numbers its files from
`00001` independently.

A severity directory can be missing. The generator creates all four, but leaves one empty for a rule whose mutations
the decoder never rejects, and version control does not track an empty directory. Verification treats an absent
severity as zero samples and names it in the run summary rather than failing.

### Verification

The Haskell node serves as the reference implementation for decoding on-chain data. Any divergence with what the Haskell node
decode would trigger a fork in the network. This is why we need to verify that the Haskell node passes the generated test suite
with no exceptions.

`verify expected` checks that deserialized then reserialized data matches expected data in the `expected/***.cbor` files.
```
docker run --rm --platform=linux/amd64 -v "$PWD/dataset:/output" cbor verify expected --era dijkstra /output/dijkstra-123-100
```

If you just want to check the deserialization `verify deserialize` checks that decoders accept valid data and reject invalid data:
```
docker run --rm --platform=linux/amd64 -v "$PWD/dataset:/output" cbor verify deserialize --era conway /output/conway-123-100
```

### Normalization

The conformance test suite needs to make sure that the successfully decoded data is meaningful.
For example, a decoder that always succeeds and decodes nothing must be caught by the suite.
One way to catch those issues is to mutate the test input data in order to see such a decoder fail.
This is the purpose of the "zap" tests.

However, this does not guarantee that all the information that was present in the original bytes was properly decoded.
One way to check this is to re-encode the data and check if the re-encoded data matches the original one.

Unfortunately this doesn't work for several reasons:

  1. The CDDL accepts several encodings of the same data.
  2. The Haskell node can do additional data transformations before encoding that makes the comparison difficult.

In order to fix those difficulties, we require from each node implementation to:

 1. Normalize its encoded data using the specification below, excepted for the rules specified in the next section.
 2. Compare the normalized result to `<corpus>/<rule>/expected/<name>.cbor`, the reference for the sample of the same
    name under `<corpus>/<rule>/valid`.

### Rules whose bytes are hashed

For the rules below encoding part of the format, because the bytes are hashed, so there should be no normalization.
Indeed, a different encoding would yield a different hash:

```
auxiliary_data   native_script  transaction_witness_set
header           redeemers
plutus_data      transaction_body
```

Re-encoding one of these samples must reproduce the bytes of the `valid` file exactly. Their `expected` files are
written without normalization, so comparing your re-encoding to the `expected` file is already the exact comparison,
with no normalization step on either side. `verify expected` additionally checks the re-encoding against the `valid`
bytes themselves and reports a failure as `re-encoding differs from the original bytes`, which is what guarantees the
two files agree.

#### What belongs on that list

A rule belongs there only when the bytes of the item **that rule encodes** are themselves a hash preimage. Containing
something hashed is not enough, and this is where the list is easy to get wrong:

 - A `script` is a tag beside a payload. The payload is hashed and has its own rule; the tag around it does not.
 - A `datum_option` selects between a datum hash and an inline datum. The datum is hashed, the selector is not.
 - A `cost_models` value does reach a hash, but as the `language_views` embedding inside the script integrity hash,
   not as the protocol-parameter map this rule encodes.
 - A `block`, a `header_body` and a `transaction` each wrap memoized contents in a record that is rebuilt when encoded.
   The parts keep their bytes; the wrapper does not.

Adding a rule that does not belong makes the suite demand something no implementation can deliver: a sample whose
original encoding used an indefinite-length container can never be reproduced byte-for-byte by an encoder that writes
definite ones, and nothing about that is a conformance defect.

In the Haskell ledger the question has a mechanical answer, and it is the one used to settle this list. A type built on
`MemoBytes` keeps the bytes it decoded and re-emits them unchanged, because `encCBOR` for a `MemoBytes` is
`encodePreEncoded` over the stored bytes, which is exactly what hashing them requires. Every rule above decodes through
such a type; every rule named in this section does not. Note that `header` and `header_body` fall on opposite sides:
`BHeader` is memoized, `BHBody` is not.

The first three were also caught empirically, which is worth recording because it shows the failure mode: with them
listed, 177 of the 441 testable samples failed, every single failure had an indefinite-length construct in the
original, and for `script` and `datum_option` an indefinite outer container predicted failure with no exceptions in
either direction. The other three have no decodable samples in the current corpora, so only the source could settle
them.


## Cardano CBOR dataset for users

Users of this repository are expected to:

 1. Download the corpus for which they want to check the conformance.
 2. Implement their tests using the corpus as an input.
 3. Each test must check that:
    1.  every case under `valid` can be decoded.
    2.  every case under `invalid` is rejected, at every severity including `zap-0`.
    3.  re-encoded and normalized values match the bytes in the `expected` files.
    4.  for the rules whose bytes are hashed, listed above, re-encoded values match the `valid` bytes exactly.
 4. Output the results of the tests as a JSON file to a stable URL (for example as a Github artefact).

## CLI discovery

```
docker run --rm cbor --help
docker run --rm cbor list-eras
docker run --rm cbor list-rules --era conway
```

The era registry is shared by generation, verification, help, and rule
listing, so adding an era or rule does not require synchronizing wrapper
scripts.

#### Normalization specification

Here is the specification of what needs to be normalized in order to compare re-encoded data to the expected data.
Most of the normalizations rules below address the "shape" of the data, except for integers and rational values.

Apply recursively to every nested item in the CBOR output:

| from                                                   | to                                                         |
| ------------------------------------------------------ | ---------------------------------------------------------- |
| indefinite-length array                                | definite-length, same elements in the same order           |
| indefinite-length map                                  | definite-length, same entries in the same order            |
| chunked byte string                                    | one definite byte string, chunks concatenated              |
| chunked text string                                    | one definite text string, chunks concatenated              |
| non-minimal integer head                               | the minimal head encoding the same value                   |
| bignum (#6.2/#6.3) whose magnitude fits a native head  | the equivalent uint/nint                                   |
| bignum that does not fit                               | kept, leading zero bytes dropped from the magnitude        |
| rational                                               | a reduced rational with minimal numerator and denominator  |

A bignum tag carries the same value a `uint` or `nint` head can carry whenever the magnitude is below 2^64, so leaving
the choice open would let two encoders of the same number disagree. The fold runs in both directions of the boundary:
below it the tag goes away, at or above it the tag stays and only the magnitude is canonicalized. Implementations that
decode into a language-level integer and re-encode get this for free, as `2^64 - 1` and `2^64` land on either side on
their own.

An example of the normalization algorithm in Haskell can be found in this repository [here](app/Normalize.hs).

### Testing the normalization

`normalization-vectors/` holds 20 small hand-verified pairs, one `.in.cbor` and one `.out.cbor` per case. Your
normalizer is correct on this set when normalizing each `<n>.in.cbor` gives bytes identical to `<n>.out.cbor`. Eight of
the cases must come out unchanged, which is what keeps a content bug failing rather than passing quietly.

`normalization-vectors/README.md` lists every pair as reviewable hex and says what each case is for. That table is the
authority: the committed files were checked against it by hand rather than taken from an implementation.

To check the reference implementation against them, from anywhere in the repository:

```
scripts/check-normalization-vectors
```

It builds the image's `vector-check` stage, which runs the check as a test suite and prints one line per case. The
runtime image does not depend on that stage, so a stale vector fails this without blocking a build of the tool, and
this belongs in CI for the same reason. The check needs no ledger packages, so it finishes in seconds once the build
plan is cached.

### Report output format

The conformance report is expected to be a JSON file with the following top fields:

**Top level**

| Field              | Type                | Meaning                                               |
| ------------------ | ------------------- | ----------------------------------------------------- |
| `corpus`           | string              | The dataset that was run, e.g. `conway-123-100`       |
| `protocol_version` | string              | The protocol version decoded against, e.g. `11.0`     |
| `successful`       | bool                | `true` when the run had no failure at all             |
| `totals`           | Outcome             | The per-rule outcomes summed                          |
| `rules`            | map rule -> Outcome | One outcome per CDDL rule, keyed by rule name, sorted |
| `failures`         | array of failures   | One entry per failing sample                          |

**Outcome**

The shape used by `totals` and by every value of `rules`. Every field is a `number`:

| Field                                  | Meaning                                                                       |
| -------------------------------------- | ----------------------------------------------------------------------------- |
| `generated_total`                      | Number of samples generated from the CDDL for this rule, `valid` plus `invalid/zap-0` |
| `generated_decoded_reencoded_expected` | Of those, the ones under `valid`, which must decode, re-encode, and match the reference bytes |
| `generated_decoded_reencoded_actual`   | The ones that did                                                             |
| `generated_must_be_rejected_expected`  | The ones under `invalid/zap-0`, which must be rejected even though they satisfy the CDDL |
| `generated_must_be_rejected_actual`    | The ones that were actually rejected                                          |
| `zap_must_be_rejected_expected`        | Mutations, `invalid/zap-1` and above, which must be rejected                  |
| `zap_must_be_rejected_actual`          | The ones that were actually rejected                                          |

`generated_total` is the sum of the two `generated_*_expected` fields, so a report whose counts do not add up that way
is reporting something other than this layout.

**Failure**

Failures are optional. But if they are present, they should provide the following fields:

| Field    | Meaning                                                                                                    |
| -------- | ---------------------------------------------------------------------------------------------------------- |
| `sample` | `<rule>/<category>/<file stem>`, where `<category>` is `valid` or `invalid/zap-<n>` for severity `n`       |
| `rule`   | The CDDL rule the sample belongs to                                                                        |
| `class`  | `reason` collapsed into a stable label                                                                     |
| `reason` | The full error text, which may span several lines and embed hex dumps                                      |

For example:
```json
{
  "sample": "auxiliary_data/valid/00003-2f2bacfd41c291d4",
  "rule": "auxiliary_data",
  "class": "re-encoding differs from the cbor reference",
  "reason": "re-encoding differs from the cbor reference\n\nexpected\n\nd90103a400a11be2de…"
}
```



# Coverage reports

The Docker image exposes the Haskell executable through a small entrypoint that
automatically produces code-coverage reports for verification commands.

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
