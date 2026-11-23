// -*- mode: Bluespec; -*-
//
// The Rust ParentReady tracker copied into Quint, a driver that feeds it
// certificates and root moves in any order, and the checks that it agrees
// with the definition in parentready.qnt.
//
// Source: Agave v5.0.0-alpha.1, votor/src/consensus_pool/parent_ready_tracker.rs
//
// Run from the repo root (add --seed=<n> to reproduce a run; add
// --init=initRandomIds to a `run` to also vary the block ids with the seed):
//   ./q typecheck spec/tracker.qnt
//   ./q test --main=tr_tests spec/tracker.qnt          (replayed Rust unit tests)
//   ./q test --main=tr_tests_root spec/tracker.qnt
//   ./q run --main=tr_n101 --invariant=ALL --max-samples=30000 --max-steps=60 spec/tracker.qnt
//   ./q run --main=tr_free --invariant=NO_CHAIN --max-samples=30000 --max-steps=60 spec/tracker.qnt
//   ./q run --main=tr_n101 --witnesses witRun6 witTwoSlots --max-samples=3000 --max-steps=60 spec/tracker.qnt
//   ./q verify --backend=tlc --main=tr_tiny --invariant=ALL spec/tracker.qnt   (every state; minutes)
module tracker {
  import parentready.* from "./parentready"
  export parentready.*

  // Assumptions about what the network can produce. Each is a fact about
  // votes and quorums that this model takes as given; switch one off to see
  // which properties depend on it.
  //
  // ASSUME_FINAL: a finalized block's slot never has a Skip certificate and
  //   never a second certified block.
  // ASSUME_CHAIN: a block is certified only on a valid parent. In the first
  //   slot of a window the parent must be a ready parent for that slot; in
  //   any other slot the parent must be a certified block of the slot before.
  // ASSUME_WINDOW: a slot gets a Skip certificate only once its window is
  //   open: the first slot of that window has a ready parent, or it is the
  //   window the initial root sits in. In the code a node arms its skip timers
  //   for a window when it sees a ParentReady for the window's first slot
  //   (event_handler.rs:258, the only call of set_timeouts), and one timer
  //   covers the rest of that window (timer_manager/timers.rs:89). Without a
  //   timer a node votes skip only in reaction to other votes for that slot,
  //   so a quorum of skip votes needs honest nodes whose window is open.
  // ASSUME_Q5 (always on): a slot never has more than MAX_CERTIFIED certified
  //   blocks.
  const ASSUME_FINAL: bool
  const ASSUME_CHAIN: bool
  const ASSUME_WINDOW: bool

  // ------------------------------------------------------------------
  // The tracker, transcribed
  // ------------------------------------------------------------------

  pure val emptyStatus: Status = { skip: false, certified: Set(), parents: Set() }
  pure def maxInt(a: int, b: int): int = if (a > b) a else b

  // ParentReadyTracker::new(root = N, (N + 1, root))   lines 66-109
  // The root block is certified, and is a ready parent for N + 1.
  pure def newTracker(root: Block): Tracker = {
    st: SLOTS.mapBy(s =>
      if (s == N) { ...emptyStatus, certified: Set(root) }
      else if (s == N + 1) { ...emptyStatus, parents: Set(root) }
      else emptyStatus),
    root: N,
    highest: N + 1,
    events: [],
    panicked: false,
  }

  // First slot >= from without a skip certificate: where both loops stop.
  pure def stopSlot(st: Slot -> Status, from: Slot): Slot =
    SLOTS.filter(s => s >= from and not(st.get(s).skip))
      .fold(H, (acc, s) => if (s < acc) s else acc)

  // add_new_notar_fallback_or_stronger   lines 114-170
  pure def addCertified(t: Tracker, b: Block): Tracker =
    if (t.panicked) t
    else if (b.slot <= t.root) t                           // line 119
    else if (t.st.get(b.slot).certified.contains(b)) t     // line 135
    // line 143: one block more than MAX_CERTIFIED in a slot is a panic
    else if (t.st.get(b.slot).certified.size() >= MAX_CERTIFIED) { ...t, panicked: true }
    else {
      pure val st1 = t.st.setBy(b.slot, x => { ...x, certified: x.certified.union(Set(b)) })
      // lines 146-169: walk forward from slot(b) + 1, stop after the first
      // slot that has no skip certificate
      pure val stop = stopSlot(st1, b.slot + 1)
      pure val reach = SLOTS.filter(s => b.slot < s and s <= stop)
      pure val fresh = reach.filter(s => not(st1.get(s).parents.contains(b)))
      { ...t,
        st: SLOTS.mapBy(s =>
          if (reach.contains(s)) { ...st1.get(s), parents: st1.get(s).parents.union(Set(b)) }
          else st1.get(s)),
        // line 163: highest moves only where b was a new parent
        highest: fresh.fold(t.highest, (a, s) => maxInt(a, s)),
        // line 156: an event only where b was new and the slot starts a window
        events: SLOT_LIST
          .select(s => fresh.contains(s) and first(s))
          .foldl(t.events, (ev, s) => ev.append({ slot: s, parent: b })),
      }
    }

