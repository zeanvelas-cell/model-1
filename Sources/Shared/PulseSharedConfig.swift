import UIKit
import Security
import os

public enum StreamAspectMode: String, Codable, CaseIterable, Sendable {
    case landscape16x9 = "landscape_16_9"
    case verticalShorts9x16 = "shorts_9_16"

    public var displayTitle: String {
        switch self {
        case .landscape16x9: return "16:9 Horizontal Video"
        case .verticalShorts9x16: return "9:16 Vertical Shorts"
        }
    }
}

public enum ShortsGameCropPreset: String, Codable, CaseIterable, Sendable {
    case fullWidthNoCrop = "full_width_19_5_9"
    case slightHUDCrop14x9 = "slight_crop_14_9"
    case fullCenterCrop16x9 = "center_crop_16_9"

    public var displayTitle: String {
        switch self {
        case .fullWidthNoCrop: return "Full Width (0% Side Cut • Full HUD)"
        case .slightHUDCrop14x9: return "Balanced Shorts (~6% Side Cut)"
        case .fullCenterCrop16x9: return "16:9 Center Fill (~9% Side Cut)"
        }
    }

    public var targetAspectRatio: CGFloat? {
        switch self {
        case .fullWidthNoCrop: return nil
        case .slightHUDCrop14x9: return 17.5 / 9.0
        case .fullCenterCrop16x9: return 16.0 / 9.0
        }
    }
}

public enum StreamQualityTier: String, Codable, CaseIterable, Sendable {
    case safe720p = "720p_safe"
    case hd1080p = "1080p_high"
    case nativeScreen = "native_screen"

    public var displayTitle: String {
        switch self {
        case .safe720p: return "720p (Cool & Safe)"
        case .hd1080p: return "1080p Full HD"
        case .nativeScreen: return "Native Screen Ratio"
        }
    }
}

public enum InGameVoiceChatMode: String, Codable, CaseIterable, Sendable {
    case preLockDualMic = "prelock_dual_mic"
    case squadOnlyGameMic = "squad_only_game_mic"

    public var displayTitle: String {
        switch self {
        case .preLockDualMic: return "Dual Mic (Pre-Lock Before Match + Wired/BT)"
        case .squadOnlyGameMic: return "Squad Mic Only (Game Owns Mic 100%)"
        }
    }
}

public struct YouTubeAccount: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var channelTitle: String
    public var primaryStreamKey: String

    public init(
        id: String = UUID().uuidString,
        channelTitle: String,
        primaryStreamKey: String
    ) {
        self.id = id
        self.channelTitle = channelTitle
        self.primaryStreamKey = primaryStreamKey
    }
}

public struct BroadcastDiagnostics: Codable, Equatable, Sendable {
    public var minAvailableMemoryMB: Int = 0
    public var framesEncoded: Int = 0
    public var framesDropped: Int = 0
    public var lastStatusMessage: String = "Ready"
    public var lastUpdatedTimestamp: String = "—"

    public init() {}
}

