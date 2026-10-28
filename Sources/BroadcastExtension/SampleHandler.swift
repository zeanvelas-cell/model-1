import ReplayKit
import AVFoundation
import VideoToolbox
import HaishinKit
import RTMPHaishinKit

private actor LocalRecordingCoordinator {
    private var assetWriter: AVAssetWriter?
    private var videoWriterInput: AVAssetWriterInput?
    private var audioWriterInput: AVAssetWriterInput?
    private var isSessionStarted = false
    private var lastPts: CMTime = .zero
    private var isFinished = false

    init(enabled: Bool, size: CGSize, bitrateBps: Int) {
        guard enabled, let fileURL = AppGroupBridge.recordedVideoURL else { return }
        try? FileManager.default.removeItem(at: fileURL)

        guard let writer = try? AVAssetWriter(outputURL: fileURL, fileType: .mp4) else { return }
        writer.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)

        let vSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrateBps,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoAllowFrameReorderingKey: false
            ]
        ]
        let vInput = AVAssetWriterInput(mediaType: .video, outputSettings: vSettings)
        vInput.expectsMediaDataInRealTime = true

        let aSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128000
        ]
        let aInput = AVAssetWriterInput(mediaType: .audio, outputSettings: aSettings)
        aInput.expectsMediaDataInRealTime = true

        if writer.canAdd(vInput) { writer.add(vInput) }
        if writer.canAdd(aInput) { writer.add(aInput) }

        writer.startWriting()
        self.assetWriter = writer
        self.videoWriterInput = vInput
        self.audioWriterInput = aInput
    }

    func append(_ sampleBuffer: CMSampleBuffer, isVideo: Bool) {
        guard !isFinished, let writer = assetWriter, writer.status == .writing else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard pts.isValid && !pts.isIndefinite else { return }

        if !isSessionStarted {
            guard isVideo else { return }
            writer.startSession(atSourceTime: pts)
            isSessionStarted = true
        }

        if isVideo && lastPts.isValid && pts <= lastPts {
            return
        }
        if isVideo {
            lastPts = pts
        }

        if isVideo, let vInput = videoWriterInput, vInput.isReadyForMoreMediaData {
            vInput.append(sampleBuffer)
        } else if !isVideo, let aInput = audioWriterInput, aInput.isReadyForMoreMediaData {
            aInput.append(sampleBuffer)
        }
    }

    func finish() async {
        guard !isFinished else { return }
        isFinished = true
        guard let writer = assetWriter, writer.status == .writing, isSessionStarted else { return }
        videoWriterInput?.markAsFinished()
        audioWriterInput?.markAsFinished()
        if lastPts.isValid && lastPts != .zero {
            writer.endSession(atSourceTime: lastPts)
        }
        await writer.finishWriting()
    }
}

public final class SampleHandler: RPBroadcastSampleHandler, @unchecked Sendable {
    private let mixer = MediaMixer(captureSessionMode: .manual, multiTrackAudioMixingEnabled: true)
    private let rtmpConnection = RTMPConnection()
    private lazy var rtmpStream = RTMPStream(connection: rtmpConnection)

    private var videoContinuation: AsyncStream<CMSampleBuffer>.Continuation?
    private var audioContinuation: AsyncStream<(CMSampleBuffer, UInt8)>.Continuation?
    private var videoTask: Task<Void, Never>?
    private var audioTask: Task<Void, Never>?
    private var recorderCoordinator: LocalRecordingCoordinator?
    private var thermalObserver: NSObjectProtocol?
    private var activeCompositor: FrameCompositor?

    private let stateLock = NSLock()
    private var shouldThrottleTo30FPS: Bool = false
    private var isBroadcastPaused: Bool = false
    private var incomingVideoFrameIndex: UInt64 = 0
    private var droppedVideoFrames: Int = 0
    private var includeMicAudio: Bool = true
    private var voiceChatMode: InGameVoiceChatMode = .preLockDualMic

