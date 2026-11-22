// -*- mode: Bluespec; -*-
//
// The pragmatic driver: the model of tracker.qnt, moving only forward.
//
// `step` in tracker.qnt includes work on slots the node has already rooted
// past, and re-delivery of certificates it already holds. The tracker ignores
// both (the first lines of addCertified and addSkip), so those steps cost the
// exhaustive checker states without showing anything new. stepPragmatic
// leaves them out.
//
// Left out, compared with `step` in tracker.qnt:
//   - the network producing a certificate, a Skip certificate or a
//     finalization for a slot at or below the node's root;
//   - the node receiving a certificate for such a slot;
//   - the node receiving a certificate it already holds.
//
// What that means for a result:
//   - This is a subset of the runs of tracker.qnt. A violation found here is
//     a violation there too.
//   - "No violation" here covers only forward-moving runs. That the left-out
//     steps change nothing is checked by the full model (every reachable
//     state of tr_tiny, and simulation of the other instances) and by the
//     trace comparison on the Rust tracker, which keeps passed slots and
//     repeats.
//   - Use it with both assumptions on. Without ASSUME_FINAL, work at or below
//     the root can reach slots above it (a second certified block in the
//     root's slot, or a Skip certificate for it), and leaving it out would
//     hide the runs that instance exists to show.
//
// Run from /opt/ag-model:
//   ./q run --main=prag_n101 --step=stepPragmatic --invariant=ALL --max-samples=3000 --max-steps=60 spec/tracker_pragmatic.qnt
//   ./q verify --backend=tlc --main=prag_w4 --step=stepPragmatic --invariant=ALL spec/tracker_pragmatic.qnt   (about 2 minutes)
//   ./q verify --backend=tlc --main=prag_tiny --step=stepPragmatic --invariant=ALL spec/tracker_pragmatic.qnt (about 5 minutes)
module tracker_pragmatic {
  import tracker.* from "./tracker"
  export tracker.*

  action stepPragmatic = any {
    // the network: only above the node's root
    { nondet b = oneOf(BLOCKS)
      nondet p = oneOf(wCerts)
      all { b.slot > tr.root, certify(b, p) } },
    { nondet s = oneOf(FREE_SLOTS)
      all { s > tr.root, skipSlot(s) } },
    { nondet b = oneOf(wCerts)
      all { b.slot > tr.root, finalize(b) } },
    // the node: only something new, above its root
    { nondet b = oneOf(wCerts)
      all { b.slot > tr.root, not(certs.contains(b)), deliverCertified(b) } },
    { nondet s = oneOf(FREE_SLOTS)
      all { s > tr.root, not(skips.contains(s)), deliverSkip(s) } },
    // the root moves as in tracker.qnt
    { nondet b = oneOf(wFinal)
      advanceRoot(b) },
  }
}

// The instance tr_tiny of tracker.qnt, to compare the number of states.
module prag_tiny { import tracker_pragmatic(W = 2, N = 101, SPAN = 3, BLOCKS_PER_SLOT = 2, MAX_CERTIFIED = 4, ASSUME_FINAL = true, ASSUME_CHAIN = true).* }
// The simulation instance tr_n101 of tracker.qnt.
module prag_n101 { import tracker_pragmatic(W = 4, N = 101, SPAN = 9, BLOCKS_PER_SLOT = 2, MAX_CERTIFIED = 4, ASSUME_FINAL = true, ASSUME_CHAIN = true).* }
// One block per slot over a whole four-slot window and the start of the
// next one (slots 103 to 107 take certificates; 104 and 108 start windows).
module prag_w4 { import tracker_pragmatic(W = 4, N = 102, SPAN = 5, BLOCKS_PER_SLOT = 1, MAX_CERTIFIED = 4, ASSUME_FINAL = true, ASSUME_CHAIN = true).* }
