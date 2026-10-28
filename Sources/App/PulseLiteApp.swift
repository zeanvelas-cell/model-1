import SwiftUI
import PhotosUI
import ReplayKit
import AVFoundation
import VideoToolbox
import HaishinKit
import RTMPHaishinKit

enum ActiveSlideDrawer: String, Identifiable {
    case none
    case ratioAndOverlays
    case accounts
    case diagnostics
    case hardwareSettings
    var id: String { rawValue }
}

/// Implements the "PRISM Live Dual-Mic Pre-Lock" workaround for iOS games (CODM / BGMI / PUBG Mobile).
@MainActor
final class DualMicPreLockEngine: ObservableObject {
    @Published var isPreLocked: Bool = false
    private var audioEngine: AVAudioEngine?

    func togglePreLock() {
        if isPreLocked {
            stopPreLock()
        } else {
            startPreLock()
        }
    }

    func startPreLock() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .voiceChat,
                options: [.mixWithOthers, .allowBluetooth, .allowBluetoothA2DP]
            )
            try session.setActive(true, options: [])

            let engine = AVAudioEngine()
            let input = engine.inputNode
            let mainMixer = engine.mainMixerNode
            mainMixer.outputVolume = 0.0
            let format = input.outputFormat(forBus: 0)
            if format.channelCount > 0 && format.sampleRate > 0 {
                engine.connect(input, to: mainMixer, format: format)
                try engine.start()
                self.audioEngine = engine
            }
            isPreLocked = true
        } catch {
            isPreLocked = false
        }
    }

    func stopPreLock() {
        audioEngine?.stop()
        audioEngine = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        isPreLocked = false
    }
}

/// In-App RTMPS Connection & Overlay Test Broadcaster (with full mixer/connection cleanup on error).
@MainActor
final class InAppTestBroadcaster: ObservableObject {
    @Published var isStreaming: Bool = false
    @Published var statusText: String = "Tap Red Button to Stream Games"

    private let mixer = MediaMixer(captureSessionMode: .manual, multiTrackAudioMixingEnabled: true)
    private let rtmpConnection = RTMPConnection()
    private lazy var rtmpStream = RTMPStream(connection: rtmpConnection)
    private var compositor: FrameCompositor?

    func toggleBroadcast(settings: PulseSettings, account: YouTubeAccount?) {
        if isStreaming {
            stopBroadcast()
        } else {
            startBroadcast(settings: settings, account: account)
        }
    }

    func startBroadcast(settings: PulseSettings, account: YouTubeAccount?) {
        guard let account = account, !account.primaryStreamKey.isEmpty else {
            statusText = "Add Stream Key in Accounts first"
            return
        }

        let recorder = RPScreenRecorder.shared()
        recorder.isMicrophoneEnabled = settings.includeMicrophoneAudio
        let targetSize = settings.resolvedCanvasSize
        let comp = FrameCompositor(settings: settings)
        self.compositor = comp
        statusText = "Testing RTMPS Key..."

        Task {
            var videoMixerSettings = await mixer.videoMixerSettings
            videoMixerSettings.mode = .passthrough
            await mixer.setVideoMixerSettings(videoMixerSettings)

            await mixer.setFrameRate(Float64(settings.targetFPS))
            var vSettings = await rtmpStream.videoSettings
            vSettings.videoSize = targetSize
            vSettings.bitRate = settings.targetBitrateKbps * 1000
            vSettings.profileLevel = kVTProfileLevel_H264_High_AutoLevel as String
            vSettings.maxKeyFrameIntervalDuration = 2
            vSettings.allowFrameReordering = false
            try? await rtmpStream.setVideoSettings(vSettings)

            var aSettings = await rtmpStream.audioSettings
            aSettings.bitRate = 128 * 1000
            try? await rtmpStream.setAudioSettings(aSettings)

            await mixer.addOutput(rtmpStream)
            await mixer.startRunning()

            do {
                _ = try await rtmpConnection.connect(settings.ingestServerURL)
                _ = try await rtmpStream.publish(account.primaryStreamKey)
            } catch {
                try? await rtmpStream.close()
                try? await rtmpConnection.close()
                await mixer.stopRunning()
                isStreaming = false
                statusText = "RTMPS Failed: \(error.localizedDescription)"
                return
            }

            recorder.startCapture { [weak self] sampleBuffer, bufferType, error in
                guard error == nil, let self = self else { return }
                switch bufferType {
                case .video:
                    guard let processed = comp.processVideoSampleBuffer(sampleBuffer) else { return }
                    Task { await self.mixer.append(processed) }
                case .audioApp:
                    Task { await self.mixer.append(sampleBuffer, track: 0) }
                case .audioMic:
                    guard settings.includeMicrophoneAudio else { return }
                    Task { await self.mixer.append(sampleBuffer, track: 1) }
                @unknown default:
                    break
                }
            } completionHandler: { [weak self] error in
                Task { @MainActor in
                    guard let self = self else { return }
                    if let error = error {
                        try? await self.rtmpStream.close()
                        try? await self.rtmpConnection.close()
                        await self.mixer.stopRunning()
                        self.statusText = "Capture Error: \(error.localizedDescription)"
                        self.isStreaming = false
                    } else {
                        self.isStreaming = true
                        self.statusText = "LIVE (App Preview Test Active)"
                    }
                }
            }
        }
    }

