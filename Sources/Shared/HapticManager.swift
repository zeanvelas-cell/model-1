// HapticManager.swift
// PulseLite — Sources/Shared/HapticManager.swift
//
// Drop this file in Sources/Shared/
// No imports needed beyond UIKit (already transitive via SwiftUI)
//
// HOW TO USE:
//   HapticManager.lightTap()          ← any button press
//   HapticManager.success()           ← stream connected / key saved
//   HapticManager.error()             ← connection fail / bad key
//   HapticManager.goLive()            ← the big red GO LIVE button
//   HapticManager.selectionTick()     ← picker/slider changing
//   HapticManager.sliderRelease()     ← slider finger-up
//   HapticManager.drawerSnap()        ← slide drawer open/close

import UIKit

// MARK: - HapticManager

/// Central haptic dispatcher. All methods are no-ops when the user
/// has disabled haptics in PulseSettings, so it's safe to call everywhere.
enum HapticManager {

    // MARK: Private helpers

    private static func isEnabled() -> Bool {
        // Reads from the same AppGroup UserDefaults your settings model writes to.
        // Key must match whatever key PulseSettings saves enableUIHaptics under.
        let defaults = UserDefaults(suiteName: "group.com.pulselite.shared")
        return defaults?.bool(forKey: "enableUIHaptics") ?? true
    }

    private static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        guard isEnabled() else { return }
        let gen = UIImpactFeedbackGenerator(style: style)
        gen.prepare()
        gen.impactOccurred()
    }

    private static func notification(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        guard isEnabled() else { return }
        let gen = UINotificationFeedbackGenerator()
        gen.prepare()
        gen.notificationOccurred(type)
    }

    // MARK: Public API

    /// Light tap — every button, toggle, row tap.
    static func lightTap() {
        impact(.light)
    }

    /// Picker / slider value changed while dragging.
    static func selectionTick() {
        guard isEnabled() else { return }
        let gen = UISelectionFeedbackGenerator()
        gen.prepare()
        gen.selectionChanged()
    }

    /// Slider or stepper released — value locked in.
    static func sliderRelease() {
        impact(.rigid)
    }

    /// Slide drawer open or close snap.
    static func drawerSnap() {
        impact(.soft)
    }

    /// The Go Live / red broadcast button — big moment.
    static func goLive() {
        impact(.heavy)
    }

    /// Stream connected, key saved, recording started — positive outcome.
    static func success() {
        notification(.success)
    }

    /// Connection failed, bad key, RTMP error — negative outcome.
    static func error() {
        notification(.error)
    }

    /// Stream disconnected cleanly (not an error — neutral signal).
    static func streamEnded() {
        notification(.warning)
    }

    /// Dual mic pre-lock armed / disarmed.
    static func micLock() {
        impact(.medium)
    }

    /// Privacy shield toggled on.
    static func privacyShieldOn() {
        // Double tap feel — shield slamming closed
        impact(.heavy)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            impact(.rigid)
        }
    }

    /// Privacy shield toggled off.
    static func privacyShieldOff() {
        impact(.medium)
    }
}

// MARK: - SwiftUI convenience (.sensoryFeedback is iOS 17+ only)
// If you want the SwiftUI modifier style instead, add these View extensions:
//
// Usage in SwiftUI:
//   Button("Go Live") { viewModel.startBroadcast() }
//       .hapticOnTap(.goLive)
//
// extension View {
//     func hapticOnTap(_ kind: HapticKind) -> some View { ... }
// }
//
// But calling HapticManager directly from .onTapGesture / button action
// is simpler and works everywhere. Stick to that.
