import Foundation
import Observation

/// Tracks the global "players online" count that Lichess publishes on
/// its homepage footer. There's no REST endpoint for this number —
/// Lichess pushes it over a WebSocket (`wss://socket*.lichess.org`)
/// as `{"t":"n","d":<int>}` messages, the same channel the lichess.org
/// site's footer reads from.
///
/// Usage: instantiate once on `AppModel`, call `start()` when the
/// home menu appears, `stop()` when the app backgrounds. The
/// `@Observable` `count` updates SwiftUI views automatically.
@MainActor
@Observable
final class LichessOnlineCountTracker {

    /// Most recently received online-player count, or `nil` before the
    /// first server message lands (typically within a second of
    /// connect). Views that show this should render "Online" without a
    /// number while it's nil to avoid flashing "0".
    private(set) var count: Int?

    private var task: URLSessionWebSocketTask?
    private var receiveLoop: Task<Void, Never>?
    private var pingLoop: Task<Void, Never>?
    private var isRunning = false

    /// Opens the WebSocket and starts listening. Idempotent — calling
    /// twice is a no-op while a connection is alive. Auto-reconnect
    /// is handled inside the receive loop on failure.
    func start() {
        guard !isRunning else { return }
        isRunning = true
        connect()
    }

    /// Closes the WebSocket cleanly. Safe to call multiple times.
    func stop() {
        isRunning = false
        receiveLoop?.cancel()
        pingLoop?.cancel()
        receiveLoop = nil
        pingLoop = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    // MARK: - Internals

    private func connect() {
        // Lichess accepts client-supplied `sri` (Session Random Id);
        // 8 random alphanumeric chars are enough to disambiguate this
        // connection from other ones from the same IP.
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        let sri = String((0..<8).map { _ in alphabet.randomElement()! })
        // socket0..5 are all valid — pick one at random so we don't
        // pile every visit onto the same shard.
        let shard = Int.random(in: 0...5)
        guard let url = URL(string:
            "wss://socket\(shard).lichess.org/socket/v5?sri=\(sri)"
        ) else { return }

        var request = URLRequest(url: url)
        request.setValue("https://lichess.org", forHTTPHeaderField: "Origin")
        let newTask = URLSession.shared.webSocketTask(with: request)
        self.task = newTask
        newTask.resume()

        receiveLoop = Task { [weak self] in
            await self?.runReceiveLoop(on: newTask)
        }
        pingLoop = Task { [weak self] in
            await self?.runPingLoop(on: newTask)
        }
    }

    private func runReceiveLoop(on task: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            do {
                let message = try await task.receive()
                handle(message: message)
            } catch {
                // Connection dropped. Wait a beat then reconnect if
                // start() hasn't been cancelled in the meantime.
                if !isRunning { return }
                try? await Task.sleep(for: .seconds(5))
                if isRunning {
                    // Tear the old task down before spinning a new one.
                    self.task?.cancel(with: .abnormalClosure, reason: nil)
                    self.task = nil
                    self.pingLoop?.cancel()
                    connect()
                }
                return
            }
        }
    }

    private func runPingLoop(on task: URLSessionWebSocketTask) async {
        // Lichess closes idle sockets after ~10s of silence. A "null"
        // text frame every 10s is the standard heartbeat their JS
        // client uses.
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(10))
            if Task.isCancelled { return }
            try? await task.send(.string("null"))
        }
    }

    private func handle(message: URLSessionWebSocketTask.Message) {
        let text: String
        switch message {
        case .string(let s): text = s
        case .data(let d):   text = String(decoding: d, as: UTF8.self)
        @unknown default:    return
        }
        guard !text.isEmpty, text != "0" else { return }  // "0" is a pong-like heartbeat
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        // The "n" message carries the connected-player count on the
        // primary socket version: { "t": "n", "d": 12345 } (or "{t,d}"
        // with `d` as a dict in newer shards — handle both).
        guard (obj["t"] as? String) == "n" else { return }
        if let n = obj["d"] as? Int {
            count = n
        } else if let dict = obj["d"] as? [String: Any],
                  let n = dict["nbPlayers"] as? Int ?? dict["d"] as? Int {
            count = n
        }
    }
}