    func stopBroadcast() {
        RPScreenRecorder.shared().stopCapture { _ in }
        Task {
            try? await rtmpStream.close()
            try? await rtmpConnection.close()
            await mixer.stopRunning()
            isStreaming = false
            statusText = "Test Stopped • Ready for Game Stream"
        }
    }
}

struct SystemBroadcastPickerRepresentable: UIViewRepresentable {
    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 64, height: 64))
        picker.preferredExtension = "com.pulselite.app.broadcast"
        picker.showsMicrophoneButton = true
        return picker
    }
    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {}
}

struct PulseLiteDeckView: View {
    @State private var settings: PulseSettings = AppGroupBridge.loadSettings()
    @State private var accounts: [YouTubeAccount] = AppGroupBridge.loadAccounts()
    @State private var activeAccountId: String? = AppGroupBridge.loadActiveAccountId()
    @State private var diagnostics: BroadcastDiagnostics = AppGroupBridge.loadDiagnostics()
    @State private var isAppGroupOK: Bool = AppGroupBridge.groupAvailable
    @State private var activeDrawer: ActiveSlideDrawer = .none
    @State private var hasRecording: Bool = AppGroupBridge.hasRecordedVideo
    @StateObject private var testBroadcaster = InAppTestBroadcaster()
    @StateObject private var dualMicEngine = DualMicPreLockEngine()

    // Heavy Mode Warning Modal State ("Don't show again" checkbox)
    @State private var showHeavyModeWarningModal: Bool = false
    @State private var dontShowHeavyWarningAgainCheckbox: Bool = false
    @State private var pendingQualityTier: StreamQualityTier? = nil
    @State private var pendingFPS: Int? = nil

    // Slider draft states (applied on release so dragging never causes a 2x buffer memory spike)
    @State private var draftOpacity: CGFloat = AppGroupBridge.loadSettings().gapOverlayOpacity
    @State private var draftVerticalOffset: CGFloat = AppGroupBridge.loadSettings().shortsGameVerticalOffset

    // User-Picked Static Gap & Landscape Overlays (No bundled screenshot examples)
    @State private var topGapItem: PhotosPickerItem? = nil
    @State private var bottomGapItem: PhotosPickerItem? = nil
    @State private var landscapeOverlayItem: PhotosPickerItem? = nil
    @State private var topGapPreview: UIImage? = AppGroupBridge.loadRawGapImage(isTop: true)
    @State private var bottomGapPreview: UIImage? = AppGroupBridge.loadRawGapImage(isTop: false)
    @State private var landscapeOverlayPreview: UIImage? = AppGroupBridge.loadRawLandscapeImage()

    // Account Entry
    @State private var newChannelName: String = ""
    @State private var newPrimaryKey: String = ""

