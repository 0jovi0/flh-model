# flh-model

A Quint model of ParentReady from Alpenglow's fast leader handover, and a
quint-connect driver that checks Agave's `ParentReadyTracker` against it.

## Setup

From the root of a clone, on Linux x64:

```
./install-tools.sh     # Node, a JDK and Quint into tools/
connect/setup.sh       # the pinned Agave into agave/, with the driver patch applied
```

Agave is pinned to tag `v5.0.0-alpha.1`, commit
`22d4b3a8d9bfd7b4dcda330ea17c777c09fc7209`. `connect/setup.sh` clones it from
`anza-xyz/agave` and stops if the commit differs.

After both steps the clone looks like this:

```
flh-model/
  spec/        the model
  connect/     agave-hooks.patch, setup.sh, mutants/, check-mutants.sh
  tools/       Node, JDK, Quint             (created by install-tools.sh)
  agave/       Agave at the pinned commit   (created by connect/setup.sh)
  q, t         run quint and cargo with the toolchain from tools/
```

`agave/` has to sit there: the driver looks for the model at `../../spec` from
`agave/votor`. The model needs only the first step. The driver needs both, plus rustup
(Agave selects its own Rust version) and Agave's build dependencies. `q` and `t` cap a
run at 4 cores; `Q_CPUS=<n>` changes that.

## The model

ParentReady decides which blocks a leader may build on at the start of its window.

- `spec/parentready.qnt` is the definition: block `b` is a ready parent for slot `s`
  when `b` is certified, lies in an earlier slot, and every slot strictly between
  them has a Skip certificate.
- `spec/tracker.qnt` is the Rust tracker
  (`votor/src/consensus_pool/parent_ready_tracker.rs`) copied into Quint, with the
  Rust line numbers in the comments. Around it sits a network that produces block
  certificates, Skip certificates and finalizations, and a node that receives them
  in any order, with repeats, and moves its root.
- Thirteen properties (`prop1_...` to `prop13_...`). Those tagged `[tracker]` state
  that the copy agrees with the definition whatever the order of arrival. The network
  obeys four assumptions (`ASSUME_CHAIN`, `ASSUME_FINAL`, `ASSUME_WINDOW`, `ASSUME_Q5`),
  described at the top of `spec/tracker.qnt`.
- `spec/tracker_pragmatic.qnt` runs the same model moving only forward: nothing for
  slots the node has passed, no repeated deliveries.

From the root of the clone:

```
./q test --main=tr_tests spec/tracker.qnt       # the tracker's Rust unit tests, replayed
./q run --main=tr_n101 --invariant=ALL --max-samples=3000 --max-steps=60 spec/tracker.qnt
./q verify --backend=tlc --main=tr_tiny --invariant=ALL spec/tracker.qnt   # every state of a small instance
```

## The driver

`connect/agave-hooks.patch` adds one test module to Agave:
`votor/src/consensus_pool/parent_ready_tracker/quint_connect.rs`. Each test:

1. Quint simulates the model (`spec/tracker_connect.qnt`) and writes every random run
   as a trace: a list of states, each tagged with the action that produced it and the
   values that action picked.
2. For every state, `TrackerDriver::step` makes the matching call on the Rust tracker:
   `deliverCertified(b)` is `add_new_notar_fallback_or_stronger`, `deliverSkip(s)` is
   `add_new_skip`, `advanceRoot(b)` is `set_root`. Actions of the network make no call.
3. After every step one `View` is built twice, from the model's state in the trace
   (`from_spec`) and from the Rust tracker (`from_driver`), and the two must be equal. A
   difference fails the test and prints a `QUINT_SEED` that replays it.

A `View` holds, per slot, the certified blocks, the ready parents and the skip flag;
the root; the highest slot with a ready parent; every ParentReady event; and what the
leader of each slot would be told.

From `agave/`:

```
../t test -p agave-votor --features agave-unstable-api --lib quint_connect
```

## Watching both sides

From `agave/`:

```
AG_TRACE=1 ../t test -p agave-votor --features agave-unstable-api \
  --lib quint_connect::one_short_trace -- --nocapture
```

For every step this prints the model's action, the call made on the Rust tracker with
the events it returned, and the two views that are compared: `model:` from the trace
and `rust:` from the tracker. Blocks are written `slot.id`. One step of the output:

```
[trace 1 step 1] model action: nodeCertified
  call:  add_new_notar_fallback_or_stronger(103.7481)
         events returned, in the tracker's order: [104 <- 103.7481]
  model: root=101 highest=104
      slot 101: skip=false certified=[101.24652] parents=[]
      slot 102: skip=false certified=[] parents=[101.24652]
      slot 103: skip=false certified=[103.7481] parents=[]
      slot 104: skip=false certified=[] parents=[103.7481]
      events (sorted): [104 <- 103.7481]
      leader before the step: [101: MissedWindow, 102: Parent(101.24652), 103: ParentNotReady, 104: ParentNotReady, 105: ParentNotReady]
  rust:  root=101 highest=104
      slot 101: skip=false certified=[101.24652] parents=[]
      slot 102: skip=false certified=[] parents=[101.24652]
      slot 103: skip=false certified=[103.7481] parents=[]
      slot 104: skip=false certified=[] parents=[103.7481]
      events (sorted): [104 <- 103.7481]
      leader before the step: [101: MissedWindow, 102: Parent(101.24652), 103: ParentNotReady, 104: ParentNotReady, 105: ParentNotReady]
```

`AG_TRACE=2` adds the tracker's own `Debug` output.

## Mutants

`connect/mutants/` holds three patches. Each changes Agave's tracker so that it no
longer matches the model: one stops carrying a skipped slot's ready parents forward,
one accepts a Skip certificate for the root slot, one drops the root's own entry in
`set_root`.

```
connect/check-mutants.sh
```

applies them one at a time, runs the comparison tests and reverses the patch. A mutant
is detected when the tests fail with a state mismatch; the script exits 0 when all
three are. To see the mismatch for one mutant, from `agave/`:

```
git apply ../connect/mutants/set-root-drops-root-entry.patch
QUINT_VERBOSE=1 ../t test -p agave-votor --features agave-unstable-api \
  --lib quint_connect::chain_root_101
git apply -R ../connect/mutants/set-root-drops-root-entry.patch
```

The comparison tests can run nightly as a regression test for the tracker, and
`check-mutants.sh` as a check that they still fail when the tracker is wrong.

## Changing the driver

Edit it in `agave/`, then refresh the patch from inside `agave/`:

```
git add -A && git diff --cached v5.0.0-alpha.1 > ../connect/agave-hooks.patch
```