  // add_new_skip   lines 173-237
  pure def addSkip(t: Tracker, slot: Slot): Tracker =
    if (t.panicked) t
    else if (slot <= t.root) t                             // line 174
    else {
      pure val st1 = t.st.setBy(slot, x => { ...x, skip: true })
      // lines 183-189: the slots after `slot`, up to and including the first
      // one without a skip certificate
      pure val stop = stopSlot(st1, slot + 1)
      pure val future = SLOTS.filter(s => slot < s and s <= stop)
      // lines 192-207: candidates come from the slot before the skipped one
      pure val prev = st1.get(slot - 1)
      pure val potential = prev.certified.union(if (prev.skip) prev.parents else Set())
      if (potential.size() == 0) { ...t, st: st1 }         // line 209
      else { ...t,
        st: SLOTS.mapBy(s =>
          if (future.contains(s)) { ...st1.get(s), parents: st1.get(s).parents.union(potential) }
          else st1.get(s)),
        // line 235: highest moves for every future slot, new parent or not
        highest: maxInt(t.highest, stop),
        // lines 220-232: an event per new parent on each window start. The
        // events of one call come out in slot order, but for one slot their
        // order is not the code's; no property here depends on it.
        events: SLOT_LIST
          .select(s => future.contains(s) and first(s))
          .foldl(t.events, (ev, s) =>
            potential
              .filter(b => not(st1.get(s).parents.contains(b)))
              .fold(ev, (e, b) => e.append({ slot: s, parent: b }))),
      }
    }

  // set_root   lines 297-300. Entries below the new root are dropped. The
  // lists inside the entries that survive are not touched, and `highest`
  // is not touched. Only called with a larger root (consensus_pool.rs:545).
  pure def setRoot(t: Tracker, r: Slot): Tracker =
    if (t.panicked) t
    else { ...t, root: r, st: SLOTS.mapBy(s => if (s < r) emptyStatus else t.st.get(s)) }

  // block_production_parent   lines 263-282
  pure def productionParent(t: Tracker, slot: Slot): Choice =
    if (t.highest > slot) MissedWindow
    else if (t.st.get(slot).parents.size() == 0) ParentNotReady
    else Parent(minOf(t.st.get(slot).parents))

  // ------------------------------------------------------------------
  // The driver. A network that produces certificates, and one node that
  // receives them in any order (repeats allowed) and moves its root.
  // ------------------------------------------------------------------

  var idSeed: int                 // seed of the block ids, set at the start

  // the network: everything that exists, whether or not the node has it
  var wCerts: Set[Block]          // certified blocks
  var wSkips: Set[Slot]           // slots with a Skip certificate
  var wFinal: Set[Block]          // finalized blocks
  var parentOf: Block -> Block    // the parent each certified block was built on
  var ancOf: Block -> Set[Block]  // each certified block with all its ancestors

  // the node
  var certs: Set[Block]           // block certificates delivered so far
  var skips: Set[Slot]            // skip certificates delivered so far
  var rootBlock: Block            // the block the node's root sits on
  var tr: Tracker
  var prevParents: Slot -> Set[Block]   // ready sets one step ago (only for prop2_readySetOnlyGrows)

  def ROOT0: Block = initialRoot(idSeed)
  def BLOCKS: Set[Block] = allBlocks(idSeed)
  def blockOf(s: Slot, k: int): Block = blockAt(idSeed, s, k)
  def parentsNow: Slot -> Set[Block] = SLOTS.mapBy(s => tr.st.get(s).parents)

  action initWith(seed: int): bool = {
    val root = initialRoot(seed)
    all {
      idSeed' = seed,
      wCerts' = Set(root),
      wSkips' = Set(),
      wFinal' = Set(root),
      parentOf' = Map(root -> root),
      ancOf' = Map(root -> Set(root)),
      certs' = Set(root),
      skips' = Set(),
      rootBlock' = root,
      tr' = newTracker(root),
      prevParents' = SLOTS.mapBy(s => Set()),
    }
  }

  // Default start: fixed block ids.
  action init = initWith(DEFAULT_ID_SEED)

  // Start with block ids that follow the simulator's --seed.
  action initRandomIds = {
    nondet seed = oneOf(SEEDS)
    initWith(seed)
  }

