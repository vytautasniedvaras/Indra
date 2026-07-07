import Testing

@testable import IndraKitCore

@Suite("AtlasIndex")
struct SpecAtlasTests {
    func key(_ start: Int, lod: Int = 0) -> TileKey {
        TileKey(audioId: "a", kind: .spec, lod: lod, bounds: [start, start + 512, 0, 2049])
    }

    @Test func allocatesFreshSlotsUntilFull() {
        var atlas = AtlasIndex(capacity: 3)
        #expect(atlas.allocate(key(0)) == .init(slot: 0))
        #expect(atlas.allocate(key(512)) == .init(slot: 1))
        #expect(atlas.allocate(key(1024)) == .init(slot: 2))
        #expect(atlas.count == 3)
        #expect(atlas.slotsByKey[key(512)] == 1)
    }

    @Test func reallocatingResidentKeyKeepsSlot() {
        var atlas = AtlasIndex(capacity: 2)
        _ = atlas.allocate(key(0))
        let again = atlas.allocate(key(0))
        #expect(again.slot == 0)
        #expect(again.evicted == nil)
        #expect(atlas.count == 1)
    }

    @Test func evictsLeastRecentlyUsedWhenFull() {
        var atlas = AtlasIndex(capacity: 2)
        _ = atlas.allocate(key(0))  // slot 0
        _ = atlas.allocate(key(512))  // slot 1
        let third = atlas.allocate(key(1024))
        #expect(third.slot == 0)  // key(0) was least recent
        #expect(third.evicted == key(0))
        #expect(!atlas.contains(key(0)))
        #expect(atlas.contains(key(512)))
        #expect(atlas.contains(key(1024)))
    }

    @Test func slotLookupRefreshesRecency() {
        var atlas = AtlasIndex(capacity: 2)
        _ = atlas.allocate(key(0))
        _ = atlas.allocate(key(512))
        #expect(atlas.slot(of: key(0)) == 0)  // touch → key(512) is now LRU
        let next = atlas.allocate(key(1024))
        #expect(next.evicted == key(512))
        #expect(atlas.contains(key(0)))
    }

    @Test func markUsedProtectsDrawnTiles() {
        var atlas = AtlasIndex(capacity: 2)
        _ = atlas.allocate(key(0))
        _ = atlas.allocate(key(512))
        atlas.markUsed([key(0)])
        let next = atlas.allocate(key(1024))
        #expect(next.evicted == key(512))
    }

    @Test func slotOfMissingKeyIsNil() {
        var atlas = AtlasIndex(capacity: 2)
        #expect(atlas.slot(of: key(0)) == nil)
    }

    @Test func removeAllResets() {
        var atlas = AtlasIndex(capacity: 2)
        _ = atlas.allocate(key(0))
        atlas.removeAll()
        #expect(atlas.count == 0)
        #expect(atlas.allocate(key(512)).slot == 0)
    }
}
