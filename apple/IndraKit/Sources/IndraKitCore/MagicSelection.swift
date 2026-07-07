// Magic-selection ribbons (docs/api.md POST /select/magic): the backend's
// region grow returns per-time-slice frequency intervals
// `ribbons: [{ t0, t1, intervals: [[f_lo, f_hi], …] }, …]` in the job's
// result_ref. This file models that payload, parses it out of the decoded
// `[String: JSONValue]` result_ref, and converts ribbons to screen rectangles
// for the overlay layer (BUILD_SPEC §5.3 overlays). Pure — Linux-tested.
//
// Key-name note: JobInfo.resultRef is decoded with IndraJSON's
// convertFromSnakeCase, which rewrites DICTIONARY keys too — so the wire's
// `selection_id` arrives here as `selectionId`, `seed_level_db` as
// `seedLevelDb`, etc. Ribbon-level keys (`t0`, `t1`, `intervals`) have no
// underscores and pass through unchanged.

/// One closed frequency interval of a ribbon slice, Hz.
public struct FrequencyInterval: Sendable, Equatable {
    public var fLo: Double
    public var fHi: Double

    public init(fLo: Double, fHi: Double) {
        self.fLo = min(fLo, fHi)
        self.fHi = max(fLo, fHi)
    }
}

/// One time slice of a magic selection: the frequency intervals selected
/// within `[t0, t1)` seconds.
public struct MagicRibbon: Sendable, Equatable {
    public var t0: Double
    public var t1: Double
    public var intervals: [FrequencyInterval]

    public init(t0: Double, t1: Double, intervals: [FrequencyInterval]) {
        self.t0 = t0
        self.t1 = t1
        self.intervals = intervals
    }
}

/// Decoded magic-selection result. `selectionId` is the cache key — pass it
/// straight to `POST /audition` to hear the selection (docs/api.md).
public struct MagicSelection: Sendable, Equatable {
    public var selectionId: String
    public var ribbons: [MagicRibbon]
    /// Selected time-frequency cells (diagnostic, from result_ref).
    public var cells: Int?
    public var seedLevelDb: Double?

    public init(
        selectionId: String, ribbons: [MagicRibbon], cells: Int? = nil,
        seedLevelDb: Double? = nil
    ) {
        self.selectionId = selectionId
        self.ribbons = ribbons
        self.cells = cells
        self.seedLevelDb = seedLevelDb
    }

    /// Parse a magic_select job's result_ref. Accepts BOTH key spellings —
    /// snake_case as on the wire, and camelCase as produced when the payload
    /// went through IndraJSON's convertFromSnakeCase (which also rewrites
    /// dictionary keys, a Foundation quirk that varies by decode path).
    /// Nil when the payload is not a magic-selection result.
    public init?(resultRef: [String: JSONValue]) {
        func field(_ camel: String, _ snake: String) -> JSONValue? {
            resultRef[camel] ?? resultRef[snake]
        }
        guard let id = field("selectionId", "selection_id")?.stringValue,
            case .array(let rawRibbons)? = resultRef["ribbons"]
        else { return nil }
        var ribbons: [MagicRibbon] = []
        ribbons.reserveCapacity(rawRibbons.count)
        for raw in rawRibbons {
            guard case .object(let slice) = raw,
                let t0 = slice["t0"]?.numberValue,
                let t1 = slice["t1"]?.numberValue,
                case .array(let rawIntervals)? = slice["intervals"]
            else { continue }
            var intervals: [FrequencyInterval] = []
            intervals.reserveCapacity(rawIntervals.count)
            for pair in rawIntervals {
                guard case .array(let bounds) = pair, bounds.count >= 2,
                    let lo = bounds[0].numberValue, let hi = bounds[1].numberValue
                else { continue }
                intervals.append(FrequencyInterval(fLo: lo, fHi: hi))
            }
            ribbons.append(MagicRibbon(t0: t0, t1: t1, intervals: intervals))
        }
        self.init(
            selectionId: id, ribbons: ribbons,
            cells: (resultRef["cells"]?.numberValue).map { Int($0) },
            seedLevelDb: field("seedLevelDb", "seed_level_db")?.numberValue)
    }

    /// Platform-neutral rectangle in viewport pixel space (origin top-left,
    /// matching `Viewport` screen conventions). The overlay maps to CGRect.
    public struct Rect: Sendable, Equatable {
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double

        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }
    }

    /// Screen rectangles for the ribbons visible in `viewport`, one per
    /// (slice × interval). Slices outside the visible time range and
    /// intervals outside the visible frequency range are dropped; edges are
    /// NOT clamped (the overlay clips).
    public func rects(in viewport: Viewport, scale: FrequencyScale = .linear) -> [Rect] {
        var out: [Rect] = []
        for ribbon in ribbons {
            guard ribbon.t1 > viewport.t0, ribbon.t0 < viewport.t1 else { continue }
            let x0 = viewport.timeToX(ribbon.t0)
            let x1 = viewport.timeToX(ribbon.t1)
            for interval in ribbon.intervals {
                guard interval.fHi > viewport.f0, interval.fLo < viewport.f1 else { continue }
                let yTop = viewport.freqToY(interval.fHi, scale: scale)
                let yBottom = viewport.freqToY(interval.fLo, scale: scale)
                out.append(
                    Rect(
                        x: x0, y: yTop, width: max(x1 - x0, 0),
                        height: max(yBottom - yTop, 0)))
            }
        }
        return out
    }
}
