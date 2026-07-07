import Foundation
import Testing

@testable import IndraKitCore

@Suite("FeatureTable")
struct FeatureTableTests {
    @Test func decodesBucketsWithVerbatimColumnKeys() throws {
        // Snake_case column names must survive: FeatureTable.decode uses a
        // plain decoder precisely so "h_entropy" is not mangled to "hEntropy".
        let json = """
            {"audio_id": "a1", "kind": "template_harmonicity_mpt",
             "cache_key": "deadbeef", "params": {"top_k": 32}, "sr": 48000,
             "n": 4200, "t0": 0.0, "t1": 90.0,
             "columns": ["value", "h_entropy"],
             "buckets": {
               "value": {"t": [1.0, 3.0], "min": [0.1, 0.2], "max": [0.5, 0.6]},
               "h_entropy": {"t": [1.0, 3.0], "min": [2.0, 2.1], "max": [3.0, 3.2]}
             }}
            """
        let table = try FeatureTable.decode(Data(json.utf8))
        #expect(table.audioId == "a1")
        #expect(table.kind == "template_harmonicity_mpt")
        #expect(table.cacheKey == "deadbeef")
        #expect(table.n == 4200)
        #expect(table.columns == ["value", "h_entropy"])
        #expect(table.values == nil)
        let buckets = try #require(table.buckets)
        #expect(Set(buckets.keys) == Set(table.columns))
        let entropy = try #require(buckets["h_entropy"])
        #expect(entropy.t == [1.0, 3.0])
        #expect(entropy.min == [2.0, 2.1])
        #expect(entropy.max == [3.0, 3.2])
    }

    @Test func decodesRawValuesMode() throws {
        let json = """
            {"audio_id": "a1", "kind": "roughness_mpt", "cache_key": null,
             "n": 3, "columns": ["value"],
             "values": {"time_s": [0.0, 0.02, 0.04], "value": [1.0, 2.0, 3.0]}}
            """
        let table = try FeatureTable.decode(Data(json.utf8))
        #expect(table.buckets == nil)
        let values = try #require(table.values)
        #expect(values["time_s"] == [0.0, 0.02, 0.04])
        #expect(values["value"] == [1.0, 2.0, 3.0])
    }

    @Test func bucketSeriesFeedsCurveLaneDownsampling() throws {
        // The render path folds server buckets back through CurveLane by
        // feeding mins and maxs as two sample sets over the same times.
        let series = FeatureBucketSeries(
            t: [1.0, 3.0, 5.0], min: [0.0, -1.0, 0.5], max: [2.0, 1.0, 0.5])
        let viewport = Viewport(t0: 0, t1: 10, f0: 0, f1: 24000, width: 10, height: 500)
        let buckets = CurveLane.minMaxBuckets(
            values: (series.min + series.max).map { Float($0) },
            times: series.t + series.t,
            viewport: viewport)
        #expect(buckets.count == 10)
        #expect(buckets[1] == CurveBucket(min: 0.0, max: 2.0))
        #expect(buckets[3] == CurveBucket(min: -1.0, max: 1.0))
        #expect(buckets[5] == CurveBucket(min: 0.5, max: 0.5))
        #expect(buckets[0] == nil)
    }
}