public struct PulseSettings: Codable, Equatable, Sendable {
    public var aspectMode: StreamAspectMode = .landscape16x9
    public var shortsCropPreset: ShortsGameCropPreset = .slightHUDCrop14x9
    public var qualityTier: StreamQualityTier = .safe720p
    public var voiceChatMode: InGameVoiceChatMode = .preLockDualMic
    public var targetFPS: Int = 30
    public var targetBitrateKbps: Int = 4500
    public var enableStaticGapOverlay: Bool = true
    public var shortsGameVerticalOffset: CGFloat = 0.0
    public var gapOverlayOpacity: CGFloat = 1.0
    public var enableLocalRecording: Bool = false
    public var enableThermalAutoGuard: Bool = true
    public var enableUIHaptics: Bool = true
    public var includeMicrophoneAudio: Bool = true
    public var enablePrivacyShieldBanner: Bool = false
    public var suppressHeavyModeWarning: Bool = false
    public var nativeScreenLongEdgePx: Int = 1664
    public var nativeScreenShortEdgePx: Int = 768
    public var ingestServerURL: String = "rtmps://a.rtmps.youtube.com:443/live2"

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        aspectMode = try c.decodeIfPresent(StreamAspectMode.self, forKey: .aspectMode) ?? .landscape16x9
        shortsCropPreset = try c.decodeIfPresent(ShortsGameCropPreset.self, forKey: .shortsCropPreset) ?? .slightHUDCrop14x9
        qualityTier = try c.decodeIfPresent(StreamQualityTier.self, forKey: .qualityTier) ?? .safe720p
        voiceChatMode = try c.decodeIfPresent(InGameVoiceChatMode.self, forKey: .voiceChatMode) ?? .preLockDualMic
        targetFPS = try c.decodeIfPresent(Int.self, forKey: .targetFPS) ?? 30
        targetBitrateKbps = try c.decodeIfPresent(Int.self, forKey: .targetBitrateKbps) ?? 4500
        enableStaticGapOverlay = try c.decodeIfPresent(Bool.self, forKey: .enableStaticGapOverlay) ?? true
        shortsGameVerticalOffset = try c.decodeIfPresent(CGFloat.self, forKey: .shortsGameVerticalOffset) ?? 0.0
        gapOverlayOpacity = try c.decodeIfPresent(CGFloat.self, forKey: .gapOverlayOpacity) ?? 1.0
        enableLocalRecording = try c.decodeIfPresent(Bool.self, forKey: .enableLocalRecording) ?? false
        enableThermalAutoGuard = try c.decodeIfPresent(Bool.self, forKey: .enableThermalAutoGuard) ?? true
        enableUIHaptics = try c.decodeIfPresent(Bool.self, forKey: .enableUIHaptics) ?? true
        includeMicrophoneAudio = try c.decodeIfPresent(Bool.self, forKey: .includeMicrophoneAudio) ?? true
        enablePrivacyShieldBanner = try c.decodeIfPresent(Bool.self, forKey: .enablePrivacyShieldBanner) ?? false
        suppressHeavyModeWarning = try c.decodeIfPresent(Bool.self, forKey: .suppressHeavyModeWarning) ?? false
        nativeScreenLongEdgePx = try c.decodeIfPresent(Int.self, forKey: .nativeScreenLongEdgePx) ?? 1664
        nativeScreenShortEdgePx = try c.decodeIfPresent(Int.self, forKey: .nativeScreenShortEdgePx) ?? 768
        ingestServerURL = try c.decodeIfPresent(String.self, forKey: .ingestServerURL) ?? "rtmps://a.rtmps.youtube.com:443/live2"
    }

    public var resolvedCanvasSize: CGSize {
        switch (aspectMode, qualityTier) {
        case (.verticalShorts9x16, .safe720p):
            return CGSize(width: 720, height: 1280)
        case (.verticalShorts9x16, .hd1080p):
            return CGSize(width: 1080, height: 1920)
        case (.verticalShorts9x16, .nativeScreen):
            let w = max(540, (nativeScreenShortEdgePx / 2) * 2)
            let h = max(960, (nativeScreenLongEdgePx / 2) * 2)
            return CGSize(width: w, height: h)
        case (.landscape16x9, .safe720p):
            return CGSize(width: 1280, height: 720)
        case (.landscape16x9, .hd1080p):
            return CGSize(width: 1920, height: 1080)
        case (.landscape16x9, .nativeScreen):
            let w = max(960, (nativeScreenLongEdgePx / 2) * 2)
            let h = max(540, (nativeScreenShortEdgePx / 2) * 2)
            return CGSize(width: w, height: h)
        }
    }
}

