// -*- mode: Bluespec; -*-
//
// Trace source for comparing the Quint tracker with the Rust tracker
// (Quint Connect). It wraps tracker.qnt.
//
// The Rust side is the driver in the Agave copy:
//   /opt/ag-model/agave/votor/src/consensus_pool/parent_ready_tracker/quint_connect.rs
// It asks Quint for random runs of an instance below, replays every step on
// Agave's ParentReadyTracker and compares the two states after each step.
//
// Run the comparison from /opt/ag-model/agave:
//   /opt/ag-model/t test -p agave-votor --features agave-unstable-api --lib quint_connect
// Look at a trace by hand, from /opt/ag-model:
//   ./q run --main=c_raw --init=initC --step=stepRaw --mbt --max-samples=1 \
//       --max-steps=20 --out-itf=one.itf.json spec/tracker_connect.qnt
module tracker_connect {
  import tracker.* from "./tracker"
  export tracker.*

  // What block_production_parent answers for every slot, taken before the
  // step. The leader's answer is a pure function in the model, so without
  // this variable it would not appear in a trace.
  var leaderBefore: Slot -> Choice

  def leaderNow: Slot -> Choice = SLOTS.mapBy(s => productionParent(tr, s))
  def freshLeader(seed: int): Slot -> Choice =
    SLOTS.mapBy(s => productionParent(newTracker(initialRoot(seed)), s))

  // The two picks choose nothing (each set has one element). They are there
  // so the trace tells the driver the root block and the last slot of the
  // instance: a trace records the values an action picks, and the driver sees
  // only the action name and its picks.
  action initSeeded(seed: int): bool = {
    nondet root = oneOf(Set(initialRoot(seed)))
    nondet last = oneOf(Set(H))
    all { initWith(seed), leaderBefore' = freshLeader(seed) }
  }
  // Fixed block ids.
  action initC = initSeeded(DEFAULT_ID_SEED)
  // Block ids that follow the run's seed.
  action initRandomIdsC = {
    nondet seed = oneOf(SEEDS)
    initSeeded(seed)
  }

  // The driver of tracker.qnt: a network under the assumptions, and a node
  // that receives what the network has.
  action stepC = all { step, leaderBefore' = leaderNow }

  // Any call sequence: no network and no assumptions. Any block is
  // handed to the tracker as certified, any slot as skipped, and the root
  // moves to any block one or two slots above it. This reaches what stepC
  // cannot: a fifth block in a slot (the panic), and a root without a
  // certificate.
  //
  // Quint picks one branch of `any` with equal chance, so a branch is
  // repeated to make it more likely: five certified blocks and four skips
  // for every root move. With equal chances the root reaches the last slot
  // within a few steps, and every later call is ignored.
  action rawCertified = {
    nondet b = oneOf(BLOCKS)
    nodeCertified(b)
  }
  action rawSkip = {
    nondet s = oneOf(FREE_SLOTS)
    nodeSkip(s)
  }
  action rawRoot = {
    nondet b = oneOf(BLOCKS)
    all { b.slot <= tr.root + 2, nodeRoot(b) }
  }
  action stepRaw = all {
    any {
      rawCertified, rawCertified, rawCertified, rawCertified, rawCertified,
      rawSkip, rawSkip, rawSkip, rawSkip,
      rawRoot,
    },
    leaderBefore' = leaderNow,
  }

  // Witness: the tracker has hit its fifth-block assert. Use it to see how
  // often an instance reaches the panic:
  //   ./q run --main=c_raw_small --init=initC --step=stepRaw --witnesses witPanicked \
  //       --max-samples=1000 --max-steps=60 spec/tracker_connect.qnt
  val witPanicked = tr.panicked
}

// Instances. The c_n*, c_b5, c_free and c_nofinal ones mirror the tr_*
// instances of tracker.qnt and are run with stepC. The two trackers must
// agree on c_nofinal too, where the chain properties fail.
module c_n100 { import tracker_connect(W = 4, N = 100, SPAN = 9, BLOCKS_PER_SLOT = 2, MAX_CERTIFIED = 4, ASSUME_FINAL = true, ASSUME_CHAIN = true).* }
module c_n101 { import tracker_connect(W = 4, N = 101, SPAN = 9, BLOCKS_PER_SLOT = 2, MAX_CERTIFIED = 4, ASSUME_FINAL = true, ASSUME_CHAIN = true).* }
module c_n102 { import tracker_connect(W = 4, N = 102, SPAN = 9, BLOCKS_PER_SLOT = 2, MAX_CERTIFIED = 4, ASSUME_FINAL = true, ASSUME_CHAIN = true).* }
module c_n103 { import tracker_connect(W = 4, N = 103, SPAN = 9, BLOCKS_PER_SLOT = 2, MAX_CERTIFIED = 4, ASSUME_FINAL = true, ASSUME_CHAIN = true).* }
module c_b5 { import tracker_connect(W = 4, N = 101, SPAN = 5, BLOCKS_PER_SLOT = 5, MAX_CERTIFIED = 4, ASSUME_FINAL = true, ASSUME_CHAIN = true).* }
module c_free { import tracker_connect(W = 4, N = 101, SPAN = 9, BLOCKS_PER_SLOT = 2, MAX_CERTIFIED = 4, ASSUME_FINAL = true, ASSUME_CHAIN = false).* }
module c_nofinal { import tracker_connect(W = 4, N = 101, SPAN = 9, BLOCKS_PER_SLOT = 2, MAX_CERTIFIED = 4, ASSUME_FINAL = false, ASSUME_CHAIN = true).* }
// For stepRaw: five blocks per slot so the limit of 4 can be exceeded. The
// two assumptions play no part in stepRaw.
module c_raw { import tracker_connect(W = 4, N = 101, SPAN = 9, BLOCKS_PER_SLOT = 5, MAX_CERTIFIED = 4, ASSUME_FINAL = false, ASSUME_CHAIN = false).* }
// The same with only three slots, so that five blocks of one slot arrive in
// most runs: this is the instance that exercises the panic.
module c_raw_small { import tracker_connect(W = 4, N = 101, SPAN = 3, BLOCKS_PER_SLOT = 5, MAX_CERTIFIED = 4, ASSUME_FINAL = false, ASSUME_CHAIN = false).* }
