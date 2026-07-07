// Similar-segment search results (docs/api.md POST /select/similar): time
// segments that sound like the seed — from one file or every imported file —
// plus the optional cluster-map embedding (2-D coords + cluster labels) that
// feeds the constellation view (docs/design/selection-ux.md §3).
//
// Like MagicSelection, parsing accepts BOTH wire snake_case keys and the
// camelCase produced when the result_ref went through convertFromSnakeCase
// (Foundation rewrites dictionary keys on some decode paths, not others).

/// One matched segment. `audioId` is nil for single-file searches (the seed
/// file is implicit); folder-wide results carry it.
public struct SimilarSegment: Sendable, Equatable {
    public var audioId: String?
    public var t0: Double
    public var t1: Double
    /// Cosine distance to the seed: 0 = identical, calibrated threshold 0.4.
    public var distance: Double

    public init(audioId: String? = nil, t0: Double, t1: Double, distance: Double) {
        self.audioId = audioId
        self.t0 = t0
        self.t1 = t1
        self.distance = distance
    }
}

/// Cluster-map data for the constellation view, in segment order.
public struct SegmentEmbedding: Sendable, Equatable {
    public var xy: [[Double]]
    public var cluster: [Int]
    public var nClusters: Int

    public init(xy: [[Double]], cluster: [Int], nClusters: Int) {
        self.xy = xy
        self.cluster = cluster
        self.nClusters = nClusters
    }
}

/// Decoded select_similar job result_ref.
public struct SimilarSearchResult: Sendable, Equatable {
    public var segments: [SimilarSegment]
    public var threshold: Double
    /// Files scanned, folder-wide searches only.
    public var scanned: [String]
    public var embedding: SegmentEmbedding?

    public init(
        segments: [SimilarSegment], threshold: Double, scanned: [String] = [],
        embedding: SegmentEmbedding? = nil
    ) {
        self.segments = segments
        self.threshold = threshold
        self.scanned = scanned
        self.embedding = embedding
    }

    /// Nil when the payload is not a select_similar result.
    public init?(resultRef: [String: JSONValue]) {
        guard case .array(let rawSegments)? = resultRef["segments"],
            let threshold = resultRef["threshold"]?.numberValue
        else { return nil }
        var segments: [SimilarSegment] = []
        segments.reserveCapacity(rawSegments.count)
        for raw in rawSegments {
            guard case .object(let fields) = raw,
                let t0 = fields["t0"]?.numberValue,
                let t1 = fields["t1"]?.numberValue,
                let distance = fields["distance"]?.numberValue
            else { continue }
            segments.append(
                SimilarSegment(
                    audioId: (fields["audioId"] ?? fields["audio_id"])?.stringValue,
                    t0: t0, t1: t1, distance: distance))
        }
        var scanned: [String] = []
        if case .array(let rawScanned)? = resultRef["scanned"] {
            scanned = rawScanned.compactMap(\.stringValue)
        }
        var embedding: SegmentEmbedding? = nil
        if case .object(let rawEmbedding)? = resultRef["embedding"] {
            var xy: [[Double]] = []
            if case .array(let rawXY)? = rawEmbedding["xy"] {
                for point in rawXY {
                    guard case .array(let pair) = point, pair.count >= 2,
                        let x = pair[0].numberValue, let y = pair[1].numberValue
                    else { continue }
                    xy.append([x, y])
                }
            }
            var cluster: [Int] = []
            if case .array(let rawCluster)? = rawEmbedding["cluster"] {
                cluster = rawCluster.compactMap { $0.numberValue.map { Int($0) } }
            }
            let nClusters = (rawEmbedding["nClusters"] ?? rawEmbedding["n_clusters"])?
                .numberValue.map { Int($0) }
            embedding = SegmentEmbedding(
                xy: xy, cluster: cluster, nClusters: nClusters ?? Set(cluster).count)
        }
        self.init(
            segments: segments, threshold: threshold, scanned: scanned, embedding: embedding)
    }
}

/// POST /onsets/repick response — the synchronous batch re-threshold
/// (docs/api.md). Times/strengths are parallel arrays.
public struct OnsetRepickResult: Codable, Sendable, Equatable {
    public struct Onsets: Codable, Sendable, Equatable {
        public var t: [Double]
        public var strength: [Double]

        public init(t: [Double], strength: [Double]) {
            self.t = t
            self.strength = strength
        }
    }

    public var audioId: String
    public var sourceKey: String
    public var n: Int
    public var onsets: Onsets

    public init(audioId: String, sourceKey: String, n: Int, onsets: Onsets) {
        self.audioId = audioId
        self.sourceKey = sourceKey
        self.n = n
        self.onsets = onsets
    }
}

/// POST /onsets/commit response — picked onsets materialized as point
/// annotations in one undo step.
public struct OnsetCommitResult: Codable, Sendable, Equatable {
    public var created: Int
    public var annotations: [AnnotationRecord]

    public init(created: Int, annotations: [AnnotationRecord]) {
        self.created = created
        self.annotations = annotations
    }
}
