// Wire type for GET /files/{id}/features/{kind} (docs/api.md), which serves
// analysis curves as raw values or per-bucket min/max at display width (§4.4)
// — the data source for the renderer's curve lanes (BUILD_SPEC §5.3, §5.4).
//
// Decoded with a PLAIN JSONDecoder via `FeatureTable.decode`, NOT
// IndraJSON.decoder: convertFromSnakeCase rewrites dictionary keys, which
// would mangle bucket column names ("h_entropy" → "hEntropy",
// "novelty_8s" → "novelty8s") and break the cross-reference with `columns`.
// The few snake_case top-level fields get explicit CodingKeys instead.

import Foundation

/// Min/max buckets for one value column (`minmax_buckets` on the backend):
/// parallel arrays of bucket-center time, minimum, and maximum.
public struct FeatureBucketSeries: Codable, Sendable, Equatable {
    public var t: [Double]
    public var min: [Double]
    public var max: [Double]

    public init(t: [Double], min: [Double], max: [Double]) {
        self.t = t
        self.min = min
        self.max = max
    }
}

/// A served feature table. Exactly one of `buckets` (downsample requested) or
/// `values` (raw, ≤ 20 000 points) is present.
public struct FeatureTable: Codable, Sendable, Equatable {
    public var audioId: String
    public var kind: String
    /// Cache key of the served variant (pass back as `?key=` to pin it).
    public var cacheKey: String?
    /// Value column names ("value", "h_entropy", "novelty_8s", …).
    public var columns: [String]
    /// Points in the requested window (pre-downsample).
    public var n: Int
    /// Min/max buckets per value column, keyed by column name (verbatim).
    public var buckets: [String: FeatureBucketSeries]?
    /// Raw mode: "time_s" plus one entry per value column.
    public var values: [String: [Double]]?

    enum CodingKeys: String, CodingKey {
        case audioId = "audio_id"
        case kind
        case cacheKey = "cache_key"
        case columns
        case n
        case buckets
        case values
    }

    public init(
        audioId: String, kind: String, cacheKey: String? = nil, columns: [String],
        n: Int, buckets: [String: FeatureBucketSeries]? = nil,
        values: [String: [Double]]? = nil
    ) {
        self.audioId = audioId
        self.kind = kind
        self.cacheKey = cacheKey
        self.columns = columns
        self.n = n
        self.buckets = buckets
        self.values = values
    }

    /// Decode from response bytes with key names preserved (see file header).
    public static func decode(_ data: Data) throws -> FeatureTable {
        try JSONDecoder().decode(FeatureTable.self, from: data)
    }
}