  action networkSame = all {
    idSeed' = idSeed, wCerts' = wCerts, wSkips' = wSkips, wFinal' = wFinal,
    parentOf' = parentOf, ancOf' = ancOf,
  }
  action nodeSame = all {
    certs' = certs, skips' = skips, rootBlock' = rootBlock, tr' = tr, prevParents' = parentsNow,
  }

  // ---- the network ----

  // Block b, built on parent p, gets a certificate.
  action certify(b: Block, p: Block): bool = all {
    not(wCerts.contains(b)),
    // The parent is certified first. For a block that does not start a
    // window this is stricter than the code: a Notarize vote only needs the
    // voter to have notarized the parent (event_handler.rs:790-800), so a
    // child's certificate can exist before its parent's. The node can still
    // receive the two in either order.
    wCerts.contains(p),
    p.slot < b.slot,
    // ASSUME_Q5: never more than MAX_CERTIFIED certified blocks in a slot.
    // The tracker panics on one more (line 143); see prop10_noPanic.
    wCerts.filter(c => c.slot == b.slot).size() < MAX_CERTIFIED,
    // ASSUME_FINAL: no second certified block in a finalized slot
    ASSUME_FINAL implies not(wFinal.exists(f => f.slot == b.slot)),
    // ASSUME_CHAIN: only on a valid parent
    ASSUME_CHAIN implies
      (if (first(b.slot)) ready(wCerts, wSkips, b.slot, p) else p.slot == b.slot - 1),
    wCerts' = wCerts.union(Set(b)),
    parentOf' = parentOf.put(b, p),
    ancOf' = ancOf.put(b, ancOf.get(p).union(Set(b))),
    idSeed' = idSeed, wSkips' = wSkips, wFinal' = wFinal,
    nodeSame,
  }

  // The window of slot s is open: nodes can have skip timers running for it.
  // Once open, a window stays open (certificates are never taken back).
  def windowOpen(s: Slot): bool =
    windowStart(s) <= N or readySet(wCerts, wSkips, windowStart(s)).size() > 0

  // Slot s gets a Skip certificate.
  action skipSlot(s: Slot): bool = all {
    not(wSkips.contains(s)),
    // ASSUME_FINAL: no Skip certificate for a finalized slot
    ASSUME_FINAL implies not(wFinal.exists(f => f.slot == s)),
    // ASSUME_WINDOW: only in a window that is open
    ASSUME_WINDOW implies windowOpen(s),
    wSkips' = wSkips.union(Set(s)),
    idSeed' = idSeed, wCerts' = wCerts, wFinal' = wFinal, parentOf' = parentOf, ancOf' = ancOf,
    nodeSame,
  }

  // Certified block b gets finalized. Finalizations may happen in any slot order.
  action finalize(b: Block): bool = all {
    wCerts.contains(b),
    not(wFinal.contains(b)),
    ASSUME_FINAL implies and {
      not(wSkips.contains(b.slot)),
      wCerts.forall(c => c.slot == b.slot implies c == b),
    },
    wFinal' = wFinal.union(Set(b)),
    idSeed' = idSeed, wCerts' = wCerts, wSkips' = wSkips, parentOf' = parentOf, ancOf' = ancOf,
    nodeSame,
  }

  // ---- the node ----
  // The three calls into the tracker, with no condition on what is passed.
  // The replayed Rust unit tests use these directly.

  action nodeCertified(b: Block): bool = all {
    certs' = certs.union(Set(b)),
    skips' = skips,
    rootBlock' = rootBlock,
    tr' = addCertified(tr, b),
    prevParents' = parentsNow,
    networkSame,
  }

  action nodeSkip(s: Slot): bool = all {
    certs' = certs,
    skips' = skips.union(Set(s)),
    rootBlock' = rootBlock,
    tr' = addSkip(tr, s),
    prevParents' = parentsNow,
    networkSame,
  }

  action nodeRoot(b: Block): bool = all {
    b.slot > tr.root,
    certs' = certs,
    skips' = skips,
    rootBlock' = b,
    tr' = setRoot(tr, b.slot),
    prevParents' = parentsNow,
    networkSame,
  }

  // The node only receives what the network has.
  action deliverCertified(b: Block): bool = all { wCerts.contains(b), nodeCertified(b) }
  action deliverSkip(s: Slot): bool = all { wSkips.contains(s), nodeSkip(s) }
  // The node roots a finalized block it holds the certificate for
  // (event_handler.rs:957-1020). The root may jump over slots.
  action advanceRoot(b: Block): bool = all { wFinal.contains(b), certs.contains(b), nodeRoot(b) }