    private func updateSyncState(
        includeMic: Bool? = nil,
        voiceMode: InGameVoiceChatMode? = nil,
        throttle30: Bool? = nil,
        paused: Bool? = nil
    ) {
        stateLock.lock()
        defer { stateLock.unlock() }
        if let includeMic = includeMic { self.includeMicAudio = includeMic }
        if let voiceMode = voiceMode { self.voiceChatMode = voiceMode }
        if let throttle30 = throttle30 { self.shouldThrottleTo30FPS = throttle30 }
        if let paused = paused { self.isBroadcastPaused = paused }
    }

    private func readDroppedFramesSync() -> Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return droppedVideoFrames
    }

    private func recordDroppedFrameSync() {
        stateLock.lock()
        droppedVideoFrames += 1
        stateLock.unlock()
    }

    private func shouldProcessVideoFrameSync() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !isBroadcastPaused else { return false }
        incomingVideoFrameIndex += 1
        if shouldThrottleTo30FPS && (incomingVideoFrameIndex % 2 != 0) {
            return false
        }
        return true
    }

    private func shouldProcessAudioPacketSync(isMic: Bool) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !isBroadcastPaused else { return false }
        if isMic {
            if voiceChatMode == .squadOnlyGameMic { return false }
            return includeMicAudio
        }
        return true
    }

    /// Configures the extension's AVAudioSession WITHOUT `.defaultToSpeaker` (so headphones are respected and speaker echo never happens).
    private func configureExtensionAudioSession(mode: InGameVoiceChatMode) {
        let session = AVAudioSession.sharedInstance()
        do {
            if mode == .preLockDualMic {
                try session.setCategory(
                    .playAndRecord,
                    mode: .voiceChat,
                    options: [.mixWithOthers, .allowBluetooth, .allowBluetoothA2DP]
                )
            } else {
                try session.setCategory(
                    .ambient,
                    mode: .default,
                    options: [.mixWithOthers]
                )
            }
        } catch {
            // Ignore if managed by iOS ReplayKit daemon
        }
    }

    public override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        var initialSettings = AppGroupBridge.loadSettings()

        let setupKey = (setupInfo?["streamKey"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let setupIngest = (setupInfo?["ingestURL"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !setupIngest.isEmpty {
            initialSettings.ingestServerURL = setupIngest
        }
        if let setupAspect = setupInfo?["aspectMode"] as? String,
           let parsedAspect = StreamAspectMode(rawValue: setupAspect) {
            initialSettings.aspectMode = parsedAspect
        }

        let activeKey = AppGroupBridge.activeAccount()?.primaryStreamKey ?? setupKey ?? ""

        guard !activeKey.isEmpty else {
            let reason = "No Stream Key found. Open PulseLite -> Accounts to save your key, or paste your key in the Broadcast Setup sheet."
            AppGroupBridge.updateDiagnostics(status: "Failed: Missing Stream Key")
            finishBroadcastWithError(NSError(
                domain: "PulseLiteBroadcast",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: reason]
            ))
            return
        }

        configureExtensionAudioSession(mode: initialSettings.voiceChatMode)
        updateSyncState(
            includeMic: initialSettings.includeMicrophoneAudio,
            voiceMode: initialSettings.voiceChatMode,
            throttle30: (initialSettings.targetFPS == 30),
            paused: false
        )

        AppGroupBridge.updateDiagnostics(
            currentMemMB: AppGroupBridge.currentProcessAvailableMemoryMB(),
            framesEncoded: 0,
            framesDropped: 0,
            status: "Initializing pipeline..."
        )

        let compositor = FrameCompositor(settings: initialSettings)
        self.activeCompositor = compositor

        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observerPtr = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            center,
            observerPtr,
            { _, observer, _, _, _ in
                guard let observer = observer else { return }
                let handler = Unmanaged<SampleHandler>.fromOpaque(observer).takeUnretainedValue()
                handler.reloadLiveSettingsFromBridge()
            },
            AppGroupBridge.reloadNotificationName as CFString,
            nil,
            .deliverImmediately
        )
        CFNotificationCenterAddObserver(
            center,
            observerPtr,
            { _, observer, _, _, _ in
                guard let observer = observer else { return }
                let handler = Unmanaged<SampleHandler>.fromOpaque(observer).takeUnretainedValue()
                handler.reloadLiveOverlaysFromBridge()
            },
            AppGroupBridge.reloadOverlaysNotificationName as CFString,
            nil,
            .deliverImmediately
        )

        let targetSize = initialSettings.resolvedCanvasSize

        let recorder = LocalRecordingCoordinator(
            enabled: initialSettings.enableLocalRecording,
            size: targetSize,
            bitrateBps: initialSettings.targetBitrateKbps * 1000
        )
        self.recorderCoordinator = recorder

        let vStream = AsyncStream<CMSampleBuffer>(bufferingPolicy: .bufferingNewest(2)) { cont in
            self.videoContinuation = cont
        }

        let aStream = AsyncStream<(CMSampleBuffer, UInt8)>(bufferingPolicy: .bufferingNewest(64)) { cont in
            self.audioContinuation = cont
        }

        if initialSettings.enableThermalAutoGuard {
            thermalObserver = NotificationCenter.default.addObserver(
                forName: ProcessInfo.thermalStateDidChangeNotification,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                self?.handleThermalChange(
                    state: ProcessInfo.processInfo.thermalState,
                    targetSize: targetSize
                )
            }
        }

        videoTask = Task {
            var videoMixerSettings = await mixer.videoMixerSettings
            videoMixerSettings.mode = .passthrough
            await mixer.setVideoMixerSettings(videoMixerSettings)

            var audioSettings = await rtmpStream.audioSettings
            audioSettings.bitRate = 128 * 1000
            try? await rtmpStream.setAudioSettings(audioSettings)

            await applyHardwareEncoder(
                size: targetSize,
                fps: initialSettings.targetFPS,
                bitrateKbps: initialSettings.targetBitrateKbps
            )

            await mixer.addOutput(rtmpStream)
            await mixer.startRunning()

            let connected = await connectAndPublishWithRetry(
                ingestURL: initialSettings.ingestServerURL,
                streamKey: activeKey
            )
            guard connected else { return }

            self.audioTask = Task {
                for await (audioBuffer, trackIndex) in aStream {
                    if Task.isCancelled { break }
                    if trackIndex == 0 && initialSettings.enableLocalRecording {
                        await recorder.append(audioBuffer, isVideo: false)
                    }
                    await mixer.append(audioBuffer, track: trackIndex)
                }
            }

            var encodedCount = 0
            for await rawVideoBuffer in vStream {
                if Task.isCancelled { break }
                guard let processed = compositor.processVideoSampleBuffer(rawVideoBuffer) else { continue }
                if initialSettings.enableLocalRecording {
                    await recorder.append(processed, isVideo: true)
                }
                await mixer.append(processed)
                encodedCount += 1

                if encodedCount % 60 == 0 {
                    let drops = self.readDroppedFramesSync()
                    AppGroupBridge.updateDiagnostics(
                        currentMemMB: AppGroupBridge.currentProcessAvailableMemoryMB(),
                        framesEncoded: encodedCount,
                        framesDropped: drops
                    )
                }
            }
        }
    }

    private func connectAndPublishWithRetry(ingestURL: String, streamKey: String) async -> Bool {
        let maxAttempts = 2
        for attempt in 1...maxAttempts {
            do {
                AppGroupBridge.updateDiagnostics(status: attempt == 1 ? "Connecting to RTMPS..." : "Reconnecting (Attempt \(attempt))...")
                _ = try await rtmpConnection.connect(ingestURL)
                _ = try await rtmpStream.publish(streamKey)
                AppGroupBridge.updateDiagnostics(
                    currentMemMB: AppGroupBridge.currentProcessAvailableMemoryMB(),
                    status: "LIVE on Stream"
                )
                return true
            } catch {
                if attempt == maxAttempts {
                    AppGroupBridge.updateDiagnostics(status: "RTMPS Error: \(error.localizedDescription)")
                    finishBroadcastWithError(error)
                    return false
                }
                try? await Task.sleep(nanoseconds: 1_200_000_000)
            }
        }
        return false
    }

    private func reloadLiveSettingsFromBridge() {
        let updated = AppGroupBridge.loadSettings()
        configureExtensionAudioSession(mode: updated.voiceChatMode)
        updateSyncState(
            includeMic: updated.includeMicrophoneAudio,
            voiceMode: updated.voiceChatMode
        )
        activeCompositor?.updateLiveSettings(updated)
    }

    private func reloadLiveOverlaysFromBridge() {
        activeCompositor?.reloadOverlaysFromDisk()
    }

    public override func broadcastPaused() {
        updateSyncState(paused: true)
        AppGroupBridge.updateDiagnostics(status: "Broadcast Paused by iOS")
    }

    public override func broadcastResumed() {
        updateSyncState(paused: false)
        AppGroupBridge.updateDiagnostics(status: "LIVE on Stream (Resumed)")
    }

    public override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard sampleBuffer.dataReadiness == .ready else { return }

        switch sampleBufferType {
        case .video:
            guard shouldProcessVideoFrameSync() else { return }
            if case .dropped = videoContinuation?.yield(sampleBuffer) {
                recordDroppedFrameSync()
            }

        case .audioApp:
            guard shouldProcessAudioPacketSync(isMic: false) else { return }
            _ = audioContinuation?.yield((sampleBuffer, 0))

        case .audioMic:
            guard shouldProcessAudioPacketSync(isMic: true) else { return }
            _ = audioContinuation?.yield((sampleBuffer, 1))

        @unknown default:
            break
        }
    }

    public override func broadcastFinished() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observerPtr = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterRemoveEveryObserver(center, observerPtr)

        if let observer = thermalObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        videoContinuation?.finish()
        audioContinuation?.finish()

        let semaphore = DispatchSemaphore(value: 0)
        Task {
            _ = await videoTask?.value
            _ = await audioTask?.value
            await recorderCoordinator?.finish()

            try? await rtmpStream.close()
            try? await rtmpConnection.close()
            await mixer.stopRunning()
            AppGroupBridge.updateDiagnostics(
                currentMemMB: AppGroupBridge.currentProcessAvailableMemoryMB(),
                status: "Broadcast finished cleanly"
            )
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 2.5)
    }

    private func handleThermalChange(
        state: ProcessInfo.ThermalState,
        targetSize: CGSize
    ) {
        // Reload latest live settings so mid-stream bitrate/FPS adjustments are respected
        let latestSettings = AppGroupBridge.loadSettings()
        let throttle30: Bool
        let targetBitrate: Int
        let statusNote: String

        switch state {
        case .nominal, .fair:
            throttle30 = (latestSettings.targetFPS == 30)
            targetBitrate = latestSettings.targetBitrateKbps
            statusNote = "LIVE (Thermal Nominal)"
        case .serious:
            throttle30 = true
            targetBitrate = min(latestSettings.targetBitrateKbps, 3500)
            statusNote = "LIVE (Thermal Serious: 30fps Guard)"
        case .critical:
            throttle30 = true
            targetBitrate = 2500
            statusNote = "LIVE (Thermal Critical: 2.5Mbps Guard)"
        @unknown default:
            return
        }

        updateSyncState(throttle30: throttle30)

        Task {
            await applyHardwareEncoder(
                size: targetSize,
                fps: throttle30 ? 30 : latestSettings.targetFPS,
                bitrateKbps: targetBitrate
            )
            AppGroupBridge.updateDiagnostics(status: statusNote)
        }
    }

    private func applyHardwareEncoder(size: CGSize, fps: Int, bitrateKbps: Int) async {
        await mixer.setFrameRate(Float64(fps))
        var videoSettings = await rtmpStream.videoSettings
        videoSettings.videoSize = size
        videoSettings.bitRate = bitrateKbps * 1000
        videoSettings.profileLevel = kVTProfileLevel_H264_High_AutoLevel as String
        videoSettings.maxKeyFrameIntervalDuration = 2
        videoSettings.allowFrameReordering = false
        try? await rtmpStream.setVideoSettings(videoSettings)
    }
}