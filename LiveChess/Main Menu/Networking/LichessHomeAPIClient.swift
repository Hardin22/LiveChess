import Foundation

/// Low-level HTTP client for the Lichess REST API used by the home
/// screen. Single-purpose: build a request, hit Lichess, decode the
/// response. Errors propagate to the caller (the `LichessService`)
/// which decides how to surface them in the UI.
///
/// An `actor` so the auth token + URLSession state is serialised even
/// if multiple ViewModels race to load data on launch.
actor LichessHomeAPIClient {

    private let baseURL = URL(string: "https://lichess.org")!
    private let session: URLSession
    private var authToken: String?

    init() {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = 20
        self.session = URLSession(configuration: config)
    }

    /// Set the OAuth bearer used for authenticated endpoints
    /// (e.g. `/api/account/playing`). Public endpoints work without it.
    func setAuthToken(_ token: String?) {
        self.authToken = token
    }

    // MARK: - JSON

    /// GET `endpoint` as JSON and decode into `T`. Optional query items
    /// are appended to the URL.
    func request<T: Decodable>(
        endpoint: String,
        queryItems: [URLQueryItem]? = nil
    ) async throws -> T {
        let url = try buildURL(endpoint: endpoint, queryItems: queryItems)
        var req = URLRequest(url: url)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        applyAuth(to: &req)

        let (data, response) = try await session.data(for: req)
        try Self.validate(response: response, data: data)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw LichessAPIError.decoding(error)
        }
    }

    // MARK: - NDJSON

    /// GET `endpoint` as newline-delimited JSON, decoding each line into
    /// `T`. Stops after `maxResults`. Lichess uses this format for
    /// streaming endpoints like `/api/games/user/{username}`.
    func requestNDJSON<T: Decodable>(
        endpoint: String,
        queryItems: [URLQueryItem],
        maxResults: Int
    ) async throws -> [T] {
        let url = try buildURL(endpoint: endpoint, queryItems: queryItems)
        var req = URLRequest(url: url)
        req.setValue("application/x-ndjson", forHTTPHeaderField: "Accept")
        applyAuth(to: &req)

        let (data, response) = try await session.data(for: req)
        try Self.validate(response: response, data: data)

        let decoder = JSONDecoder()
        var out: [T] = []
        out.reserveCapacity(min(maxResults, 32))
        // 0x0A is '\n'. Skipping empty/whitespace-only lines keeps the
        // loop resilient against trailing newlines from the server.
        for slice in data.split(separator: 0x0A) where !slice.isEmpty {
            if out.count >= maxResults { break }
            do {
                let item = try decoder.decode(T.self, from: Data(slice))
                out.append(item)
            } catch {
                // Skip malformed lines rather than aborting the whole
                // page — Lichess occasionally streams partial frames.
                continue
            }
        }
        return out
    }

    // MARK: - Helpers

    private func buildURL(endpoint: String, queryItems: [URLQueryItem]?) throws -> URL {
        let path = endpoint.hasPrefix("/") ? endpoint : "/" + endpoint
        var comps = URLComponents()
        comps.scheme = baseURL.scheme
        comps.host = baseURL.host
        comps.path = path
        if let queryItems, !queryItems.isEmpty {
            comps.queryItems = queryItems
        }
        guard let url = comps.url else { throw LichessAPIError.badURL }
        return url
    }

    private func applyAuth(to req: inout URLRequest) {
        if let authToken, !authToken.isEmpty {
            req.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        }
    }

    private static func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw LichessAPIError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw LichessAPIError.http(status: http.statusCode, body: data)
        }
    }
}

// MARK: - Errors

enum LichessAPIError: Error, LocalizedError {
    case badURL
    case invalidResponse
    case http(status: Int, body: Data)
    case decoding(Error)

    var errorDescription: String? {
        switch self {
        case .badURL:           "Invalid URL."
        case .invalidResponse:  "Invalid response from Lichess."
        case .http(let status, _): "Lichess returned HTTP \(status)."
        case .decoding(let e):  "Could not parse Lichess response: \(e.localizedDescription)"
        }
    }
}