  action step = any {
    { nondet b = oneOf(BLOCKS)
      nondet p = oneOf(wCerts)
      certify(b, p) },
    { nondet s = oneOf(FREE_SLOTS)
      skipSlot(s) },
    { nondet b = oneOf(wCerts)
      finalize(b) },
    { nondet b = oneOf(wCerts)
      deliverCertified(b) },
    { nondet s = oneOf(FREE_SLOTS)
      deliverSkip(s) },
    { nondet b = oneOf(wFinal)
      advanceRoot(b) },
  }

  // ------------------------------------------------------------------
  // Properties. Node-side properties are about slots above the current root.
  // Tags:
  //   [tracker]      compares the transcribed tracker with the definition;
  //                  this is what can catch a difference from the code
  //   [construction] restates the definition, the id arithmetic or a guard
  //                  of `certify`; a failure means the model itself is wrong
  //   [assumption]   follows from the named assumption about the network,
  //                  not from anything the tracker does
  //
  // Index.
  //    1  trackerMatchesDefinition                  [tracker]
  //    2  readySetOnlyGrows                         [tracker]
  //    3a eventsOnlyForWindowStarts                 [tracker]
  //    3b eventsAtMostOnce                          [tracker]
  //    3c eventsNameReadyParent                     [tracker]
  //    3d readyParentsHaveEvent                     [tracker]
  //    4a laterCertifiedDescendFromFinalized        [assumption]
  //    4b laterReadyParentsDescendFromFinalized     [assumption]
  //    4c readyParentsDescendFromRoot               [assumption]
  //    5  certifiedOnValidParent                    [construction]
  //    6a leaderGetsSmallestReadyParent             [tracker]
  //    6b missedWindowMatchesCertificates           [tracker]
  //    7  coveredSlotHasReadyParent                 [construction]
  //    8a parentsNotBelowRoot                       [assumption]
  //    8b rootSlotParentIsRootBlock                 [assumption]
  //    8c leaderParentNotBelowRoot                  [assumption]
  //    9  highestIsHighestReadySlot                 [tracker]
  //   10  noPanic                                   [assumption]
  //   11  certifiedOnEarlierCertified               [construction]
  //   12  finalizedOnOneChain                       [assumption]
  //   13  skipOnlyInOpenWindow                      [construction]
  // Each is named prop<number>_<name>. IDS_DISTINCT is a check of the model's
  // id arithmetic, not a property of ParentReady, and has no number.
  // ------------------------------------------------------------------

  def R(s: Slot): Set[Block] = readySet(certs, skips, s)
  def above: Set[Slot] = SLOTS.filter(s => s > tr.root)
  def eventSet: Set[Event] = tr.events.indices().map(i => tr.events[i])
  def SEEDED: Event = { slot: N + 1, parent: ROOT0 }

  // prop1_trackerMatchesDefinition [tracker]: the tracker holds exactly what the definition says,
  // whatever the order the certificates and root moves came in.
  val prop1_trackerMatchesDefinition = above.forall(s => and {
    tr.st.get(s).parents == R(s),
    tr.st.get(s).skip == skips.contains(s),
    tr.st.get(s).certified == certs.filter(b => b.slot == s),
  })

  // prop2_readySetOnlyGrows [tracker]: a ready set never loses a parent.
  val prop2_readySetOnlyGrows = above.forall(s => prevParents.get(s).subseteq(tr.st.get(s).parents))

  // Events [tracker]: the ParentReady events the tracker emits.
  //  prop3a_eventsOnlyForWindowStarts - only for window starts
  //  prop3b_eventsAtMostOnce          - at most once per (slot, parent)
  //  prop3c_eventsNameReadyParent     - every event names a parent that is ready for
  //                              that slot
  //  prop3d_readyParentsHaveEvent     - every ready (window start, parent) pair has
  //                              its event, except the seeded pair, which the
  //                              tracker never announces (the service does,
  //                              consensus_pool_service.rs:295-298)
  val prop3a_eventsOnlyForWindowStarts = eventSet.forall(e => first(e.slot))
  val prop3b_eventsAtMostOnce = tr.events.length() == eventSet.size()
  val prop3c_eventsNameReadyParent = eventSet.forall(e => e.slot > tr.root implies R(e.slot).contains(e.parent))
  val prop3d_readyParentsHaveEvent = above.filter(s => first(s)).forall(s =>
    R(s).forall(b => eventSet.contains({ slot: s, parent: b }) or { slot: s, parent: b } == SEEDED))

  // prop9_highestIsHighestReadySlot [tracker]: `highest` is the highest slot with a ready parent. Any
  // slot counts, not only window starts. True here because the root always
  // sits on a block the tracker holds a certificate for; it is false for a
  // root without a certificate (migration; rootWithoutCertTest).
  val prop9_highestIsHighestReadySlot = tr.highest == above.filter(s => R(s).size() > 0).fold(N, (a, s) => maxInt(a, s))