    private let glassStroke = LinearGradient(
        colors: [Color.white.opacity(0.32), Color.white.opacity(0.06)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    private var activeAccount: YouTubeAccount? {
        accounts.first(where: { $0.id == activeAccountId }) ?? accounts.first
    }

    private var currentResolutionBadge: String {
        switch settings.qualityTier {
        case .safe720p: return "720P"
        case .hd1080p: return "1080P"
        case .nativeScreen: return "NATIVE"
        }
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.02, green: 0.02, blue: 0.04),
                        Color(red: 0.06, green: 0.07, blue: 0.12),
                        Color(red: 0.02, green: 0.02, blue: 0.03)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Color.white.opacity(0.08), Color.clear],
                            center: .center,
                            startRadius: 10,
                            endRadius: 240
                        )
                    )
                    .frame(width: 440, height: 440)
                    .blur(radius: 30)

                VStack(spacing: 10) {
                    topGlassTelemetryBar
                    quickLiveControlsStrip
                    centerGlassBroadcastMonitor
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    bottomGlassControlDeck
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)

                if activeDrawer != .none {
                    Color.black.opacity(0.55)
                        .ignoresSafeArea()
                        .onTapGesture {
                            triggerUIHaptic()
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                                activeDrawer = .none
                            }
                        }

                    HStack(spacing: 0) {
                        Spacer()
                        slideOutGlassDrawer
                            .frame(width: min(geo.size.width * 0.88, 410))
                            .background(.ultraThinMaterial)
                            .overlay(
                                Rectangle()
                                    .frame(width: 1)
                                    .foregroundStyle(glassStroke),
                                alignment: .leading
                            )
                            .transition(.move(edge: .trailing))
                    }
                    .ignoresSafeArea(edges: .vertical)
                }

                // Heavy Performance Mode Warning Dialog (with "Don't show again" checkbox)
                if showHeavyModeWarningModal {
                    Color.black.opacity(0.65)
                        .ignoresSafeArea()

                    heavyPerformanceWarningCard
                        .padding(.horizontal, 28)
                        .transition(.scale.combined(with: .opacity))
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            // Record exact device screen aspect dimensions (capped to safe encoder limits) for Native Screen mode
            let screenBounds = UIScreen.main.nativeBounds
            let rawLong = Int(max(screenBounds.width, screenBounds.height))
            let rawShort = Int(min(screenBounds.width, screenBounds.height))
            if rawLong > 0 && rawShort > 0 {
                let scale = min(1.0, 1920.0 / Double(rawLong))
                let evenLong = (Int(Double(rawLong) * scale) / 2) * 2
                let evenShort = (Int(Double(rawShort) * scale) / 2) * 2
                if settings.nativeScreenLongEdgePx != evenLong || settings.nativeScreenShortEdgePx != evenShort {
                    settings.nativeScreenLongEdgePx = evenLong
                    settings.nativeScreenShortEdgePx = evenShort
                }
            }
        }
        .onChange(of: settings) { _, newVal in
            AppGroupBridge.saveSettings(newVal)
        }
        .onChange(of: topGapItem) { _, item in
            handlePickedImage(item: item, mode: .topGap)
        }
        .onChange(of: bottomGapItem) { _, item in
            handlePickedImage(item: item, mode: .bottomGap)
        }
        .onChange(of: landscapeOverlayItem) { _, item in
            handlePickedImage(item: item, mode: .landscape)
        }
    }

    // MARK: - Heavy Performance Mode Warning Modal (with "Don't show again" box)
    private var heavyPerformanceWarningCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                    .font(.system(size: 18))
                Text("High Performance Mode Warning")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
            }

            Text("Activating 1080p, Native Resolution, or 60 FPS increases GPU heat and pushes the iOS Broadcast Extension closer to Apple's 50 MB RAM limit on some devices while playing heavy games like CODM.")
                .font(.system(size: 12, design: .rounded))
                .foregroundColor(.white.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)

            Button {
                triggerUIHaptic()
                dontShowHeavyWarningAgainCheckbox.toggle()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: dontShowHeavyWarningAgainCheckbox ? "checkmark.square.fill" : "square")
                        .foregroundColor(dontShowHeavyWarningAgainCheckbox ? .cyan : .white.opacity(0.6))
                        .font(.system(size: 16))
                    Text("Don't show this warning again")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundColor(.white)
                }
            }
            .padding(.vertical, 4)

            HStack(spacing: 10) {
                Button("Keep 720p 30fps") {
                    triggerUIHaptic()
                    pendingQualityTier = nil
                    pendingFPS = nil
                    withAnimation(.easeOut(duration: 0.2)) {
                        showHeavyModeWarningModal = false
                    }
                }
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                .foregroundColor(.white)

                Button("Activate Anyway") {
                    triggerUIHaptic()
                    if dontShowHeavyWarningAgainCheckbox {
                        settings.suppressHeavyModeWarning = true
                    }
                    if let tier = pendingQualityTier {
                        settings.qualityTier = tier
                    }
                    if let fps = pendingFPS {
                        settings.targetFPS = fps
                    }
                    pendingQualityTier = nil
                    pendingFPS = nil
                    withAnimation(.easeOut(duration: 0.2)) {
                        showHeavyModeWarningModal = false
                    }
                }
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(Color.orange.opacity(0.85), in: RoundedRectangle(cornerRadius: 12))
                .foregroundColor(.black)
            }
        }
        .padding(20)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(glassStroke, lineWidth: 1.5))
        .shadow(color: .black.opacity(0.55), radius: 22, y: 10)
    }

    private func requestQualityOrFPSChange(newTier: StreamQualityTier? = nil, newFPS: Int? = nil) {
        let targetTier = newTier ?? settings.qualityTier
        let targetFPS = newFPS ?? settings.targetFPS
        let isHeavy = (targetTier == .hd1080p || targetTier == .nativeScreen || targetFPS == 60)

        if isHeavy && !settings.suppressHeavyModeWarning {
            pendingQualityTier = targetTier
            pendingFPS = targetFPS
            dontShowHeavyWarningAgainCheckbox = false
            withAnimation(.spring(response: 0.26, dampingFraction: 0.85)) {
                showHeavyModeWarningModal = true
            }
        } else {
            if let tier = newTier { settings.qualityTier = tier }
            if let fps = newFPS { settings.targetFPS = fps }
        }
    }

    // MARK: - Top Frosted Glass Telemetry Pill
    private var topGlassTelemetryBar: some View {
        HStack(spacing: 10) {
            Image("PulseLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 30, height: 30)
                .clipShape(Circle())
                .overlay(Circle().stroke(Color.white.opacity(0.35), lineWidth: 1))
                .shadow(color: .white.opacity(0.18), radius: 4)

            HStack(spacing: 6) {
                Circle()
                    .fill(activeAccount == nil ? Color.orange : Color.green)
                    .frame(width: 7, height: 7)
                Text(activeAccount?.channelTitle ?? "ADD STREAM KEY")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.thinMaterial, in: Capsule())
            .overlay(Capsule().stroke(glassStroke, lineWidth: 1))

            Spacer()

            Button {
                triggerUIHaptic()
                settings.aspectMode = (settings.aspectMode == .landscape16x9) ? .verticalShorts9x16 : .landscape16x9
            } label: {
                Text(settings.aspectMode == .landscape16x9 ? "16:9 ⇄" : "9:16 ⇄")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.14), in: Capsule())
                    .foregroundColor(.white)
                    .overlay(Capsule().stroke(glassStroke, lineWidth: 1))
            }

            Text("\(currentResolutionBadge) • \(settings.targetFPS)FPS")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(.thinMaterial, in: Capsule())
                .foregroundColor(.green)
                .overlay(Capsule().stroke(glassStroke, lineWidth: 1))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(glassStroke, lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
    }

    // MARK: - Instant Live Streamer Action Pill
    private var quickLiveControlsStrip: some View {
        HStack(spacing: 8) {
            Button {
                triggerUIHaptic()
                settings.includeMicrophoneAudio.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: settings.includeMicrophoneAudio ? "mic.fill" : "mic.slash.fill")
                    Text(settings.includeMicrophoneAudio ? "Stream Mic" : "Mic Muted")
                }
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(settings.includeMicrophoneAudio ? Color.green.opacity(0.22) : Color.red.opacity(0.25), in: Capsule())
                .foregroundColor(settings.includeMicrophoneAudio ? .green : .red)
                .overlay(Capsule().stroke(glassStroke, lineWidth: 1))
            }

            Button {
                triggerUIHaptic()
                dualMicEngine.togglePreLock()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: dualMicEngine.isPreLocked ? "headphones.circle.fill" : "headphones")
                    Text(dualMicEngine.isPreLocked ? "Dual-Mic LOCKED" : "Pre-Lock Squad Mic")
                }
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(dualMicEngine.isPreLocked ? Color.cyan.opacity(0.28) : Color.white.opacity(0.08), in: Capsule())
                .foregroundColor(dualMicEngine.isPreLocked ? .cyan : .white)
                .overlay(Capsule().stroke(glassStroke, lineWidth: 1))
            }

            Button {
                triggerUIHaptic()
                settings.enablePrivacyShieldBanner.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: settings.enablePrivacyShieldBanner ? "eye.slash.fill" : "eye.fill")
                    Text(settings.enablePrivacyShieldBanner ? "Shield ON" : "Privacy Shield")
                }
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(settings.enablePrivacyShieldBanner ? Color.orange.opacity(0.28) : Color.white.opacity(0.06), in: Capsule())
                .foregroundColor(settings.enablePrivacyShieldBanner ? .orange : .white)
                .overlay(Capsule().stroke(glassStroke, lineWidth: 1))
            }
        }
    }

    // MARK: - Center Glass Studio Preview
    private var centerGlassBroadcastMonitor: some View {
        VStack(spacing: 10) {
            if settings.aspectMode == .verticalShorts9x16 {
                VStack(spacing: 0) {
                    ZStack {
                        Color.black.opacity(0.45)
                        if let topImg = topGapPreview, settings.enableStaticGapOverlay {
                            Image(uiImage: topImg)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 182, height: 96)
                                .opacity(draftOpacity)
                                .clipped()
                        } else {
                            Text("TOP BANNER SLOT (OPTIONAL PNG)")
                                .font(.system(size: 9, weight: .semibold, design: .rounded))
                                .foregroundColor(.white.opacity(0.45))
                        }
                    }
                    .frame(width: 182, height: 96)
                    .clipped()

                    ZStack {
                        Color.black.opacity(0.85)
                        VStack(spacing: 4) {
                            Image(systemName: settings.enablePrivacyShieldBanner ? "lock.shield.fill" : "gamecontroller.fill")
                                .font(.system(size: 15))
                                .foregroundColor(settings.enablePrivacyShieldBanner ? .orange : .white.opacity(0.85))
                            Text(settings.enablePrivacyShieldBanner ? "PRIVACY SHIELD ON" : "LIVE GAME FEED")
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .foregroundColor(.white)
                            Text(settings.shortsCropPreset.displayTitle)
                                .font(.system(size: 8, weight: .medium, design: .rounded))
                                .foregroundColor(.white.opacity(0.65))
                                .lineLimit(1)
                                .padding(.horizontal, 6)
                        }
                    }
                    .frame(width: 182, height: 112)
                    .overlay(Rectangle().stroke(Color.white.opacity(0.28), lineWidth: 1))

                    ZStack {
                        Color.black.opacity(0.45)
                        if let botImg = bottomGapPreview, settings.enableStaticGapOverlay {
                            Image(uiImage: botImg)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 182, height: 96)
                                .opacity(draftOpacity)
                                .clipped()
                        } else {
                            Text("BOTTOM BANNER SLOT (OPTIONAL PNG)")
                                .font(.system(size: 9, weight: .semibold, design: .rounded))
                                .foregroundColor(.white.opacity(0.45))
                        }
                    }
                    .frame(width: 182, height: 96)
                    .clipped()
                }
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(glassStroke, lineWidth: 1.5))
                .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
            } else {
                ZStack {
                    Color.black.opacity(0.65)
                    if let landImg = landscapeOverlayPreview, settings.enableStaticGapOverlay {
                        Image(uiImage: landImg)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 306, height: 172)
                            .opacity(draftOpacity)
                            .clipped()
                    }
                    VStack(spacing: 6) {
                        Image(systemName: settings.enablePrivacyShieldBanner ? "lock.shield.fill" : "display")
                            .font(.system(size: 20))
                            .foregroundColor(settings.enablePrivacyShieldBanner ? .orange : .white.opacity(0.85))
                        Text(settings.enablePrivacyShieldBanner ? "PRIVACY SHIELD ON" : "16:9 HORIZONTAL STREAM")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                        Text("\(settings.qualityTier.displayTitle) • \(settings.targetFPS) FPS")
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundColor(.white.opacity(0.65))
                    }
                }
                .frame(width: 306, height: 172)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(glassStroke, lineWidth: 1.5))
                .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
            }

            Text("1. Plug in earphones  2. Turn on iOS Focus/DND  3. Tap Pre-Lock Squad Mic BEFORE opening game.")
                .font(.system(size: 9.5, weight: .medium, design: .rounded))
                .foregroundColor(.white.opacity(0.65))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)
        }
    }

    // MARK: - Bottom Frosted Glass Control Dock
    private var bottomGlassControlDeck: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                glassDockButton(title: "Layout", icon: "rectangle.split.3x1", active: activeDrawer == .ratioAndOverlays) {
                    activeDrawer = .ratioAndOverlays
                }
                glassDockButton(title: "Accounts", icon: "person.crop.circle", active: activeDrawer == .accounts) {
                    activeDrawer = .accounts
                }
                glassDockButton(title: "Health", icon: "waveform.path.ecg", active: activeDrawer == .diagnostics) {
                    refreshDiagnostics()
                    activeDrawer = .diagnostics
                }
                glassDockButton(title: "Engine", icon: "slider.horizontal.3", active: activeDrawer == .hardwareSettings) {
                    refreshDiagnostics()
                    activeDrawer = .hardwareSettings
                }
            }

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("GAME BROADCAST LAUNCHER")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                    Text(testBroadcaster.statusText)
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundColor(.white.opacity(0.65))
                        .lineLimit(1)
                }

                Spacer()

                Button {
                    triggerUIHaptic()
                    testBroadcaster.toggleBroadcast(settings: settings, account: activeAccount)
                } label: {
                    Text(testBroadcaster.isStreaming ? "STOP TEST" : "TEST KEY")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(testBroadcaster.isStreaming ? Color.red : Color.white.opacity(0.14), in: Capsule())
                        .foregroundColor(.white)
                        .overlay(Capsule().stroke(glassStroke, lineWidth: 1))
                }

                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Color.red.opacity(0.88), Color.red.opacity(0.48)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 50, height: 50)
                        .overlay(Circle().stroke(Color.white.opacity(0.4), lineWidth: 1.5))
                        .shadow(color: .red.opacity(0.4), radius: 8)

                    SystemBroadcastPickerRepresentable()
                        .frame(width: 44, height: 44)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(glassStroke, lineWidth: 1))
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(glassStroke, lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 16, y: 8)
    }

    // MARK: - Frosted Slide-Out Drawer
    @ViewBuilder
    private var slideOutGlassDrawer: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(drawerTitle)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                Spacer()
                Button("Done") {
                    triggerUIHaptic()
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                        activeDrawer = .none
                    }
                }
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.thinMaterial, in: Capsule())
                .foregroundColor(.white)
            }
            .padding(.top, 54)

            Divider().overlay(Color.white.opacity(0.15))

            ScrollView(showsIndicators: false) {
                switch activeDrawer {
                case .ratioAndOverlays:
                    ratioAndOverlaysDrawer
                case .accounts:
                    accountsDrawer
                case .diagnostics:
                    diagnosticsDrawer
                case .hardwareSettings:
                    hardwareSettingsDrawer
                case .none:
                    EmptyView()
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 24)
    }

    private var ratioAndOverlaysDrawer: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("CANVAS ASPECT RATIO (SET BEFORE GOING LIVE)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundColor(.white.opacity(0.6))

            ForEach(StreamAspectMode.allCases, id: \.self) { mode in
                Button {
                    triggerUIHaptic()
                    settings.aspectMode = mode
                } label: {
                    HStack {
                        Text(mode.displayTitle)
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundColor(.white)
                        Spacer()
                        if settings.aspectMode == mode {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                        }
                    }
                    .padding(12)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(settings.aspectMode == mode ? Color.green.opacity(0.8) : Color.white.opacity(0.15), lineWidth: 1)
                    )
                }
            }

            if settings.aspectMode == .verticalShorts9x16 {
                Text("SHORTS HUD CROP PRESET")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundColor(.white.opacity(0.6))

                ForEach(ShortsGameCropPreset.allCases, id: \.self) { preset in
                    Button {
                        triggerUIHaptic()
                        settings.shortsCropPreset = preset
                    } label: {
                        HStack {
                            Text(preset.displayTitle)
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .foregroundColor(.white)
                            Spacer()
                            if settings.shortsCropPreset == preset {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.cyan)
                            }
                        }
                        .padding(10)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(settings.shortsCropPreset == preset ? Color.cyan.opacity(0.8) : Color.white.opacity(0.15), lineWidth: 1)
                        )
                    }
                }
            }

            Toggle("Enable Custom Static Overlays (Updates Live)", isOn: $settings.enableStaticGapOverlay)
                .font(.system(size: 13, weight: .medium, design: .rounded))

            if settings.aspectMode == .verticalShorts9x16 {
                HStack(spacing: 10) {
                    PhotosPicker(selection: $topGapItem, matching: .images) {
                        Text(topGapPreview == nil ? "Pick Top Banner PNG" : "Change Top PNG")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .frame(maxWidth: .infinity)
                            .padding(12)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .foregroundColor(.white)
                            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(glassStroke, lineWidth: 1))
                    }

                    PhotosPicker(selection: $bottomGapItem, matching: .images) {
                        Text(bottomGapPreview == nil ? "Pick Bottom Banner PNG" : "Change Bottom PNG")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .frame(maxWidth: .infinity)
                            .padding(12)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .foregroundColor(.white)
                            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(glassStroke, lineWidth: 1))
                    }
                }
            } else {
                PhotosPicker(selection: $landscapeOverlayItem, matching: .images) {
                    Text(landscapeOverlayPreview == nil ? "Select 16:9 Transparent Frame PNG" : "Change 16:9 Frame PNG")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .frame(maxWidth: .infinity)
                        .padding(12)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .foregroundColor(.white)
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(glassStroke, lineWidth: 1))
                }
            }

            if topGapPreview != nil || bottomGapPreview != nil || landscapeOverlayPreview != nil {
                Button("Remove Custom Overlays") {
                    triggerUIHaptic()
                    topGapPreview = nil
                    bottomGapPreview = nil
                    landscapeOverlayPreview = nil
                    Task.detached(priority: .utility) {
                        AppGroupBridge.saveRawGapImage(nil, isTop: true)
                        AppGroupBridge.saveRawGapImage(nil, isTop: false)
                        AppGroupBridge.saveRawLandscapeImage(nil)
                        AppGroupBridge.bakeStaticOverlays(opacity: 1.0)
                    }
                }
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundColor(.red)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Overlay Opacity (Applies on Release): \(Int(draftOpacity * 100))%")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                Slider(
                    value: $draftOpacity,
                    in: 0.1...1.0,
                    step: 0.05,
                    onEditingChanged: { editing in
                        if !editing {
                            settings.gapOverlayOpacity = draftOpacity
                            let finalOp = draftOpacity
                            Task.detached(priority: .utility) {
                                AppGroupBridge.bakeStaticOverlays(opacity: finalOp)
                            }
                        }
                    }
                )
            }

            if settings.aspectMode == .verticalShorts9x16 {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Game Vertical Position (Applies on Release): \(Int(draftVerticalOffset)) px")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                    Slider(
                        value: $draftVerticalOffset,
                        in: -300...300,
                        step: 10,
                        onEditingChanged: { editing in
                            if !editing {
                                settings.shortsGameVerticalOffset = draftVerticalOffset
                            }
                        }
                    )
                }
            }
        }
    }

    private var accountsDrawer: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("YOUR STREAM CHANNELS (KEYCHAIN PROTECTED)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundColor(.white.opacity(0.6))

            if accounts.isEmpty {
                Text("Paste your YouTube, Twitch, or Kick Stream Key below.")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundColor(.white.opacity(0.6))
            } else {
                ForEach(accounts) { account in
                    HStack {
                        Button {
                            triggerUIHaptic()
                            activeAccountId = account.id
                            AppGroupBridge.saveActiveAccountId(account.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(account.channelTitle)
                                    .font(.system(size: 13, weight: .bold, design: .rounded))
                                    .foregroundColor(.white)
                                Text(activeAccount?.id == account.id ? "Active Stream Key" : "Tap to Switch")
                                    .font(.system(size: 11, design: .rounded))
                                    .foregroundColor(activeAccount?.id == account.id ? .green : .white.opacity(0.55))
                            }
                        }
                        Spacer()
                        Button("Copy (60s)") {
                            AppGroupBridge.copyStreamKeyWithAutoExpire(account.primaryStreamKey)
                            triggerUIHaptic()
                        }
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundColor(.cyan)

                        Button("Remove") {
                            triggerUIHaptic()
                            AppGroupBridge.removeAccount(id: account.id, from: &accounts)
                            if activeAccountId == account.id {
                                activeAccountId = accounts.first?.id
                                AppGroupBridge.saveActiveAccountId(activeAccountId)
                            }
                        }
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundColor(.red)
                    }
                    .padding(12)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(activeAccount?.id == account.id ? Color.green.opacity(0.8) : Color.white.opacity(0.15), lineWidth: 1)
                    )
                }
            }

            Divider().overlay(Color.white.opacity(0.15))

            Text("ADD STREAM KEY")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundColor(.white.opacity(0.6))

            TextField("Channel Name (e.g. Main Gaming)", text: $newChannelName)
                .padding(10)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
                .font(.system(size: 13, design: .rounded))

            SecureField("Stream Key (xxxx-xxxx-xxxx-xxxx)", text: $newPrimaryKey)
                .padding(10)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
                .font(.system(size: 13, design: .monospaced))

            Button {
                triggerUIHaptic()
                let cleanKey = newPrimaryKey.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleanKey.isEmpty else { return }
                let acct = YouTubeAccount(
                    channelTitle: newChannelName.isEmpty ? "Channel \(accounts.count + 1)" : newChannelName,
                    primaryStreamKey: cleanKey
                )
                accounts.append(acct)
                activeAccountId = acct.id
                AppGroupBridge.saveAccounts(accounts)
                AppGroupBridge.saveActiveAccountId(acct.id)
                AppGroupBridge.copyStreamKeyWithAutoExpire(cleanKey)
                newChannelName = ""
                newPrimaryKey = ""
            } label: {
                Text("Save to Keychain (60s Auto-Expire Clipboard)")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .frame(maxWidth: .infinity)
                    .padding(12)
                    .background(Color.green.opacity(0.25), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .foregroundColor(.green)
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.green.opacity(0.7), lineWidth: 1))
            }
        }
    }

    private var diagnosticsDrawer: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("LIVE STREAM HEALTH & REAL EXTENSION RAM")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundColor(.white.opacity(0.6))

            diagGlassCard(
                label: "SHARED APP GROUP (\(AppGroupBridge.resolvedGroupId))",
                value: isAppGroupOK
                    ? "ACTIVE (Setup Sheet Auto-Skips Immediately)"
                    : "STRIPPED BY SIDELOADER (Setup Sheet Will Ask for Key)",
                color: isAppGroupOK ? .green : .orange
            )

            diagGlassCard(
                label: "MEASURED MIN EXTENSION RAM HEADROOM",
                value: diagnostics.minAvailableMemoryMB > 0
                    ? "\(diagnostics.minAvailableMemoryMB) MB Free (Measured via os_proc_available_memory)"
                    : "— (Start a broadcast to measure real RAM headroom)",
                color: diagnostics.minAvailableMemoryMB > 12 ? .green : .orange
            )

            diagGlassCard(
                label: "FRAMES ENCODED / DROPPED",
                value: "\(diagnostics.framesEncoded) Encoded • \(diagnostics.framesDropped) Dropped",
                color: .white
            )

            diagGlassCard(
                label: "BROADCASTER STATUS",
                value: diagnostics.lastStatusMessage,
                color: .green
            )

            HStack(spacing: 10) {
                Button("Refresh") {
                    triggerUIHaptic()
                    refreshDiagnostics()
                }
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .frame(maxWidth: .infinity)
                .padding(12)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
                .foregroundColor(.white)

                Button("Reset Stats") {
                    triggerUIHaptic()
                    AppGroupBridge.resetDiagnostics()
                    refreshDiagnostics()
                }
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .frame(maxWidth: .infinity)
                .padding(12)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
                .foregroundColor(.red)
            }
        }
    }

    private var hardwareSettingsDrawer: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("RESOLUTION & FRAME RATE MODES")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundColor(.white.opacity(0.6))

            VStack(alignment: .leading, spacing: 8) {
                Text("Stream Resolution (720p / 1080p / Native Screen)")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))

                ForEach(StreamQualityTier.allCases, id: \.self) { tier in
                    Button {
                        triggerUIHaptic()
                        requestQualityOrFPSChange(newTier: tier)
                    } label: {
                        HStack {
                            Text(tier.displayTitle)
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .foregroundColor(.white)
                            Spacer()
                            if settings.qualityTier == tier {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                            }
                        }
                        .padding(10)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(settings.qualityTier == tier ? Color.green.opacity(0.8) : Color.white.opacity(0.15), lineWidth: 1)
                        )
                    }
                }
            }

            HStack {
                Text("Frame Rate (30 FPS / 60 FPS)")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                Spacer()
                HStack(spacing: 6) {
                    ForEach([30, 60], id: \.self) { fps in
                        Button {
                            triggerUIHaptic()
                            requestQualityOrFPSChange(newFPS: fps)
                        } label: {
                            Text("\(fps) FPS")
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(settings.targetFPS == fps ? Color.green.opacity(0.28) : Color.white.opacity(0.08), in: Capsule())
                                .foregroundColor(settings.targetFPS == fps ? .green : .white)
                        }
                    }
                }
            }

            if settings.suppressHeavyModeWarning {
                Button("Re-enable Heavy Mode Warning Popup") {
                    triggerUIHaptic()
                    settings.suppressHeavyModeWarning = false
                }
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundColor(.orange)
            }

            Divider().overlay(Color.white.opacity(0.15))

            Text("IN-GAME SQUAD MIC & AUDIO")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundColor(.white.opacity(0.6))

            VStack(alignment: .leading, spacing: 6) {
                Text("Extension Mic Mode")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                Picker("Voice Mode", selection: $settings.voiceChatMode) {
                    Text("Dual Mic (Pre-Lock)").tag(InGameVoiceChatMode.preLockDualMic)
                    Text("Squad Mic Only").tag(InGameVoiceChatMode.squadOnlyGameMic)
                }
                .pickerStyle(.segmented)
            }

            Toggle("Microphone Voice Audio on Stream", isOn: $settings.includeMicrophoneAudio)
                .font(.system(size: 13, design: .rounded))

            Toggle("Privacy Shield (Hide Screen/Notifications Live)", isOn: $settings.enablePrivacyShieldBanner)
                .font(.system(size: 13, design: .rounded))

            Toggle("Auto Thermal Guard (Stepdown to 30fps)", isOn: $settings.enableThermalAutoGuard)
                .font(.system(size: 13, design: .rounded))

            Toggle("Save Local MP4 Copy (Game Audio)", isOn: $settings.enableLocalRecording)
                .font(.system(size: 13, design: .rounded))

            if hasRecording, let recURL = AppGroupBridge.recordedVideoURL {
                HStack(spacing: 10) {
                    ShareLink(item: recURL) {
                        Text("Save MP4")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .frame(maxWidth: .infinity)
                            .padding(10)
                            .background(Color.green.opacity(0.22), in: RoundedRectangle(cornerRadius: 12))
                            .foregroundColor(.green)
                    }

                    Button("Delete MP4") {
                        try? FileManager.default.removeItem(at: recURL)
                        hasRecording = false
                    }
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .frame(maxWidth: .infinity)
                    .padding(10)
                    .background(Color.red.opacity(0.2), in: RoundedRectangle(cornerRadius: 12))
                    .foregroundColor(.red)
                }
            }

            Divider().overlay(Color.white.opacity(0.15))

            VStack(alignment: .leading, spacing: 4) {
                Text("Video Bitrate: \(settings.targetBitrateKbps) Kbps")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                Slider(
                    value: Binding(
                        get: { Double(settings.targetBitrateKbps) },
                        set: { settings.targetBitrateKbps = Int($0) }
                    ),
                    in: 2000...9000,
                    step: 500
                )
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("RTMP(S) Ingest Server")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundColor(.white.opacity(0.6))
                HStack(spacing: 8) {
                    Button("YouTube RTMPS") {
                        settings.ingestServerURL = "rtmps://a.rtmps.youtube.com:443/live2"
                    }
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.thinMaterial, in: Capsule())

                    Button("Twitch RTMPS") {
                        settings.ingestServerURL = "rtmps://live.twitch.tv:443/app"
                    }
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.thinMaterial, in: Capsule())

                    Button("Paste Kick URL") {
                        if let clip = UIPasteboard.general.string, clip.lowercased().hasPrefix("rtmp") {
                            settings.ingestServerURL = clip.trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                    }
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.thinMaterial, in: Capsule())
                }
                TextField("rtmps://a.rtmps.youtube.com:443/live2", text: $settings.ingestServerURL)
                    .padding(10)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .font(.system(size: 11, design: .monospaced))
            }
        }
    }

    // MARK: - Helpers
    private enum PickedImageMode { case topGap, bottomGap, landscape }

    private var drawerTitle: String {
        switch activeDrawer {
        case .ratioAndOverlays: return "Layout, Crop & Overlays"
        case .accounts: return "Stream Accounts"
        case .diagnostics: return "Stream Health"
        case .hardwareSettings: return "Resolution, FPS & Mic"
        case .none: return ""
        }
    }

    private func diagGlassCard(label: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundColor(.white.opacity(0.55))
            Text(value)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundColor(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(glassStroke, lineWidth: 1))
    }

    private func refreshDiagnostics() {
        isAppGroupOK = AppGroupBridge.groupAvailable
        diagnostics = AppGroupBridge.loadDiagnostics()
        hasRecording = AppGroupBridge.hasRecordedVideo
    }

    private func glassDockButton(title: String, icon: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button {
            triggerUIHaptic()
            withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) { action() }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                Text(title)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(active ? Color.white.opacity(0.24) : Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .foregroundColor(.white)
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(glassStroke, lineWidth: 1))
        }
    }

    private func triggerUIHaptic() {
        guard settings.enableUIHaptics else { return }
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.impactOccurred()
    }

    private func handlePickedImage(item: PhotosPickerItem?, mode: PickedImageMode) {
        guard let item = item else { return }
        let currentOpacity = settings.gapOverlayOpacity
        Task.detached(priority: .userInitiated) {
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let rawImg = UIImage(data: data) else { return }
            let scaled = AppGroupBridge.downscaleImage(rawImg, maxDimension: mode == .landscape ? 1920 : 1080)
            switch mode {
            case .topGap:
                AppGroupBridge.saveRawGapImage(scaled, isTop: true)
            case .bottomGap:
                AppGroupBridge.saveRawGapImage(scaled, isTop: false)
            case .landscape:
                AppGroupBridge.saveRawLandscapeImage(scaled)
            }
            AppGroupBridge.bakeStaticOverlays(opacity: currentOpacity)
            await MainActor.run {
                switch mode {
                case .topGap: topGapPreview = scaled
                case .bottomGap: bottomGapPreview = scaled
                case .landscape: landscapeOverlayPreview = scaled
                }
            }
        }
    }
}

@main
struct PulseLiteApp: App {
    var body: some Scene {
        WindowGroup {
            PulseLiteDeckView()
        }
    }
}
