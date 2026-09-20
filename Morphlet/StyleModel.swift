import Foundation
import Combine

/// User-tunable style knobs for the fold effect, persisted across launches.
///
/// `@AppStorage` is a `DynamicProperty` meant for use inside SwiftUI `View`
/// structs — it does not hook into a class's `objectWillChange`. Since this
/// needs to live in a plain `ObservableObject` (so the app coordinator and
/// menu bar / settings UI can all share one instance), each property is
/// backed manually by `UserDefaults` via `didSet`, which gives the same
/// persistence guarantee `@AppStorage` would.
@MainActor
final class StyleModel: ObservableObject {
    private enum Keys {
        static let enabled = "enabled"
        static let silk = "silk"
        static let frost = "frost"
        static let shade = "shade"
        static let startAngle = "startAngle"
        static let closedAngle = "closedAngle"
    }

    /// Master on/off switch for the effect.
    @Published var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Keys.enabled) }
    }

    /// 0...1 tilt (perspective) multiplier.
    @Published var silk: Double {
        didSet { UserDefaults.standard.set(silk, forKey: Keys.silk) }
    }

    /// 0...1 blur ("liquid glass") multiplier.
    @Published var frost: Double {
        didSet { UserDefaults.standard.set(frost, forKey: Keys.frost) }
    }

    /// 0...1 darkening multiplier.
    @Published var shade: Double {
        didSet { UserDefaults.standard.set(shade, forKey: Keys.shade) }
    }

    /// Lid angle, in degrees, at/above which the effect is fully off.
    @Published var startAngle: Double {
        didSet { UserDefaults.standard.set(startAngle, forKey: Keys.startAngle) }
    }

    /// Lid angle, in degrees, at/below which the effect is fully on.
    @Published var closedAngle: Double {
        didSet { UserDefaults.standard.set(closedAngle, forKey: Keys.closedAngle) }
    }

    init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [
            Keys.enabled: true,
            Keys.silk: 1.0,
            Keys.frost: 1.0,
            Keys.shade: 1.0,
            // Tuned by hand rather than chosen for roundness, replacing the
            // original 100/15. The fold begins a little before the lid reaches
            // a right angle and is fully closed well before the hinge bottoms
            // out, so the effect finishes while there is still screen to see.
            Keys.startAngle: 92.0,
            Keys.closedAngle: 30.0,
        ])

        isEnabled = defaults.bool(forKey: Keys.enabled)
        silk = defaults.double(forKey: Keys.silk)
        frost = defaults.double(forKey: Keys.frost)
        shade = defaults.double(forKey: Keys.shade)
        startAngle = defaults.double(forKey: Keys.startAngle)
        closedAngle = defaults.double(forKey: Keys.closedAngle)
    }

    /// Maps a raw lid angle (degrees) to an effect progress in 0...1.
    ///
    /// `progress == 0` while the lid is at or above `startAngle` (open),
    /// `progress == 1` at or below `closedAngle` (nearly shut), and linear
    /// in between. Always clamped to 0...1, even if the two angles are
    /// misconfigured (e.g. equal or inverted).
    func progress(forAngle angle: Double) -> Double {
        let start = startAngle
        let closed = closedAngle

        guard start > closed else {
            // Degenerate configuration — fall back to a hard threshold.
            return angle <= closed ? 1 : 0
        }

        if angle >= start { return 0 }
        if angle <= closed { return 1 }

        let raw = (start - angle) / (start - closed)
        return min(max(raw, 0), 1)
    }
}