  // prop6a_leaderGetsSmallestReadyParent [tracker]: what the leader of slot s is
  // told: the smallest ready parent, or why there is none. With ready parents
  // in two slots this is the older one: the code does not build on a block in
  // a skip-certified slot (lines 246-262).
  val prop6a_leaderGetsSmallestReadyParent = above.forall(s =>
    match productionParent(tr, s) {
      // p is ready, and no ready parent is smaller (slot first, then id);
      // written without minOf, which productionParent uses
      | Parent(p) => R(s).contains(p) and
          R(s).forall(q => p.slot < q.slot or (p.slot == q.slot and p.id <= q.id))
      | ParentNotReady => R(s).size() == 0
      | MissedWindow => above.exists(k => k > s and R(k).size() > 0)
    })

  // prop6b_missedWindowMatchesCertificates [tracker]: MissedWindow in terms of certificates only. The leader of
  // s is told it missed its window exactly when a block at slot >= s is
  // certified, or s itself is skip-certified and has a ready parent.
  val prop6b_missedWindowMatchesCertificates = above.forall(s =>
    (productionParent(tr, s) == MissedWindow) == or {
      certs.exists(b => b.slot >= s),
      skips.contains(s) and R(s).size() > 0,
    })

  // prop7_coveredSlotHasReadyParent [construction]: if every slot between the root and s has a certified
  // block or a skip certificate, s has a ready parent. Stated in
  // parentready.qnt (coveredHasParent); evaluated here on what the node
  // holds and on what the network holds.
  val prop7_coveredSlotHasReadyParent = and {
    above.forall(s => coveredHasParent(certs, skips, tr.root, s)),
    SLOTS.forall(s => coveredHasParent(wCerts, wSkips, N, s)),
  }

  // The root and ready parents [assumption: ASSUME_FINAL, and the node only
  // roots a finalized block it holds the certificate for]. For slots above
  // the root:
  //  prop8a_parentsNotBelowRoot       - no ready parent lies below the root
  //  prop8b_rootSlotParentIsRootBlock - the only ready parent in the root's own slot
  //                              is the root block
  //  prop8c_leaderParentNotBelowRoot  - what the first means for a leader: it is
  //                              never handed a parent below the root
  val prop8a_parentsNotBelowRoot =
    above.forall(s => tr.st.get(s).parents.forall(p => p.slot >= tr.root))
  val prop8b_rootSlotParentIsRootBlock = above.forall(s =>
    tr.st.get(s).parents.forall(p => p.slot == tr.root implies p == rootBlock))
  val prop8c_leaderParentNotBelowRoot = above.forall(s =>
    match productionParent(tr, s) {
      | Parent(p) => p.slot >= tr.root
      | _ => true
    })

  // prop10_noPanic [assumption: ASSUME_Q5]: the tracker never hits its assert,
  // because the network never certifies one block too many in a slot. Every
  // other property here is about a tracker that has not panicked.
  val prop10_noPanic = not(tr.panicked)

  // IDS_DISTINCT [construction]: no two blocks share an id, whatever seed the
  // run picked.
  val IDS_DISTINCT = idsDistinct(idSeed)

  // ------------------------------------------------------------------
  // Chains.
  // ------------------------------------------------------------------

  // b and all its ancestors, down to the initial root. Kept up to date as
  // blocks are certified: anc(b) = {b} + anc(parent of b).
  def anc(b: Block): Set[Block] = ancOf.get(b)

  // prop11_certifiedOnEarlierCertified [construction]: every certified block was built on a certified block
  // of an earlier slot (the first guards of `certify`).
  val prop11_certifiedOnEarlierCertified = wCerts.forall(b =>
    b == ROOT0 or (wCerts.contains(parentOf.get(b)) and parentOf.get(b).slot < b.slot))

  // prop5_certifiedOnValidParent [construction]: a certified block in the first slot of a window
  // was built on a ready parent for that slot; in any other slot, on a block
  // of the slot before. This is ASSUME_CHAIN read back from the state.
  val prop5_certifiedOnValidParent = wCerts.forall(b =>
    b == ROOT0 or
      (if (first(b.slot)) ready(wCerts, wSkips, b.slot, parentOf.get(b))
       else parentOf.get(b).slot == b.slot - 1))

  // prop13_skipOnlyInOpenWindow [construction]: every skip-certified slot lies
  // in an open window. This is ASSUME_WINDOW read back from the state; it
  // stays true later because a window never closes.
  val prop13_skipOnlyInOpenWindow = wSkips.forall(s => windowOpen(s))

  // prop12_finalizedOnOneChain [assumption: ASSUME_CHAIN and ASSUME_FINAL]: finalized blocks lie on
  // one chain.
  val prop12_finalizedOnOneChain = wFinal.forall(f => wFinal.forall(g => anc(f).contains(g) or anc(g).contains(f)))