public enum AppGroupBridge {
    private static let fallbackGroupId = "group.com.pulselite.shared"
    private static let settingsKey = "pulse_hardware_settings_v8"
    private static let accountsMetadataKey = "pulse_yt_accounts_meta_v8"
    private static let activeAccountIdKey = "pulse_active_yt_id_v8"
    private static let diagnosticsKey = "pulse_ext_diagnostics_v8"
    private static let keychainService = "com.pulselite.streamkeys.v8"
    public static let reloadNotificationName = "com.pulselite.shared.reloadSettings"
    public static let reloadOverlaysNotificationName = "com.pulselite.shared.reloadOverlays"

    private static let rawTopFilename = "raw_top_gap.png"
    private static let rawBottomFilename = "raw_bottom_gap.png"
    private static let rawLandscapeFilename = "raw_landscape_overlay.png"
    private static let bakedShortsFilename = "prebaked_shorts_9x16.png"
    private static let bakedLandscapeFilename = "prebaked_landscape_16x9.png"
    public static let recordingFilename = "PulseLite_LastBroadcast.mp4"

    public static var resolvedGroupId: String {
        if let altGroups = Bundle.main.object(forInfoDictionaryKey: "ALTSharedAppGroups") as? [String],
           let firstAlt = altGroups.first, !firstAlt.isEmpty {
            return firstAlt
        }
        if let plistGroup = Bundle.main.object(forInfoDictionaryKey: "PulseAppGroupID") as? String,
           !plistGroup.isEmpty {
            return plistGroup
        }
        return fallbackGroupId
    }

