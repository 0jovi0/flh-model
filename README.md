# ag-model

A Quint model of Alpenglow's ParentReady (Agave v4.5.0-beta.0,
`votor/src/consensus_pool/parent_ready_tracker.rs`), and a harness that checks the Rust
tracker against it.

## Layout

| Path | What it is |
|---|---|
| `spec/parentready.qnt` | Constants, types, block ids, the definition of ParentReady |
| `spec/tracker.qnt` | The Rust tracker copied into Quint, a driver (network + one node), the properties, instances, replayed Rust unit tests |
| `spec/tracker_connect.qnt` | Trace source for the comparison with the Rust; wraps `tracker.qnt` |
| `agave/` | A copy of Agave at the pinned commit plus the test-only hooks. Not tracked here; rebuilt by `connect/setup.sh` |
| `connect/agave-hooks.patch` | Edits to Agave: the driver and three hooks |
| `connect/setup.sh` | Recreates `agave/` from the tag and the patch |
| `q`, `t` | Run `quint` and `cargo` under a CPU and memory cap |
| `tools/` | Node, JDK and Quint. Not tracked |

## Running

The wrappers cap a run at 4 cores (`Q_CPUS=<n>` to change) and 32 GB, at low priority.

Model, from `/opt/ag-model`:

```
./q typecheck spec/tracker.qnt
./q test --main=tr_tests spec/tracker.qnt
./q run --main=tr_n101 --invariant=ALL --max-samples=3000 --max-steps=60 spec/tracker.qnt
./q run --main=tr_free --invariant=NO_CHAIN --max-samples=3000 --max-steps=60 spec/tracker.qnt
./q verify --backend=tlc --main=tr_tiny --invariant=ALL spec/tracker.qnt
```

Comparison with the Rust, from `/opt/ag-model/agave`:

```
/opt/ag-model/t test -p agave-votor --features agave-unstable-api --lib quint_connect
```

The feature flag is required: without it the votor crate compiles empty. The first build
needs about 8 GB of disk.

## The model

- **Definition.** `ready(certs, skips, s, b)`: block `b` is certified, lies in an
  earlier slot than `s`, and every slot strictly between them has a Skip certificate.
- **Tracker copy.** `newTracker`, `addCertified`, `addSkip`, `setRoot`,
  `productionParent`, with the Rust line numbers in the comments.
- **Driver.** A network produces certificates, Skip certificates and finalizations;
  a node receives them in any order, with repeats, and moves its root.
- **Assumptions about the network:**
  `ASSUME_CHAIN` a block is certified only on a valid parent; `ASSUME_FINAL` a
  finalized slot has no Skip certificate and no second certified block; `ASSUME_Q5`
  at most 4 certified blocks per slot.
- **Properties.** Twelve, named `prop<number>_<name>` and indexed in a comment in
  `tracker.qnt`. Each is tagged by why it holds: `[tracker]` compares the copy with
  the definition, `[construction]` restates the model, `[assumption]` follows from
  the network assumptions. Check them with the bundles `ALL` or `NO_CHAIN`.
- **Instances.** `tr_n100`..`tr_n103` (root at each position in a window), `tr_b5`,
  `tr_w2`, `tr_free` (no chains), `tr_nofinal` (expected to fail `ALL`), `tr_tiny`
  (small enough for every state).

## The comparison with the Rust

The driver is `agave/votor/src/consensus_pool/parent_ready_tracker/quint_connect.rs`. It
is a child module of the tracker, so it reads the tracker's private fields. For each
test:

1. Quint runs one instance of `tracker_connect.qnt` and writes each random run as a
   trace: a list of states, each tagged with the action that produced it and the
   values that action picked.
2. For every state, the driver makes the matching call on the Rust tracker:
   `deliverCertified(b)` is `add_new_notar_fallback_or_stronger`, `deliverSkip(s)` is
   `add_new_skip`, `advanceRoot(b)` is `set_root`. Network actions (`certify`,
   `skipSlot`, `finalize`) make no call.
3. After every step, the model's state in the trace and the Rust tracker's state are
   reduced to the same shape and must be equal. A difference fails the test and prints
   the diff and the seed.

What is compared: per slot the certified blocks, ready parents and skip flag; the
root; the highest slot with a ready parent; every ParentReady event so far (the same
events per call, order inside a call ignored); what the leader of each slot would be
told; whether the fifth-block assert fired. At the start of every trace the driver
also checks that no two blocks share an id.

Two kinds of traces:

- **`stepC`**: the network and node of `tracker.qnt`, under the assumptions.
- **`stepRaw`**: any call sequence, with no network and no assumptions. This reaches the
  fifth-block panic and a root without a certificate.

Both take most picks from what is new above the root, because the tracker ignores passed
slots and repeats. A share of passed slots and repeats is kept: ignoring them is a rule
of the tracker too. Measured on 100 traces of 60 steps (plain: unweighted random picks):

| Steps that | `stepRaw` plain | `stepRaw` weighted | `stepC` plain | `stepC` weighted |
|---|---|---|---|---|
| change the tracker | 31% | 56% | 21% | 31% |
| hit a slot at or below the root | 44% | 20% | 15% | 14% |
| repeat something already delivered | 17% | 16% | 22% | 11% |
| move the root | 9% | 7% | 3% | 4% |
| are network only | - | - | 39% | 40% |

To watch both sides of a run:

```
AG_TRACE=1 /opt/ag-model/t test -p agave-votor --features agave-unstable-api \
  --lib quint_connect::one_short_trace -- --nocapture
```

This prints, per step, the call made on the Rust tracker, the events it returned,
and the two views (`model:` and `rust:`). Blocks are written `slot.id`. `AG_TRACE=2`
adds the tracker's own `Debug` output.

## Rebuilding the Agave copy

```
connect/setup.sh
```

clones tag `v4.5.0-beta.0` (commit `ef54b258`) from the builder's tree and applies
`connect/agave-hooks.patch`. After changing the driver, refresh the patch from `agave/`
with `git diff v4.5.0-beta.0 > ../connect/agave-hooks.patch`.