  // Finalized blocks [assumption: ASSUME_CHAIN and ASSUME_FINAL]: a finalized
  // block is an ancestor of
  //  prop4a_laterCertifiedDescendFromFinalized    - every certified block in a later
  //                                          slot
  //  prop4b_laterReadyParentsDescendFromFinalized - every ready parent for a later
  //                                          slot, anywhere in the network
  //  prop4c_readyParentsDescendFromRoot           - at the node: every ready parent
  //                                          above its root is the root block
  //                                          or a descendant of it
  val prop4a_laterCertifiedDescendFromFinalized = wFinal.forall(f => wCerts.forall(b => b.slot > f.slot implies anc(b).contains(f)))
  val prop4b_laterReadyParentsDescendFromFinalized = SLOTS.forall(s => readySet(wCerts, wSkips, s).forall(p =>
    wFinal.forall(f => s > f.slot implies anc(p).contains(f))))
  val prop4c_readyParentsDescendFromRoot = above.forall(s => tr.st.get(s).parents.forall(p => anc(p).contains(rootBlock)))

  // ------------------------------------------------------------------
  // What to check.
  // ------------------------------------------------------------------

  // The transcribed tracker against the definition.
  val TRACKER = and {
    prop1_trackerMatchesDefinition, prop2_readySetOnlyGrows,
    prop3a_eventsOnlyForWindowStarts, prop3b_eventsAtMostOnce, prop3c_eventsNameReadyParent, prop3d_readyParentsHaveEvent,
    prop9_highestIsHighestReadySlot, prop6a_leaderGetsSmallestReadyParent, prop6b_missedWindowMatchesCertificates,
  }
  // True by construction of the model.
  val BY_CONSTRUCTION = and {
    IDS_DISTINCT, prop7_coveredSlotHasReadyParent, prop11_certifiedOnEarlierCertified, prop5_certifiedOnValidParent,
    prop13_skipOnlyInOpenWindow,
  }
  // True because of the assumptions about the network.
  val FROM_ASSUMPTIONS = and {
    prop10_noPanic, prop8a_parentsNotBelowRoot, prop8b_rootSlotParentIsRootBlock, prop8c_leaderParentNotBelowRoot,
    prop12_finalizedOnOneChain, prop4a_laterCertifiedDescendFromFinalized,
    prop4b_laterReadyParentsDescendFromFinalized, prop4c_readyParentsDescendFromRoot,
  }

  // Everything; for instances with all assumptions on.
  val ALL = and { TRACKER, BY_CONSTRUCTION, FROM_ASSUMPTIONS }
  // Everything that does not need ASSUME_CHAIN or ASSUME_WINDOW; for tr_free.
  val NO_CHAIN = and {
    TRACKER, IDS_DISTINCT, prop7_coveredSlotHasReadyParent, prop11_certifiedOnEarlierCertified,
    prop10_noPanic, prop8a_parentsNotBelowRoot, prop8b_rootSlotParentIsRootBlock, prop8c_leaderParentNotBelowRoot,
  }

  // ------------------------------------------------------------------
  // Witnesses: situations that should be reachable. Each is a predicate on
  // the state, not an invariant.
  //   simulation:  ./q run --main=tr_n101 --witnesses witRun6 witTwoSlots ... spec/tracker.qnt
  //                (reports in how many traces each one came true)
  //   exhaustive:  ./q verify --main=tr_tiny --invariant='not(witRun3)' spec/tracker.qnt
  //                (a reported violation is a shortest example; no violation
  //                 means it cannot happen within the step bound)
  // ------------------------------------------------------------------

  // n slots in a row each have at least one certified block
  def certifiedRun(n: int): bool = FREE_SLOTS.exists(s =>
    s + n - 1 <= MAX_SLOT and
      SLOTS.forall(k => (s <= k and k < s + n) implies wCerts.exists(b => b.slot == k)))
  val witRun3 = certifiedRun(3)
  val witRun6 = certifiedRun(6)
  val witRunAll = certifiedRun(SPAN)