    public static var groupAvailable: Bool {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: resolvedGroupId) != nil
    }

    public static var activeDefaults: UserDefaults {
        if groupAvailable, let shared = UserDefaults(suiteName: resolvedGroupId) {
            return shared
        }
        return UserDefaults.standard
    }

    public static var activeStorageURL: URL? {
        if let groupURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: resolvedGroupId) {
            return groupURL
        }
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    }

    public static func postDarwinNotification(named name: String) {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(
            center,
            CFNotificationName(name as CFString),
            nil,
            nil,
            true
        )
    }

    // MARK: - Keychain Stream Key Helper
    private static func saveKeyToKeychain(accountId: String, streamKey: String) {
        guard let data = streamKey.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: accountId
        ]
        SecItemDelete(query as CFDictionary)
        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    private static func loadKeyFromKeychain(accountId: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: accountId,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func deleteKeyFromKeychain(accountId: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: accountId
        ]
        SecItemDelete(query as CFDictionary)
    }

    public static func copyStreamKeyWithAutoExpire(_ key: String) {
        UIPasteboard.general.setItems(
            [[UIPasteboard.typeAutomatic: key]],
            options: [.expirationDate: Date().addingTimeInterval(60)]
        )
    }

    // MARK: - Settings
    public static func saveSettings(_ settings: PulseSettings) {
        let defaults = activeDefaults
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: settingsKey)
        defaults.synchronize()
        postDarwinNotification(named: reloadNotificationName)
    }

    public static func loadSettings() -> PulseSettings {
        let defaults = activeDefaults
        guard let data = defaults.data(forKey: settingsKey),
              let decoded = try? JSONDecoder().decode(PulseSettings.self, from: data) else {
            return PulseSettings()
        }
        return decoded
    }

    // MARK: - Diagnostics & True Low-Water Mark Memory
    public static func currentProcessAvailableMemoryMB() -> Int {
        Int(os_proc_available_memory() / (1024 * 1024))
    }

    public static func loadDiagnostics() -> BroadcastDiagnostics {
        let defaults = activeDefaults
        guard let data = defaults.data(forKey: diagnosticsKey),
              let decoded = try? JSONDecoder().decode(BroadcastDiagnostics.self, from: data) else {
            return BroadcastDiagnostics()
        }
        return decoded
    }

    public static func updateDiagnostics(
        currentMemMB: Int? = nil,
        framesEncoded: Int? = nil,
        framesDropped: Int? = nil,
        status: String? = nil
    ) {
        let defaults = activeDefaults
        var diag = loadDiagnostics()
        if let mem = currentMemMB, mem > 0 {
            if diag.minAvailableMemoryMB == 0 || mem < diag.minAvailableMemoryMB {
                diag.minAvailableMemoryMB = mem
            }
        }
        if let enc = framesEncoded { diag.framesEncoded = enc }
        if let drop = framesDropped { diag.framesDropped = drop }
        if let st = status { diag.lastStatusMessage = st }

        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        diag.lastUpdatedTimestamp = formatter.string(from: Date())

        if let data = try? JSONEncoder().encode(diag) {
            defaults.set(data, forKey: diagnosticsKey)
            defaults.synchronize()
        }
    }

    public static func resetDiagnostics() {
        let defaults = activeDefaults
        guard let data = try? JSONEncoder().encode(BroadcastDiagnostics()) else { return }
        defaults.set(data, forKey: diagnosticsKey)
        defaults.synchronize()
    }

    // MARK: - Accounts
    public static func loadAccounts() -> [YouTubeAccount] {
        let defaults = activeDefaults
        guard let data = defaults.data(forKey: accountsMetadataKey),
              var decoded = try? JSONDecoder().decode([YouTubeAccount].self, from: data) else {
            return []
        }
        for i in decoded.indices {
            if let kcKey = loadKeyFromKeychain(accountId: decoded[i].id), !kcKey.isEmpty {
                decoded[i].primaryStreamKey = kcKey
            }
        }
        return decoded
    }

    public static func saveAccounts(_ accounts: [YouTubeAccount]) {
        let defaults = activeDefaults
        for acct in accounts {
            saveKeyToKeychain(accountId: acct.id, streamKey: acct.primaryStreamKey)
        }
        guard let data = try? JSONEncoder().encode(accounts) else { return }
        defaults.set(data, forKey: accountsMetadataKey)
        defaults.synchronize()
    }

    public static func removeAccount(id: String, from accounts: inout [YouTubeAccount]) {
        deleteKeyFromKeychain(accountId: id)
        accounts.removeAll(where: { $0.id == id })
        saveAccounts(accounts)
    }

    public static func loadActiveAccountId() -> String? {
        activeDefaults.string(forKey: activeAccountIdKey) ?? loadAccounts().first?.id
    }

    public static func saveActiveAccountId(_ id: String?) {
        let defaults = activeDefaults
        defaults.set(id, forKey: activeAccountIdKey)
        defaults.synchronize()
    }

    public static func activeAccount() -> YouTubeAccount? {
        let list = loadAccounts()
        let activeId = loadActiveAccountId()
        return list.first(where: { $0.id == activeId }) ?? list.first
    }

    // MARK: - Downscaled User Overlay Persistence
    public static func downscaleImage(_ image: UIImage, maxDimension: CGFloat = 1080) -> UIImage {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return image }
        let maxSide = max(size.width, size.height)
        guard maxSide > maxDimension else { return image }

        let scale = maxDimension / maxSide
        let targetSize = CGSize(width: round(size.width * scale), height: round(size.height * scale))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }

    public static func saveRawGapImage(_ image: UIImage?, isTop: Bool) {
        guard let base = activeStorageURL else { return }
        let url = base.appendingPathComponent(isTop ? rawTopFilename : rawBottomFilename)
        guard let image = image, let data = downscaleImage(image).pngData() else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try? data.write(to: url, options: .atomic)
    }

    public static func loadRawGapImage(isTop: Bool) -> UIImage? {
        guard let base = activeStorageURL else { return nil }
        let targetURL = base.appendingPathComponent(isTop ? rawTopFilename : rawBottomFilename)
        guard let data = try? Data(contentsOf: targetURL) else { return nil }
        return UIImage(data: data)
    }

    public static func saveRawLandscapeImage(_ image: UIImage?) {
        guard let base = activeStorageURL else { return }
        let url = base.appendingPathComponent(rawLandscapeFilename)
        guard let image = image, let data = downscaleImage(image, maxDimension: 1920).pngData() else {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: base.appendingPathComponent(bakedLandscapeFilename))
            return
        }
        try? data.write(to: url, options: .atomic)
    }

    public static func loadRawLandscapeImage() -> UIImage? {
        guard let base = activeStorageURL else { return nil }
        let url = base.appendingPathComponent(rawLandscapeFilename)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    private static func drawAspectFill(_ image: UIImage, in targetRect: CGRect, opacity: CGFloat, context: CGContext) {
        guard image.size.width > 0, image.size.height > 0 else { return }
        context.saveGState()
        context.clip(to: targetRect)
        let scale = max(targetRect.width / image.size.width, targetRect.height / image.size.height)
        let drawWidth = image.size.width * scale
        let drawHeight = image.size.height * scale
        let drawRect = CGRect(
            x: targetRect.minX + (targetRect.width - drawWidth) * 0.5,
            y: targetRect.minY + (targetRect.height - drawHeight) * 0.5,
            width: drawWidth,
            height: drawHeight
        )
        image.draw(in: drawRect, blendMode: .normal, alpha: opacity)
        context.restoreGState()
    }

    public static func bakeStaticOverlays(opacity: CGFloat) {
        guard let base = activeStorageURL else { return }
        let topImg = loadRawGapImage(isTop: true)
        let botImg = loadRawGapImage(isTop: false)
        let shortsURL = base.appendingPathComponent(bakedShortsFilename)

        if topImg == nil && botImg == nil {
            try? FileManager.default.removeItem(at: shortsURL)
        } else {
            let size = CGSize(width: 1080, height: 1920)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1.0
            format.opaque = true
            let renderer = UIGraphicsImageRenderer(size: size, format: format)

            let img = renderer.image { ctx in
                UIColor(red: 0.035, green: 0.035, blue: 0.043, alpha: 1.0).setFill()
                ctx.fill(CGRect(origin: .zero, size: size))
                if let top = topImg {
                    drawAspectFill(top, in: CGRect(x: 0, y: 0, width: 1080, height: 720), opacity: opacity, context: ctx.cgContext)
                }
                if let bot = botImg {
                    drawAspectFill(bot, in: CGRect(x: 0, y: 1200, width: 1080, height: 720), opacity: opacity, context: ctx.cgContext)
                }
            }
            if let data = img.pngData() {
                try? data.write(to: shortsURL, options: .atomic)
            }
        }

        let landscapeURL = base.appendingPathComponent(bakedLandscapeFilename)
        if let landImg = loadRawLandscapeImage() {
            let size = CGSize(width: 1920, height: 1080)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1.0
            format.opaque = false
            let renderer = UIGraphicsImageRenderer(size: size, format: format)
            let baked = renderer.image { ctx in
                drawAspectFill(landImg, in: CGRect(origin: .zero, size: size), opacity: opacity, context: ctx.cgContext)
            }
            if let data = baked.pngData() {
                try? data.write(to: landscapeURL, options: .atomic)
            }
        } else {
            try? FileManager.default.removeItem(at: landscapeURL)
        }

        postDarwinNotification(named: reloadOverlaysNotificationName)
    }

    public static var bakedShortsURL: URL? {
        guard let base = activeStorageURL else { return nil }
        let url = base.appendingPathComponent(bakedShortsFilename)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    public static var bakedLandscapeURL: URL? {
        guard let base = activeStorageURL else { return nil }
        let url = base.appendingPathComponent(bakedLandscapeFilename)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    public static var recordedVideoURL: URL? {
        activeStorageURL?.appendingPathComponent(recordingFilename)
    }

    public static var hasRecordedVideo: Bool {
        guard let url = recordedVideoURL else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }
}
