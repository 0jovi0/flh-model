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
  // tracker_pragmatic.qnt is tracker.qnt plus the forward-only step.
  import tracker_pragmatic.* from "./tracker_pragmatic"
  export tracker_pragmatic.*

  // What block_production_parent answers for every slot, taken before the
  // step. The leader's answer is a pure function in the model, so without
  // this variable it would not appear in a trace.
  var leaderBefore: Slot -> Choice

  // The slots that may get a Skip certificate in this run; picked at the
  // start and then fixed. See "how skipped a run is" below.
  var maySkip: Set[Slot]

  def leaderNow: Slot -> Choice = SLOTS.mapBy(s => productionParent(tr, s))
  def freshLeader(seed: int): Slot -> Choice =
    SLOTS.mapBy(s => productionParent(newTracker(initialRoot(seed)), s))

  // The four picks choose nothing (each set has one element). They are
  // there so the trace tells the driver about the instance: a trace records
  // the values an action picks, and the driver sees only the action name and
  // its picks.
  //   root   - the root block the run starts from
  //   last   - the last slot of the instance
  //   blocks - every block of the instance, the root included
  //   count  - how many blocks that must be. The driver checks that there
  //            are that many, each with its own id: two blocks with one id
  //            would be one element of `blocks`.
  action initSeeded(seed: int): bool = {
    nondet root = oneOf(Set(initialRoot(seed)))
    nondet last = oneOf(Set(H))
    nondet blocks = oneOf(Set(allBlocks(seed).union(Set(initialRoot(seed)))))
    nondet count = oneOf(Set(SPAN * BLOCKS_PER_SLOT + 1))
    // how skipped this run is: see below
    nondet appetite = oneOf(Set(0, 1, 2, 3))
    nondet some = oneOf(powerset(FREE_SLOTS))
    nondet more = oneOf(powerset(FREE_SLOTS))
    all {
      initWith(seed),
      leaderBefore' = freshLeader(seed),
      maySkip' = restOfWindow(
        if (appetite == 0) Set()
        else if (appetite == 1) some.intersect(more)
        else if (appetite == 2) some
        else FREE_SLOTS),
    }
  }

  // ---- how skipped a run is ----
  //
  // With plain random picks nearly every run ends with every slot skipped: a
  // Skip certificate takes one step and cannot be undone, while finalizing a
  // slot takes several. A network skips a slot only when its leader fails, so
  // each run draws the slots that may be skipped:
  //   appetite 0 - none: every slot must be decided by a certified block
  //   appetite 1 - about a quarter of the slots
  //   appetite 2 - about half of the slots
  //   appetite 3 - all slots, the adversarial runs
  // A slot that may be skipped makes the rest of its window skippable too,
  // because a block needs a certified block in the slot before it: after a
  // skipped slot the remaining slots of that window can only be skipped.
  pure def restOfWindow(xs: Set[Slot]): Set[Slot] =
    FREE_SLOTS.filter(s => xs.exists(x => windowStart(x) == windowStart(s) and x <= s))
  // Fixed block ids.
  action initC = initSeeded(DEFAULT_ID_SEED)
  // Block ids that follow the run's seed.
  action initRandomIdsC = {
    nondet seed = oneOf(SEEDS)
    initSeeded(seed)
  }

  // ---- which steps a trace is made of ----
  //
  // A call for a slot at or below the root is ignored by the tracker, and so
  // is a certificate it already holds. With plain random picks such calls
  // are most of a trace, so both steps below take most of their picks from
  // what is new above the root. They keep a share of passed slots and
  // repeats: "ignore it" is a rule of the tracker too, and those are the
  // calls that test it.
  //
  // Quint picks one branch of `any` with equal chance, so a branch is
  // written several times to make it more likely. The blocks inside `any`
  // are left unnamed so that a trace records the name of the action they
  // call (certify, deliverCertified, nodeCertified, ...), which is what the
  // driver matches on.

  // What would be new, above the node's root. A pick from an empty set
  // switches its branch off for that step.
  def newToNetwork: Set[Block] = BLOCKS.filter(b => b.slot > tr.root and not(wCerts.contains(b)))
  def newSkipsForNetwork: Set[Slot] = maySkip.filter(s =>
    s > tr.root and not(wSkips.contains(s)) and (ASSUME_WINDOW implies windowOpen(s)))
  def notYetFinal: Set[Block] = wCerts.filter(b => b.slot > tr.root and not(wFinal.contains(b)))
  def undelivered: Set[Block] = wCerts.filter(b => b.slot > tr.root and not(certs.contains(b)))
  def undeliveredSkips: Set[Slot] = wSkips.filter(s => s > tr.root and not(skips.contains(s)))
  def newToNode: Set[Block] = BLOCKS.filter(b => b.slot > tr.root and not(certs.contains(b)))
  def newSkipsForNode: Set[Slot] = maySkip.filter(s => s > tr.root and not(skips.contains(s)))

  // The driver of tracker.qnt: a network under the assumptions, and a node
  // that receives what the network has.
  action stepC = all {
    any {
      // the network produces something above the node's root
      { nondet b = oneOf(newToNetwork)
        nondet p = oneOf(wCerts)
        certify(b, p) },
      { nondet b = oneOf(newToNetwork)
        nondet p = oneOf(wCerts)
        certify(b, p) },
      { nondet s = oneOf(newSkipsForNetwork)
        skipSlot(s) },
      { nondet b = oneOf(notYetFinal)
        finalize(b) },
      // the node receives something new above its root
      { nondet b = oneOf(undelivered)
        deliverCertified(b) },
      { nondet b = oneOf(undelivered)
        deliverCertified(b) },
      { nondet b = oneOf(undelivered)
        deliverCertified(b) },
      { nondet s = oneOf(undeliveredSkips)
        deliverSkip(s) },
      { nondet s = oneOf(undeliveredSkips)
        deliverSkip(s) },
      { nondet b = oneOf(wFinal)
        advanceRoot(b) },
      // passed slots and repeats: a block certified anywhere, and anything
      // the network has delivered again
      { nondet b = oneOf(BLOCKS)
        nondet p = oneOf(wCerts)
        certify(b, p) },
      { nondet b = oneOf(wCerts)
        deliverCertified(b) },
      { nondet s = oneOf(wSkips)
        deliverSkip(s) },
    },
    leaderBefore' = leaderNow,
    maySkip' = maySkip,
  }

  // The forward-only step of tracker_pragmatic.qnt: nothing for a slot at or
  // below the node's root, and no certificate delivered twice.
  action stepForward = all {
    stepPragmaticWith(maySkip),
    leaderBefore' = leaderNow,
    maySkip' = maySkip,
  }

  // Any call sequence: no network and no assumptions. Any block is
  // handed to the tracker as certified, any slot as skipped, and the root
  // moves to any block one or two slots above it. This reaches what stepC
  // cannot: a fifth block in a slot (the panic), and a root without a
  // certificate.
  action stepRaw = all {
    any {
      // something new above the root
      { nondet b = oneOf(newToNode)
        nodeCertified(b) },
      { nondet b = oneOf(newToNode)
        nodeCertified(b) },
      { nondet b = oneOf(newToNode)
        nodeCertified(b) },
      { nondet b = oneOf(newToNode)
        nodeCertified(b) },
      { nondet s = oneOf(newSkipsForNode)
        nodeSkip(s) },
      { nondet s = oneOf(newSkipsForNode)
        nodeSkip(s) },
      { nondet s = oneOf(newSkipsForNode)
        nodeSkip(s) },
      // any block and any slot, passed ones and repeats included
      { nondet b = oneOf(BLOCKS)
        nodeCertified(b) },
      { nondet s = oneOf(FREE_SLOTS)
        nodeSkip(s) },
      // the root moves up by one or two slots, but only once the node has
      // received six certificates for every slot the root has already
      // climbed. A root that climbs freely reaches the last slot long before
      // the trace ends, and from then on every call is on a passed slot.
      { nondet b = oneOf(BLOCKS.filter(b => b.slot > tr.root and b.slot <= tr.root + 2))
        all { certs.size() + skips.size() >= 6 * (tr.root - N + 1), nodeRoot(b) } },
    },
    leaderBefore' = leaderNow,
    maySkip' = maySkip,
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
module c_n100 { import tracker_connect(W = 4, N = 100, SPAN = 9, BLOCKS_PER_SLOT = 2, MAX_CERTIFIED = 4, ASSUME_FINAL = true, ASSUME_CHAIN = true, ASSUME_WINDOW = true).* }
module c_n101 { import tracker_connect(W = 4, N = 101, SPAN = 9, BLOCKS_PER_SLOT = 2, MAX_CERTIFIED = 4, ASSUME_FINAL = true, ASSUME_CHAIN = true, ASSUME_WINDOW = true).* }
module c_n102 { import tracker_connect(W = 4, N = 102, SPAN = 9, BLOCKS_PER_SLOT = 2, MAX_CERTIFIED = 4, ASSUME_FINAL = true, ASSUME_CHAIN = true, ASSUME_WINDOW = true).* }
module c_n103 { import tracker_connect(W = 4, N = 103, SPAN = 9, BLOCKS_PER_SLOT = 2, MAX_CERTIFIED = 4, ASSUME_FINAL = true, ASSUME_CHAIN = true, ASSUME_WINDOW = true).* }
module c_b5 { import tracker_connect(W = 4, N = 101, SPAN = 5, BLOCKS_PER_SLOT = 5, MAX_CERTIFIED = 4, ASSUME_FINAL = true, ASSUME_CHAIN = true, ASSUME_WINDOW = true).* }
module c_free { import tracker_connect(W = 4, N = 101, SPAN = 9, BLOCKS_PER_SLOT = 2, MAX_CERTIFIED = 4, ASSUME_FINAL = true, ASSUME_CHAIN = false, ASSUME_WINDOW = false).* }
module c_nofinal { import tracker_connect(W = 4, N = 101, SPAN = 9, BLOCKS_PER_SLOT = 2, MAX_CERTIFIED = 4, ASSUME_FINAL = false, ASSUME_CHAIN = true, ASSUME_WINDOW = true).* }
// For stepRaw. The assumptions play no part in it.
// c_raw: four blocks per slot, so slots fill up to the limit but the tracker
// never panics and every step of a trace counts.
module c_raw { import tracker_connect(W = 4, N = 101, SPAN = 9, BLOCKS_PER_SLOT = 4, MAX_CERTIFIED = 4, ASSUME_FINAL = false, ASSUME_CHAIN = false, ASSUME_WINDOW = false).* }
// c_raw_small: five blocks per slot on three slots, so a fifth block of one
// slot arrives within 20 steps in most runs. This is the instance that
// exercises the panic. After a panic the rest of a trace only checks that
// nothing moves, so it is run with short traces.
module c_raw_small { import tracker_connect(W = 4, N = 101, SPAN = 3, BLOCKS_PER_SLOT = 5, MAX_CERTIFIED = 4, ASSUME_FINAL = false, ASSUME_CHAIN = false, ASSUME_WINDOW = false).* }
