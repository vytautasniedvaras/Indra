// Byte-bounded LRU cache for waveform/spectrogram tiles (BUILD_SPEC §5.1).
// Actor: tiles arrive from network tasks and are read by the render loop.

import Foundation

public struct TileKey: Hashable, Sendable {
    public enum Kind: String, Sendable {
        case waveform, spec
    }

    public var audioId: String
    public var kind: Kind
    public var lod: Int
    /// Waveform: (start, count, 0, 0). Spec: (t0, t1, f0, f1).
    public var bounds: [Int]

    public init(audioId: String, kind: Kind, lod: Int, bounds: [Int]) {
        self.audioId = audioId
        self.kind = kind
        self.lod = lod
        self.bounds = bounds
    }
}

public struct Tile: Sendable {
    public var data: Data
    public var shape: [Int]
    public var dtype: String

    public init(data: Data, shape: [Int], dtype: String) {
        self.data = data
        self.shape = shape
        self.dtype = dtype
    }
}

public actor TileCache {
    private var storage: [TileKey: Tile] = [:]
    private var order: [TileKey] = []  // LRU: least-recent first
    private(set) public var totalBytes: Int = 0
    public let limitBytes: Int

    public init(limitBytes: Int) {
        self.limitBytes = limitBytes
    }

    public var count: Int { storage.count }

    public func tile(for key: TileKey) -> Tile? {
        guard let tile = storage[key] else { return nil }
        touch(key)
        return tile
    }

    public func insert(_ tile: Tile, for key: TileKey) {
        if let existing = storage[key] {
            totalBytes -= existing.data.count
        }
        storage[key] = tile
        totalBytes += tile.data.count
        touch(key)
        evictIfNeeded()
    }

    public func removeAll(audioId: String? = nil) {
        if let audioId {
            for key in storage.keys where key.audioId == audioId {
                if let removed = storage.removeValue(forKey: key) {
                    totalBytes -= removed.data.count
                }
            }
            order.removeAll { $0.audioId == audioId }
        } else {
            storage.removeAll()
            order.removeAll()
            totalBytes = 0
        }
    }

    private func touch(_ key: TileKey) {
        if let index = order.firstIndex(of: key) {
            order.remove(at: index)
        }
        order.append(key)
    }

    private func evictIfNeeded() {
        while totalBytes > limitBytes, let victim = order.first {
            order.removeFirst()
            if let removed = storage.removeValue(forKey: victim) {
                totalBytes -= removed.data.count
            }
        }
    }
}
