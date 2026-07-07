import Foundation
import Testing

@testable import IndraKitCore

@Suite("MagicSelection")
struct MagicSelectionTests {
    /// Wire-shaped result_ref (docs/api.md POST /select/magic), decoded the
    /// way JobInfo.resultRef actually arrives: through IndraJSON's
    /// convertFromSnakeCase, which also rewrites dictionary keys.
    func decodeResultRef(_ json: String) throws -> [String: JSONValue] {
        try IndraJSON.decoder().decode([String: JSONValue].self, from: Data(json.utf8))
    }

    let fixture = """
        {"selection_id": "abc123", "lod": 2, "seconds_per_column": 0.0853,
         "hz_per_bin": 11.72, "cells": 42, "seed_level_db": -38.5,
         "bounds": {"t0": 1.0, "t1": 2.0, "f0": 100.0, "f1": 500.0},
         "ribbons": [
           {"t0": 1.0, "t1": 1.5, "intervals": [[100.0, 200.0], [400.0, 500.0]]},
           {"t0": 1.5, "t1": 2.0, "intervals": [[120.0, 220.0]]}
         ]}
        """

    @Test func parsesResultRefWithConvertedKeys() throws {
        let ref = try decodeResultRef(fixture)
        let selection = try #require(MagicSelection(resultRef: ref))
        #expect(selection.selectionId == "abc123")
        #expect(selection.cells == 42)
        #expect(selection.seedLevelDb == -38.5)
        #expect(selection.ribbons.count == 2)
        #expect(selection.ribbons[0].intervals.count == 2)
        #expect(selection.ribbons[0].intervals[1] == FrequencyInterval(fLo: 400, fHi: 500))
        #expect(selection.ribbons[1].t0 == 1.5)
    }

    @Test func rejectsNonMagicResultRef() throws {
        let ref = try decodeResultRef("{\"audio_id\": \"x\", \"already_imported\": false}")
        #expect(MagicSelection(resultRef: ref) == nil)
    }

    @Test func malformedRibbonEntriesAreSkippedNotFatal() throws {
        let ref = try decodeResultRef(
            """
            {"selection_id": "s", "ribbons": [
              {"t0": 0.0, "t1": 0.5, "intervals": [[10.0, 20.0], [30.0]]},
              "garbage",
              {"t0": 0.5, "intervals": []}
            ]}
            """)
        let selection = try #require(MagicSelection(resultRef: ref))
        #expect(selection.ribbons.count == 1)
        #expect(selection.ribbons[0].intervals == [FrequencyInterval(fLo: 10, fHi: 20)])
    }

    @Test func rectsMapRibbonsThroughViewportMath() throws {
        let selection = try #require(MagicSelection(resultRef: decodeResultRef(fixture)))
        // 10 s × 1000 px → 100 px/s; 0..1000 Hz over 500 px (linear).
        let viewport = Viewport(t0: 0, t1: 10, f0: 0, f1: 1000, width: 1000, height: 500)
        let rects = selection.rects(in: viewport)
        #expect(rects.count == 3)
        // First slice, interval 100–200 Hz: x = t0 · 100, y from freqToY(200).
        let first = rects[0]
        #expect(abs(first.x - 100) < 1e-9)
        #expect(abs(first.width - 50) < 1e-9)
        #expect(abs(first.y - 400) < 1e-9)  // (1 - 200/1000) · 500
        #expect(abs(first.height - 50) < 1e-9)  // 100 Hz · 0.5 px/Hz
    }

    @Test func rectsDropSlicesAndIntervalsOutsideTheViewport() throws {
        let selection = try #require(MagicSelection(resultRef: decodeResultRef(fixture)))
        // Time window past every ribbon.
        let late = Viewport(t0: 5, t1: 10, f0: 0, f1: 1000, width: 1000, height: 500)
        #expect(selection.rects(in: late).isEmpty)
        // Frequency window above every interval (max fHi is 500).
        let high = Viewport(t0: 0, t1: 10, f0: 600, f1: 1000, width: 1000, height: 500)
        #expect(selection.rects(in: high).isEmpty)
    }
}
