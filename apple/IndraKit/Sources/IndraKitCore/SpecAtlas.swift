// Atlas slot allocation for the Metal tile renderer (BUILD_SPEC §5.3,
// ADR 0013): the renderer keeps resident spectrogram tiles in one
// `texture2d_array` whose slices are fixed-size slots; this value type decides
// which TileKey lives in which slot and which slot to recycle when full
// (least-recently-used). Pure bookkeeping — no Metal here, so the policy is
// Linux-testable while the MTKView layer stays thin.

/// LRU map from `TileKey` to an atlas slot index in `0..<capacity`.
public struct AtlasIndex: Sendable, Equatable {
    /// Result of `allocate`: the slot to upload into, plus the key that lost
    /// its slot (nil while free slots remain or when the key was resident).
    public struct Allocation: Sendable, Equatable {
        public var slot: Int
        public var evicted: TileKey?

        public init(slot: Int, evicted: TileKey? = nil) {
            self.slot = slot
            self.evicted = evicted
        }
    }

    public let capacity: Int
    private var slotsByKeyStorage: [TileKey: Int] = [:]
    private var keysBySlot: [Int: TileKey] = [:]
    /// Monotonic use tick per slot; the minimum is the LRU victim.
    private var lastUsed: [Int: Int] = [:]
    private var nextFreeSlot = 0
    private var tick = 0

    public init(capacity: Int) {
        self.capacity = max(capacity, 1)
    }

    public var count: Int { slotsByKeyStorage.count }

    /// Snapshot for the render planner (`SpecRenderPlanner.plan(resident:)`).
    public var slotsByKey: [TileKey: Int] { slotsByKeyStorage }

    public func contains(_ key: TileKey) -> Bool {
        slotsByKeyStorage[key] != nil
    }

    /// Slot of a resident key, marking it most-recently-used.
    public mutating func slot(of key: TileKey) -> Int? {
        guard let slot = slotsByKeyStorage[key] else { return nil }
        touch(slot)
        return slot
    }

    /// Mark resident keys as used without needing their slots (called with the
    /// keys a frame actually drew, so visible tiles never age out first).
    public mutating func markUsed<Keys: Sequence>(_ keys: Keys) where Keys.Element == TileKey {
        for key in keys {
            if let slot = slotsByKeyStorage[key] { touch(slot) }
        }
    }

    /// Slot for `key`, reusing its existing slot, then a never-used slot, then
    /// evicting the least-recently-used resident. The caller uploads the tile
    /// into `Allocation.slot`; `evicted` is informational (the slot's texels
    /// are simply overwritten).
    public mutating func allocate(_ key: TileKey) -> Allocation {
        if let slot = slotsByKeyStorage[key] {
            touch(slot)
            return Allocation(slot: slot)
        }
        if nextFreeSlot < capacity {
            let slot = nextFreeSlot
            nextFreeSlot += 1
            insert(key, at: slot)
            return Allocation(slot: slot)
        }
        // Evict the LRU slot. lastUsed always covers every occupied slot.
        let victim = lastUsed.min { $0.value < $1.value }!.key
        let evicted = keysBySlot[victim]
        if let evicted { slotsByKeyStorage[evicted] = nil }
        insert(key, at: victim)
        return Allocation(slot: victim, evicted: evicted)
    }

    public mutating func removeAll() {
        slotsByKeyStorage.removeAll()
        keysBySlot.removeAll()
        lastUsed.removeAll()
        nextFreeSlot = 0
        tick = 0
    }

    private mutating func insert(_ key: TileKey, at slot: Int) {
        slotsByKeyStorage[key] = slot
        keysBySlot[slot] = key
        touch(slot)
    }

    private mutating func touch(_ slot: Int) {
        tick += 1
        lastUsed[slot] = tick
    }
}
