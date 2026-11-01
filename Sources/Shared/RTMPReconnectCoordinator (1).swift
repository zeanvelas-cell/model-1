// RTMPReconnectCoordinator.swift
// PulseLite — Sources/Shared/RTMPReconnectCoordinator.swift
//
// Automatic reconnect with exponential backoff for HaishinKit 2.2.5.
// Meant to live INSIDE THE BROADCAST EXTENSION (that is where the RTMP
// connection runs). It has no UI code: it reports state through the
// `onStateChange` closure, and the extension can write that into the
// App Group so the app screen can show it.
//
// HOW TO USE (in SampleHandler):
//   let coordinator = RTMPReconnectCoordinator(
//       connection: connection,          // your existing RTMPConnection
//       stream: stream,                  // your existing RTMPStream
//       config: .init(ingestURL: url, streamKey: key),
//       onStateChange: { state in /* save state.displayString to App Group */ })
//   await coordinator.start()            // replaces connection.connect + stream.publish
//   ...
//   await coordinator.stop()             // replaces connection.close + stream.close

import Foundation
import Network

// Only compiled in targets that link HaishinKit's RTMP library (app + broadcast extension).
#if canImport(RTMPHaishinKit)
import HaishinKit
import RTMPHaishinKit

// MARK: - State

enum RTMPConnectionState: Equatable, Sendable {
    case idle
    case connecting(attempt: Int)
    case live
    case reconnecting(attempt: Int, of: Int, delay: Int)   // delay in whole seconds
    case failed(reason: String)
    case disconnected

    var displayString: String {
        switch self {
        case .idle:                                  return "Ready"
        case .connecting(let a):                     return a <= 1 ? "Connecting…" : "Connecting… (try \(a))"
        case .live:                                  return "LIVE"
        case .reconnecting(let a, let n, let d):     return "Reconnecting in \(d)s… (\(a)/\(n))"
        case .failed(let reason):                    return "Failed: \(reason)"
        case .disconnected:                          return "Stopped"
        }
    }

    /// SF Symbol name for the UI.
    var sfSymbol: String {
        switch self {
        case .idle:          return "antenna.radiowaves.left.and.right.slash"
        case .connecting:    return "arrow.clockwise"
        case .live:          return "dot.radiowaves.left.and.right"
        case .reconnecting:  return "arrow.triangle.2.circlepath"
        case .failed:        return "exclamationmark.triangle.fill"
        case .disconnected:  return "stop.circle"
        }
    }
}

// MARK: - Coordinator

actor RTMPReconnectCoordinator {

    struct Config: Sendable {
        var ingestURL: String                 // e.g. "rtmps://a.rtmp.youtube.com:443/live2"
        var streamKey: String
        var maxRetries: Int = 8               // give up after this many failed tries in a row (once live)
        var initialAttempts: Int = 2          // before the FIRST successful connect: give up after this many tries (bad key = fast error)
        var baseDelay: Double = 2.0           // 2, 4, 8, 16, 32, 60, 60... seconds
        var jitter: Double = 0.3              // +/- 30% randomness
    }

    private let connection: RTMPConnection
    private let stream: RTMPStream
    private var config: Config
    private let onStateChange: @Sendable (RTMPConnectionState) -> Void

    private(set) var state: RTMPConnectionState = .idle
    private var sessionTask: Task<Void, Never>?
    private var pathMonitor: NWPathMonitor?
    private var lastPathSignature: String?

    init(connection: RTMPConnection,
         stream: RTMPStream,
         config: Config,
         onStateChange: @escaping @Sendable (RTMPConnectionState) -> Void) {
        self.connection = connection
        self.stream = stream
        self.config = config
        self.onStateChange = onStateChange
    }

    // MARK: Public

    /// Connect, publish, and keep the stream alive until `stop()`.
    func start() {
        sessionTask?.cancel()
        startPathMonitor()
        sessionTask = Task { await self.run() }
    }

    /// Change URL / key. Takes effect on the next (re)connect.
    func updateConfig(_ newConfig: Config) {
        config = newConfig
    }

    /// Waits for the first connection. true = live, false = gave up before ever going live.
    func waitForFirstResult() async -> Bool {
        while !Task.isCancelled {
            switch state {
            case .live: return true
            case .failed, .disconnected: return false
            default: try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }
        return false
    }

    /// User pressed Retry after `.failed`.
    func retry() {
        start()
    }

    /// Clean stop. No reconnect afterwards.
    func stop() async {
        sessionTask?.cancel()
        sessionTask = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        _ = try? await stream.close()
        try? await connection.close()
        setState(.disconnected)
    }

    // MARK: Main loop

    private func run() async {
        var failures = 0
        var hasBeenLive = false
        var reason = "Unknown error"

        while !Task.isCancelled {
            setState(.connecting(attempt: failures + 1))

            // Subscribe to connection events BEFORE connecting so none are missed.
            let events = await connection.status

            do {
                _ = try await connection.connect(config.ingestURL)
                _ = try await stream.publish(config.streamKey)
                failures = 0
                hasBeenLive = true
                setState(.live)

                // Stay here until the connection drops.
                for await event in events {
                    if Task.isCancelled { break }
                    if Self.isDrop(event.code) {
                        reason = "Connection lost"
                        break
                    }
                }
            } catch {
                reason = error.localizedDescription
            }

            if Task.isCancelled { return }

            // Clean up so connect() is allowed again (it throws if still connected).
            try? await connection.close()

            failures += 1
            let gaveUp = hasBeenLive ? (failures > config.maxRetries) : (failures >= config.initialAttempts)
            if gaveUp {
                setState(.failed(reason: reason))
                return
            }

            let delay = backoff(for: failures)
            setState(.reconnecting(attempt: failures, of: config.maxRetries, delay: Int(delay.rounded(.up))))
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }

    private static func isDrop(_ code: String) -> Bool {
        switch code {
        case RTMPConnection.Code.connectClosed.rawValue,
             RTMPConnection.Code.connectFailed.rawValue,
             RTMPConnection.Code.connectIdleTimeOut.rawValue,
             RTMPConnection.Code.connectAppshutdown.rawValue,
             RTMPConnection.Code.connectRejected.rawValue:
            return true
        default:
            return false
        }
    }

    private func backoff(for attempt: Int) -> Double {
        let exp = min(config.baseDelay * pow(2.0, Double(attempt - 1)), 60.0)
        let jitter = exp * config.jitter * Double.random(in: -1...1)
        return max(1.0, exp + jitter)
    }

    private func setState(_ newState: RTMPConnectionState) {
        state = newState
        onStateChange(newState)
    }

    // MARK: Network change (Wi-Fi <-> mobile data)

    private func startPathMonitor() {
        pathMonitor?.cancel()
        lastPathSignature = nil
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let kinds = [NWInterface.InterfaceType.wifi, .cellular, .wiredEthernet]
                .filter { path.usesInterfaceType($0) }
                .map { "\($0)" }
                .joined(separator: ",")
            let signature = "\(path.status)-\(kinds)"
            Task { await self?.pathChanged(signature) }
        }
        monitor.start(queue: DispatchQueue(label: "pulselite.netpath"))
        pathMonitor = monitor
    }

    private func pathChanged(_ signature: String) async {
        defer { lastPathSignature = signature }
        guard let last = lastPathSignature, last != signature else { return }
        // Network switched while streaming: drop the old socket so the main loop
        // sees the close event and reconnects on the new network.
        if state == .live {
            try? await connection.close()
        }
    }
}

#endif
