// -*- mode: Bluespec; -*-
//
// ParentReady: constants, types, block ids, and the definition.
// The Rust tracker and its checks are in tracker.qnt.
//
// Source: Agave v5.0.0-alpha.1, votor/src/consensus_pool/parent_ready_tracker.rs.
// Line numbers in the comments are those of that version.
// Scope: steady state. The root starts at a block in slot N that the node
// holds a certificate for, and advances as the chain makes progress.
module parentready {
  // ---------------- constants ----------------

  const W: int      // slots per leader window (NUM_CONSECUTIVE_LEADER_SLOTS = 4)
  const N: int      // slot of the initial root block. Windows are aligned to slot 0,
                    // so N % W decides where in a window the model starts.
  const SPAN: int   // how many slots after N can receive certificates
  const BLOCKS_PER_SLOT: int  // how many different blocks can exist in one slot
  const MAX_CERTIFIED: int  // MAX_NOTAR_FALLBACK_BLOCKS = 4 (votor/src/common.rs:10)

  // ---------------- types ----------------

  type Slot = int

  // A block is always the pair, never a bare slot or a bare id.
  // Ordered by slot, then id (derive(Ord) on the Rust struct).
  type Block = { slot: Slot, id: int }

  // What the tracker knows about one slot. It stores certificates, not votes.
  //   skip      - a Skip certificate exists for the slot
  //   certified - blocks of this slot holding a NotarizeFallback, Notarize or
  //               FinalizeFast certificate; the code keeps all three in one
  //               list (`notar_fallbacks`) and never tells them apart
  //   parents   - blocks that are ready parents for this slot (`parents_ready`)
  type Status = { skip: bool, certified: Set[Block], parents: Set[Block] }

  type Event = { slot: Slot, parent: Block }

  // The tracker's state (Rust `ParentReadyTracker`).
  //   st      - map from slot to Status (`slot_statuses: HashMap<Slot, ParentReadyStatus>`)
  //   root    - the current root slot (`root`); starts at N and only moves forward
  //   highest - `highest_with_parent_ready`
  //   events  - record of the ParentReady events emitted
  //   panicked - the code asserts at most MAX_CERTIFIED certified blocks in a
  //              slot (line 143). Here the tracker stops and stays as it was.
  type Tracker = { st: Slot -> Status, root: Slot, highest: Slot, events: List[Event],
                   panicked: bool }

  // What the leader is told when it asks for a parent (`BlockProductionParent`).
  type Choice = MissedWindow | ParentNotReady | Parent(Block)

  // ---------------- derived values ----------------

  pure val MAX_SLOT: Slot = N + SPAN
  // One slot past the last one that can receive a certificate.
  pure val H: Slot = MAX_SLOT + 1
  pure val SLOTS: Set[Slot] = N.to(H)
  pure val FREE_SLOTS: Set[Slot] = (N + 1).to(MAX_SLOT)
  pure val SLOT_LIST: List[Slot] = range(N, H + 1)

  // ---------------- block ids ----------------
  //
  // In the code an id is a 32-byte hash. Here it is a 15-bit number computed
  // from a seed, the slot and the block's number within the slot. 15 bits
  // because the explicit-state checker (TLC) has 32-bit integers. The seed is
  // DEFAULT_ID_SEED unless a run picks one from SEEDS.
  pure val ID_MOD: int = 32749        // a prime below 2^15
  pure val DEFAULT_ID_SEED: int = 7
  pure val SEEDS: Set[int] = 0.to(ID_MOD - 1)
  pure def blockId(seed: int, s: Slot, k: int): int =
    ((s * 64 + k + seed) % ID_MOD) * 27449 % ID_MOD
  // Block number k of slot s.
  pure def blockAt(seed: int, s: Slot, k: int): Block = { slot: s, id: blockId(seed, s, k) }
  // The root block the model starts from.
  pure def initialRoot(seed: int): Block = blockAt(seed, N, 0)
  // Every block that can exist above the initial root.
  pure def allBlocks(seed: int): Set[Block] =
    tuples(FREE_SLOTS, 1.to(BLOCKS_PER_SLOT)).map(p => blockAt(seed, p._1, p._2))
  // No two blocks share an id.
  pure def idsDistinct(seed: int): bool =
    allBlocks(seed).union(Set(initialRoot(seed))).map(b => b.id).size()
      == SPAN * BLOCKS_PER_SLOT + 1

  // ---------------- helpers ----------------

  // s is the first slot of a leader window.
  pure def first(s: Slot): bool = s % W == 0
  // The first slot of the leader window that s is in.
  pure def windowStart(s: Slot): Slot = s - s % W

  // Block order: slot first, then id.
  pure def le(a: Block, b: Block): bool =
    a.slot < b.slot or (a.slot == b.slot and a.id <= b.id)

  pure def minOf(bs: Set[Block]): Block =
    bs.fold({ slot: H + 1, id: 0 }, (acc, p) => if (le(p, acc)) p else acc)

  // ---------------- definition of ParentReady ----------------
  //
  // As stated in the tracker's module doc (parent_ready_tracker.rs:1-13).
  //   certs - blocks holding a certificate (NotarizeFallback or stronger)
  //   skips - slots holding a Skip certificate

  // b is a ready parent for slot s: b is certified, and every slot strictly
  // between slot(b) and s has a skip certificate.
  // Quantified over the fixed set SLOTS because the exhaustive checker needs
  // ranges with constant bounds.
  pure def ready(certs: Set[Block], skips: Set[Slot], s: Slot, b: Block): bool = and {
    certs.contains(b),
    b.slot < s,
    SLOTS.forall(k => (b.slot < k and k < s) implies skips.contains(k)),
  }

  pure def readySet(certs: Set[Block], skips: Set[Slot], s: Slot): Set[Block] =
    certs.filter(b => ready(certs, skips, s, b))

  // ---------------- a consequence of the definition ----------------

  // If slot r has a certified block, and every slot strictly between r
  // and s has a certified block or a skip certificate, then s has a ready
  // parent. It holds for any certificates.
  pure def coveredHasParent(certs: Set[Block], skips: Set[Slot], r: Slot, s: Slot): bool =
    and {
      r < s,
      certs.exists(b => b.slot == r),
      SLOTS.forall(k => (r < k and k < s) implies
        (skips.contains(k) or certs.exists(b => b.slot == k))),
    } implies readySet(certs, skips, s).size() > 0
}

// Example instance, for typechecking parentready on its own.
module parentready_example {
  import parentready(W = 4, N = 101, SPAN = 9, BLOCKS_PER_SLOT = 2, MAX_CERTIFIED = 4).*
}
