import Foundation

/// Parses an `URLSession.AsyncBytes` (or any other line-yielding async
/// byte sequence) as **newline-delimited JSON** — what Lichess uses for
/// every long-lived stream (`/api/stream/event`,
/// `/api/board/game/stream/{id}`, `/api/board/seek`).
///
/// Behaviour:
///   * Empty lines are skipped — they are Lichess' keep-alive heartbeats.
///   * Whitespace-only lines (rare) are skipped likewise.
///   * Decode failures on a single line are skipped silently. Our event
///     enums already model `case unknown(type:)` for forward-compat
///     against new event shapes, so a decode failure on a recognised
///     type would be either a transient line-fragment or a logic bug;
///     in either case, throwing here would tear down a perfectly good
///     stream over a single bad frame, which is worse for the user than
///     dropping that frame.
///   * Network failures (the underlying byte sequence throws) propagate
///     out so the reconnect loop in the stream actor can back off.
///
/// The returned stream is a one-shot `AsyncThrowingStream`: when it
/// finishes (clean EOF or error), reconnect logic in the caller starts a
/// new request and re-subscribes.
enum NDJSON {

    /// Wraps a URLSession byte stream into typed events. The cancellation
    /// of the consuming task tears down both the JSON pump and the
    /// underlying URL data task.
    static func stream<T: Decodable & Sendable>(
        from bytes: URLSession.AsyncBytes,
        as type: T.Type,
        decoder: JSONDecoder = JSONDecoder()
    ) -> AsyncThrowingStream<T, Error> {
        AsyncThrowingStream<T, Error> { continuation in
            let task = Task {
                do {
                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        guard !trimmed.isEmpty else { continue }
                        let data = Data(trimmed.utf8)
                        if let event = try? decoder.decode(T.self, from: data) {
                            continuation.yield(event)
                        }
                        // else: silently drop. See doc comment.
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

extension URLSession {

    /// Dedicated `URLSession` for long-lived Lichess NDJSON streams.
    ///
    /// `URLSession.shared` has a 60-second resource timeout that would
    /// kill a quiet game stream during the opponent's think time. We
    /// override:
    ///   * `timeoutIntervalForRequest = 60` — give the initial response
    ///     a minute to start (covers slow first-byte on cold paths).
    ///   * `timeoutIntervalForResource = effectively unbounded` — never
    ///     timeout a connection that's actively producing bytes (even
    ///     just heartbeats).
    ///   * `waitsForConnectivity = true` — brief connectivity drops queue
    ///     instead of failing immediately, which is what we want before
    ///     the explicit reconnect loop kicks in.
    static let lichessStreaming: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = TimeInterval.greatestFiniteMagnitude / 2
        config.waitsForConnectivity = true
        config.httpAdditionalHeaders = ["Accept": "application/x-ndjson"]
        return URLSession(configuration: config)
    }()
}
