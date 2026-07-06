// Colormap lookup tables for the Metal tile renderer (BUILD_SPEC §5.3):
// 256-entry RGBA8 LUTs for a 1D `.rgba8Unorm` texture, so palette switching
// is free (no tile reprocess). Ships viridis, magma, inferno, cividis, gray.
//
// Anchor data: the canonical 10-point discretizations of the matplotlib
// colormaps (accurate to 1/255 per channel), linearly interpolated to 256.
// These maps are perceptually smooth, so 10 anchors reproduce the full
// tables to within ~1-2 counts per channel. Gray is computed.

/// Spectrogram color palettes (BUILD_SPEC §5.3, colormap LUT).
public enum Colormap: String, CaseIterable, Sendable {
    case viridis, magma, inferno, cividis, gray

    /// 256-entry RGBA8 lookup table (1024 bytes, alpha always 255), ready
    /// for direct upload as a 1D texture. Index 0 = dbMin, 255 = dbMax.
    public func lut() -> [UInt8] {
        switch self {
        case .gray:
            var out = [UInt8]()
            out.reserveCapacity(1024)
            for k in 0..<256 {
                let v = UInt8(k)
                out.append(v)
                out.append(v)
                out.append(v)
                out.append(255)
            }
            return out
        case .viridis, .magma, .inferno, .cividis:
            return Self.interpolate(anchors: anchors)
        }
    }

    /// Anchor RGB triples as flat [R, G, B, R, G, B, ...] bytes, evenly
    /// spaced over 0..1. Empty for `gray` (computed, no anchors).
    var anchors: [UInt8] {
        switch self {
        case .viridis: Self.viridisAnchors
        case .magma: Self.magmaAnchors
        case .inferno: Self.infernoAnchors
        case .cividis: Self.cividisAnchors
        case .gray: []
        }
    }

    /// Linearly interpolate evenly-spaced RGB anchors to a 256-entry RGBA8
    /// table. Endpoints reproduce the first/last anchors exactly.
    static func interpolate(anchors: [UInt8]) -> [UInt8] {
        let count = anchors.count / 3
        precondition(count >= 2, "need at least two RGB anchors")
        var out = [UInt8]()
        out.reserveCapacity(1024)
        for k in 0..<256 {
            let pos = Double(k) / 255.0 * Double(count - 1)
            let i = min(Int(pos.rounded(.down)), count - 2)
            let frac = pos - Double(i)
            for c in 0..<3 {
                let a = Double(anchors[i * 3 + c])
                let b = Double(anchors[(i + 1) * 3 + c])
                out.append(UInt8((a + (b - a) * frac).rounded()))
            }
            out.append(255)
        }
        return out
    }

    // Canonical matplotlib 10-point discretizations (positions i/9).

    private static let viridisAnchors: [UInt8] = [
        0x44, 0x01, 0x54,  // #440154
        0x48, 0x28, 0x78,  // #482878
        0x3E, 0x49, 0x89,  // #3e4989
        0x31, 0x68, 0x8E,  // #31688e
        0x26, 0x82, 0x8E,  // #26828e
        0x1F, 0x9E, 0x89,  // #1f9e89
        0x35, 0xB7, 0x79,  // #35b779
        0x6E, 0xCE, 0x58,  // #6ece58
        0xB5, 0xDE, 0x2B,  // #b5de2b
        0xFD, 0xE7, 0x25,  // #fde725
    ]

    private static let magmaAnchors: [UInt8] = [
        0x00, 0x00, 0x04,  // #000004
        0x18, 0x0F, 0x3E,  // #180f3e
        0x45, 0x10, 0x77,  // #451077
        0x72, 0x1F, 0x81,  // #721f81
        0x9F, 0x2F, 0x7F,  // #9f2f7f
        0xCD, 0x40, 0x71,  // #cd4071
        0xF1, 0x60, 0x5D,  // #f1605d
        0xFD, 0x95, 0x67,  // #fd9567
        0xFE, 0xC9, 0x8D,  // #fec98d
        0xFC, 0xFD, 0xBF,  // #fcfdbf
    ]

    private static let infernoAnchors: [UInt8] = [
        0x00, 0x00, 0x04,  // #000004
        0x1B, 0x0C, 0x42,  // #1b0c42
        0x4B, 0x0C, 0x6B,  // #4b0c6b
        0x78, 0x1C, 0x6D,  // #781c6d
        0xA5, 0x2C, 0x60,  // #a52c60
        0xCF, 0x44, 0x46,  // #cf4446
        0xED, 0x69, 0x25,  // #ed6925
        0xFB, 0x9A, 0x06,  // #fb9a06
        0xF7, 0xD0, 0x3C,  // #f7d03c
        0xFC, 0xFF, 0xA4,  // #fcffa4
    ]

    private static let cividisAnchors: [UInt8] = [
        0x00, 0x20, 0x4D,  // #00204d
        0x00, 0x33, 0x6F,  // #00336f
        0x39, 0x48, 0x6B,  // #39486b
        0x57, 0x5D, 0x6D,  // #575d6d
        0x70, 0x71, 0x73,  // #707173
        0x8A, 0x87, 0x79,  // #8a8779
        0xA6, 0x9D, 0x75,  // #a69d75
        0xC4, 0xB5, 0x6C,  // #c4b56c
        0xE4, 0xCF, 0x5B,  // #e4cf5b
        0xFF, 0xEA, 0x46,  // #ffea46
    ]
}
