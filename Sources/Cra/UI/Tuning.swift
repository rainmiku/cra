import AppKit
import Observation

/// Rendering constants calibrated against Arc. They can be changed at run time
/// for calibration with `cra://debug?lift=0.15&liftInactive=0.93&alpha=1&toolbar=0.4&material=21`.
@MainActor @Observable
final class CraTuning {
    static let shared: CraTuning = {
        let t = CraTuning()
        // CRA_TUNING="lift=0.1&alpha=1&material=21" configures a test instance at launch
        // (cra://debug only works through CRA_COMMAND_FILE).
        if let env = ProcessInfo.processInfo.environment["CRA_TUNING"] {
            var q: [String: String] = [:]
            for pair in env.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
                if kv.count == 2 { q[kv[0]] = kv[1] }
            }
            t.apply(q)
        }
        return t
    }()

    /// White layer over the behind-window blur (active / inactive window).
    /// 0.12 re-fitted on 24 Oct (evening) against Arc 1.170 live on the same desktop; 0.03 ran 6–12/255 too dark.
    /// Backdrop-layer path (light vibrant themes), solved from Arc 1.170 over white and
    /// black: out = a·G + (1−a)·[L·255 + (1−L)(1−D)·backdrop]. Measured fit (25 Oct):
    /// a 0.43→0.59, L 0.16→0.18, D 0.19 lands within ±5 of Arc's 123/116/83→159/129/95
    /// over black and 204/197/164→218/188/154 over white at five heights.
    /// Re-fitted 25 Oct 11:30 with the backdrop actually blurring (the earlier fit ran while
    /// the layer passed the backdrop unblurred): Arc 1.170 active, Victor theme, same screen,
    /// upper sidebar: 184/177/137 over 50 % grey stripes, 213/206/167 over white, i.e. k ≈ 0.21
    /// and ≈158/151/111 over black. Cra was k 0.31 and 145/128/92; lift 0.35→0.37 with dim 0.36
    /// measured k 0.21 and 159/149/114 over black, 185/175/140 over stripes, 213/203/168 over white
    /// (Arc: 158/151/111, 184/177/137, 213/206/167).
    var liftActive: Double = 0.35
    var liftActiveBottom: Double = 0.37
    var blurDim: Double = 0.36
    /// Inactive window: Arc drops the backdrop entirely and shows a flat, slightly darker
    /// sidebar (measured 25 Oct: 149/143/104 at the top over any backdrop, k = 0). Cra used to
    /// lift to 0.75 white with no dim, which flipped the sidebar between a dark translucent
    /// and a pale opaque look on every app switch. Full dim + 0.28 lift lands on Arc's colour.
    var liftInactive: Double = 0.28
    var blurDimInactive: Double = 1.0
    /// Multiplier on the theme's gradient opacity (vibrant themes only).
    var gradientAlphaScale: Double = 1
    /// Separate multipliers on the top and bottom gradient opacity (calibration only).
    var gradientAlphaTopScale: Double = 1
    var gradientAlphaBottomScale: Double = 1
    /// Black overlay that makes the toolbar band out of the space background.
    var toolbarAlpha: Double = 0.40
    var material: NSVisualEffectView.Material = .hudWindow
    var forceActiveBlur = false
    var darkBlur = true

    func apply(_ q: [String: String]) {
        if let v = q["lift"].flatMap(Double.init) { liftActive = v }
        if let v = q["liftBottom"].flatMap(Double.init) { liftActiveBottom = v }
        if let v = q["dim"].flatMap(Double.init) { blurDim = v }
        if let v = q["liftInactive"].flatMap(Double.init) { liftInactive = v }
        if let v = q["dimInactive"].flatMap(Double.init) { blurDimInactive = v }
        if let v = q["alpha"].flatMap(Double.init) { gradientAlphaScale = v }
        if let v = q["alphaTop"].flatMap(Double.init) { gradientAlphaTopScale = v }
        if let v = q["alphaBottom"].flatMap(Double.init) { gradientAlphaBottomScale = v }
        if let v = q["toolbar"].flatMap(Double.init) { toolbarAlpha = v }
        if let v = q["material"].flatMap(Int.init), let m = NSVisualEffectView.Material(rawValue: v) { material = m }
        if let v = q["state"] { forceActiveBlur = v == "active" }
        if let v = q["appearance"] { darkBlur = v != "light" }
    }
}
