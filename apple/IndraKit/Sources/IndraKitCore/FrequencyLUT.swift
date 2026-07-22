// Frequency-axis remap table for the Metal tile renderer (BUILD_SPEC §5.3,
// "frequency-axis LUT"): one entry per output row mapping screen y → source
// bin, so linear/log display scaling is a 1D texture lookup in the fragment
// shader instead of per-fragment log math. Rebuilt on viewport or scale-mode
// change (a few KB — cheap). Pure math, Linux-tested; the renderer only
// uploads the floats.

import Foundation

public enum FrequencyLUT {
    /// Default table length; plenty for sub-pixel accuracy on a ~1000 px-tall
    /// canvas because the shader samples the table with linear filtering.
    public static let defaultCount = 1024

    /// `count` bin fractions, top row first (index 0 = screen y 0 = high
    /// frequencies, matching `Viewport.freqToY`). Each entry is the texel-
    /// center coordinate `(bin + 0.5) / nBins` of the STFT bin shown at that
    /// row, clamped to [0, 1] (frequencies outside the pyramid pin to the
    /// edge bins). Bin k covers `k * sr / nFft` Hz (TilePlanner convention).
    public static func binFractions(
        viewport: Viewport,
        scale: FrequencyScale,
        manifest: SpecManifest,
        sr: Int,
        count: Int = defaultCount
    ) -> [Float] {
        guard count > 0, sr > 0, manifest.nFft > 0, manifest.nBins > 0 else { return [] }
        let hzToBin = Double(manifest.nFft) / Double(sr)
        let nBins = Double(manifest.nBins)
        var out = [Float]()
        out.reserveCapacity(count)
        for row in 0..<count {
            // Row center in viewport pixel space.
            let y = (Double(row) + 0.5) / Double(count) * viewport.height
            let hz = viewport.yToFreq(y, scale: scale)
            let bin = min(max(hz * hzToBin, 0), nBins - 1)
            out.append(Float((bin + 0.5) / nBins))
        }
        return out
    }
}
