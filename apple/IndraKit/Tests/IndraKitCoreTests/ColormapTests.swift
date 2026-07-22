import Testing

@testable import IndraKitCore

@Suite("Colormap")
struct ColormapTests {
    /// Rec. 709 luma of LUT entry `i`.
    func luma(_ lut: [UInt8], _ i: Int) -> Double {
        0.2126 * Double(lut[i * 4]) + 0.7152 * Double(lut[i * 4 + 1])
            + 0.0722 * Double(lut[i * 4 + 2])
    }

    @Test func allCasesPresent() {
        #expect(Colormap.allCases.count == 5)
        #expect(Colormap(rawValue: "viridis") == .viridis)
        #expect(Colormap(rawValue: "gray") == .gray)
        #expect(Colormap(rawValue: "jet") == nil)
    }

    @Test(arguments: Colormap.allCases)
    func lutIs256RGBA8(colormap: Colormap) {
        let lut = colormap.lut()
        #expect(lut.count == 1024)
    }

    @Test(arguments: Colormap.allCases)
    func alphaIsOpaqueEverywhere(colormap: Colormap) {
        let lut = colormap.lut()
        for i in 0..<256 {
            #expect(lut[i * 4 + 3] == 255)
        }
    }

    @Test(arguments: [Colormap.viridis, .magma, .inferno, .cividis])
    func endpointsMatchAnchors(colormap: Colormap) {
        let lut = colormap.lut()
        let anchors = colormap.anchors
        #expect(anchors.count >= 6)
        #expect(anchors.count % 3 == 0)
        // First LUT entry == first anchor, last entry == last anchor.
        #expect(lut[0] == anchors[0])
        #expect(lut[1] == anchors[1])
        #expect(lut[2] == anchors[2])
        #expect(lut[1020] == anchors[anchors.count - 3])
        #expect(lut[1021] == anchors[anchors.count - 2])
        #expect(lut[1022] == anchors[anchors.count - 1])
    }

    @Test func viridisKnownEndpoints() {
        let lut = Colormap.viridis.lut()
        // Canonical matplotlib viridis: #440154 → #fde725.
        #expect(lut[0] == 0x44)
        #expect(lut[1] == 0x01)
        #expect(lut[2] == 0x54)
        #expect(lut[1020] == 0xFD)
        #expect(lut[1021] == 0xE7)
        #expect(lut[1022] == 0x25)
    }

    @Test func grayIsIdentityRamp() {
        let lut = Colormap.gray.lut()
        for i in 0..<256 {
            #expect(lut[i * 4] == UInt8(i))
            #expect(lut[i * 4 + 1] == UInt8(i))
            #expect(lut[i * 4 + 2] == UInt8(i))
        }
    }

    @Test func grayLumaStrictlyIncreasing() {
        let lut = Colormap.gray.lut()
        for i in 1..<256 {
            #expect(luma(lut, i) > luma(lut, i - 1))
        }
    }

    @Test func viridisLumaNonDecreasingWithinTolerance() {
        // Viridis is designed with monotonically increasing lightness; allow
        // ±2 counts of quantization wiggle.
        let lut = Colormap.viridis.lut()
        for i in 1..<256 {
            #expect(luma(lut, i) >= luma(lut, i - 1) - 2)
        }
    }

    @Test(arguments: [Colormap.viridis, .magma, .inferno, .cividis])
    func lutSpansDarkToBright(colormap: Colormap) {
        // All four maps run dark → bright overall.
        let lut = colormap.lut()
        #expect(luma(lut, 255) > luma(lut, 0) + 100)
    }

    @Test func interpolationIsPiecewiseLinear() {
        // Two anchors (black → white) must reproduce the gray ramp within
        // rounding.
        let lut = Colormap.interpolate(anchors: [0, 0, 0, 255, 255, 255])
        #expect(lut.count == 1024)
        for i in 0..<256 {
            #expect(lut[i * 4] == UInt8(i))
            #expect(lut[i * 4 + 1] == UInt8(i))
            #expect(lut[i * 4 + 2] == UInt8(i))
            #expect(lut[i * 4 + 3] == 255)
        }
    }
}
