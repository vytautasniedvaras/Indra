import Foundation
import Testing

@testable import IndraKitCore

@Suite("TileCache")
struct TileCacheTests {
    func makeTile(bytes: Int) -> Tile {
        Tile(data: Data(repeating: 7, count: bytes), shape: [bytes], dtype: "uint8")
    }

    func key(_ n: Int) -> TileKey {
        TileKey(audioId: "a", kind: .spec, lod: 0, bounds: [n, n + 1, 0, 0])
    }

    @Test func insertAndFetch() async {
        let cache = TileCache(limitBytes: 1000)
        await cache.insert(makeTile(bytes: 100), for: key(1))
        let tile = await cache.tile(for: key(1))
        #expect(tile?.data.count == 100)
        #expect(await cache.totalBytes == 100)
    }

    @Test func keyStability() {
        #expect(key(1) == TileKey(audioId: "a", kind: .spec, lod: 0, bounds: [1, 2, 0, 0]))
        #expect(key(1) != key(2))
        #expect(
            key(1)
                != TileKey(audioId: "a", kind: .waveform, lod: 0, bounds: [1, 2, 0, 0]))
    }

    @Test func lruEviction() async {
        let cache = TileCache(limitBytes: 250)
        await cache.insert(makeTile(bytes: 100), for: key(1))
        await cache.insert(makeTile(bytes: 100), for: key(2))
        _ = await cache.tile(for: key(1))  // refresh 1 → 2 becomes LRU
        await cache.insert(makeTile(bytes: 100), for: key(3))  // over limit → evict 2
        #expect(await cache.tile(for: key(2)) == nil)
        #expect(await cache.tile(for: key(1)) != nil)
        #expect(await cache.tile(for: key(3)) != nil)
        #expect(await cache.totalBytes == 200)
    }

    @Test func replaceSameKeyAccountsBytes() async {
        let cache = TileCache(limitBytes: 1000)
        await cache.insert(makeTile(bytes: 100), for: key(1))
        await cache.insert(makeTile(bytes: 300), for: key(1))
        #expect(await cache.totalBytes == 300)
        #expect(await cache.count == 1)
    }

    @Test func removeByAudioId() async {
        let cache = TileCache(limitBytes: 1000)
        await cache.insert(makeTile(bytes: 10), for: key(1))
        await cache.insert(
            makeTile(bytes: 10),
            for: TileKey(audioId: "other", kind: .spec, lod: 0, bounds: [0, 1, 0, 0]))
        await cache.removeAll(audioId: "a")
        #expect(await cache.count == 1)
        #expect(await cache.totalBytes == 10)
    }
}

extension Tile: @retroactive Equatable {
    public static func == (lhs: Tile, rhs: Tile) -> Bool {
        lhs.data == rhs.data && lhs.shape == rhs.shape && lhs.dtype == rhs.dtype
    }
}