  // a certified block with at least four ancestors besides itself
  val witLongChain = wCerts.exists(b => anc(b).size() >= 5)
  // the node's root sits on a block at least four links above the initial root
  val witRootOnChain = anc(rootBlock).size() >= 5
  // a window start with ready parents in two different slots
  val witTwoSlots = above.exists(s =>
    first(s) and R(s).exists(a => R(s).exists(b => a.slot != b.slot)))
  // a window start with two ready parents in the same slot
  val witSameSlot = above.exists(s =>
    first(s) and R(s).exists(a => R(s).exists(b => a.slot == b.slot and a.id != b.id)))
  // the node's root is more than three slots above the initial root, and at
  // least two blocks besides the initial root are finalized
  val witRootAdvanced = wFinal.size() >= 3 and tr.root > N + 3
  // a slot holds MAX_CERTIFIED certified blocks (needs BLOCKS_PER_SLOT >= MAX_CERTIFIED)
  val witFullSlot = FREE_SLOTS.exists(s =>
    wCerts.filter(b => b.slot == s).size() == MAX_CERTIFIED)
  // a slot holds more than MAX_CERTIFIED certified blocks: must never happen
  val witOverfullSlot = FREE_SLOTS.exists(s =>
    wCerts.filter(b => b.slot == s).size() > MAX_CERTIFIED)
  // a leader is told MissedWindow for a window start above the root
  val witMissed = above.exists(s =>
    first(s) and s <= MAX_SLOT and productionParent(tr, s) == MissedWindow)
}

// Instances. The root starts at each position inside a window.
module tr_n100 { import tracker(W = 4, N = 100, SPAN = 9, BLOCKS_PER_SLOT = 2, MAX_CERTIFIED = 4, ASSUME_FINAL = true, ASSUME_CHAIN = true, ASSUME_WINDOW = true).* }
module tr_n101 { import tracker(W = 4, N = 101, SPAN = 9, BLOCKS_PER_SLOT = 2, MAX_CERTIFIED = 4, ASSUME_FINAL = true, ASSUME_CHAIN = true, ASSUME_WINDOW = true).* }
module tr_n102 { import tracker(W = 4, N = 102, SPAN = 9, BLOCKS_PER_SLOT = 2, MAX_CERTIFIED = 4, ASSUME_FINAL = true, ASSUME_CHAIN = true, ASSUME_WINDOW = true).* }
module tr_n103 { import tracker(W = 4, N = 103, SPAN = 9, BLOCKS_PER_SLOT = 2, MAX_CERTIFIED = 4, ASSUME_FINAL = true, ASSUME_CHAIN = true, ASSUME_WINDOW = true).* }
// five blocks per slot, so the limit of 4 certified blocks is reached
module tr_b5 { import tracker(W = 4, N = 101, SPAN = 5, BLOCKS_PER_SLOT = 5, MAX_CERTIFIED = 4, ASSUME_FINAL = true, ASSUME_CHAIN = true, ASSUME_WINDOW = true).* }
// two-slot windows
module tr_w2 { import tracker(W = 2, N = 101, SPAN = 7, BLOCKS_PER_SLOT = 2, MAX_CERTIFIED = 4, ASSUME_FINAL = true, ASSUME_CHAIN = true, ASSUME_WINDOW = true).* }
// any certificates, no chains, skips in any slot. Check NO_CHAIN here, not ALL.
module tr_free { import tracker(W = 4, N = 101, SPAN = 9, BLOCKS_PER_SLOT = 2, MAX_CERTIFIED = 4, ASSUME_FINAL = true, ASSUME_CHAIN = false, ASSUME_WINDOW = false).* }
// the finalization facts not assumed. Checking ALL here is expected to fail
// (the tracker, root and chain properties): it shows which properties depend
// on ASSUME_FINAL.
module tr_nofinal { import tracker(W = 4, N = 101, SPAN = 9, BLOCKS_PER_SLOT = 2, MAX_CERTIFIED = 4, ASSUME_FINAL = false, ASSUME_CHAIN = true, ASSUME_WINDOW = true).* }
// small enough for the exhaustive checker
module tr_tiny { import tracker(W = 2, N = 101, SPAN = 3, BLOCKS_PER_SLOT = 2, MAX_CERTIFIED = 4, ASSUME_FINAL = true, ASSUME_CHAIN = true, ASSUME_WINDOW = true).* }

// The tracker's own unit tests (parent_ready_tracker.rs:316-542) replayed.
// They root the tracker at genesis, hence N = 0 here.
// Block::new_unique(i) becomes blockOf(i, 1). The tests hand the tracker
// certificates directly, so they use the node's calls, not the network.
module tr_tests {
  import tracker(W = 4, N = 0, SPAN = 64, BLOCKS_PER_SLOT = 5, MAX_CERTIFIED = 4, ASSUME_FINAL = true, ASSUME_CHAIN = false, ASSUME_WINDOW = false).*

  def B(i: int): Block = blockOf(i, 1)
  def isReady(s: Slot, b: Block): bool = tr.st.get(s).parents.contains(b)

  // basic (316)
  run basicTest =
    init.then(7.reps(i =>
      nodeCertified(B(i + 1)).expect(tr.highest == i + 2 and isReady(i + 2, B(i + 1)))))

  // skips (345)
  run skipsTest =
    init.then(nodeCertified(B(1)))
      .then(nodeSkip(1)).then(nodeSkip(2)).then(nodeSkip(3))
      .expect(isReady(4, B(1)) and isReady(4, ROOT0) and tr.highest == 4)

  // out_of_order (363)
  run outOfOrderTest =
    init.then(nodeSkip(3)).then(nodeSkip(2))
      .then(nodeCertified(B(1)))
      .expect(isReady(4, B(1)) and not(isReady(4, ROOT0)))
      .then(nodeSkip(1))
      .expect(isReady(4, B(1)) and isReady(4, ROOT0))

  // highest_parent_ready_out_of_order (458)
  run highestOutOfOrderTest =
    init.expect(tr.highest == 1)
      .then(nodeSkip(2)).expect(tr.highest == 1)
      .then(nodeSkip(3)).expect(tr.highest == 1)
      .then(nodeSkip(1))
      .expect(isReady(4, ROOT0) and tr.highest == 4
        and productionParent(tr, 4) == Parent(ROOT0))

  // missed_window (481)
  run missedWindowTest =
    init.expect(tr.highest == 1 and productionParent(tr, 4) == ParentNotReady)
      .then(nodeCertified(B(4)))
      .expect(tr.highest == 5 and productionParent(tr, 4) == MissedWindow)
      .expect(productionParent(tr, 8) == ParentNotReady)
      .then(nodeCertified(B(64)))
      .expect(tr.highest == 65 and productionParent(tr, 8) == MissedWindow)

  // pick_more_skips (512)
  run pickMoreSkipsTest =
    init.then(10.reps(i => nodeSkip(i + 1).then(nodeCertified(B(i + 1)))))
      .then(nodeSkip(11))
      .expect(and {
        tr.highest == 12,
        tr.events.indices().map(i => tr.events[i]).filter(e => e.slot == 12).map(e => e.parent.slot)
          == 0.to(10),
        tr.events.indices().map(i => tr.events[i]).filter(e => e.slot == 12).size() == 11,
        productionParent(tr, 12) == Parent(ROOT0),
      })

  // test_too_many_notar_fallback_blocks (334): five different blocks of slot 1
  // handed to the tracker. The fifth is a panic; nothing changes after it.
  run tooManyTest =
    init.then(4.reps(i => nodeCertified(blockOf(1, i + 1))))
      .expect(not(tr.panicked) and tr.st.get(1).certified.size() == 4)
      // a block the tracker already holds is not a fifth one (line 135)
      .then(nodeCertified(blockOf(1, 1)))
      .expect(not(tr.panicked))
      .then(nodeCertified(blockOf(1, 5)))
      .expect(and {
        tr.panicked,
        tr.st.get(1).certified.size() == 4,
        addCertified(tr, B(2)) == tr,
        addSkip(tr, 1) == tr,
        setRoot(tr, 3) == tr,
      })

  // ASSUME_Q5: the network refuses to certify the fifth block of a slot, so
  // the node never sees one.
  run networkLimitTest =
    init.then(4.reps(i => certify(blockOf(1, i + 1), ROOT0)))
      .then(certify(blockOf(1, 5), ROOT0))
      .fail()

  // root_notar_fallback_seeds_parent_ready (412), first two assertions: a
  // root the tracker holds no certificate for leaves the next slot without a
  // parent, and a certificate for the root slot arriving later is ignored.
  run rootWithoutCertTest =
    init.expect(and {
      productionParent(setRoot(tr, 63), 64) == ParentNotReady,
      addCertified(setRoot(tr, 63), B(63)) == setRoot(tr, 63),
    })
}

// snapshot_wfsm (383): the Rust test that roots the tracker away from genesis.
module tr_tests_root {
  import tracker(W = 4, N = 2147, SPAN = 5, BLOCKS_PER_SLOT = 1, MAX_CERTIFIED = 4, ASSUME_FINAL = false, ASSUME_CHAIN = false, ASSUME_WINDOW = false).*

  def isReady(s: Slot, b: Block): bool = tr.st.get(s).parents.contains(b)

  run snapshotTest =
    init.expect(isReady(N + 1, ROOT0) and tr.highest == N + 1)
      // "Skipping root slot shouldn't do anything"
      .then(nodeSkip(N))
      .expect(isReady(N + 1, ROOT0) and tr.highest == N + 1)
      .then(nodeSkip(N + 1).then(nodeSkip(N + 2)))
      .expect(isReady(N + 3, ROOT0) and tr.highest == N + 3)
      .then(nodeCertified(blockOf(N + 4, 1)))
      .expect(isReady(N + 3, ROOT0) and isReady(N + 5, blockOf(N + 4, 1))
        and tr.highest == N + 5)
}
