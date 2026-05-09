import Testing
import Foundation
@testable import LiveChess

/// Round-trip tests for the keychain-backed token store.
///
/// Each test uses a unique `service` string so the suite is order- and
/// parallel-safe and never collides with the production keychain entry.
/// The `defer { try? store.delete() }` blocks are best-effort cleanup so
/// a failing test doesn't leave dangling keychain items behind.
@Suite("LichessTokenStore", .serialized)
struct LichessTokenStoreTests {

    private func makeStore(_ tag: String = #function) -> LichessTokenStore {
        // Stable but unique per test method, so re-running an individual
        // test repeatedly hits the same entry (helpful when debugging) and
        // different methods can run in any order.
        LichessTokenStore(service: "test.LiveChess.lichess.\(tag)", account: "oauth-token")
    }

    @Test
    func loadReturnsNilWhenStoreIsEmpty() async throws {
        let store = makeStore()
        try await store.delete()  // make sure we start clean

        let loaded = try await store.load()
        #expect(loaded == nil)
    }

    @Test
    func saveThenLoadRoundTrip() async throws {
        let store = makeStore()
        defer { Task { try? await store.delete() } }

        let token = StoredToken(
            accessToken: "abc-XYZ_123-456",
            scope: "board:play challenge:write preference:read",
            expiresAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        try await store.save(token)

        let loaded = try await store.load()
        #expect(loaded == token)
    }

    @Test
    func saveOverwritesPreviousEntry() async throws {
        let store = makeStore()
        defer { Task { try? await store.delete() } }

        let first = StoredToken(
            accessToken: "first-token",
            scope: "board:play",
            expiresAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let second = StoredToken(
            accessToken: "second-token",
            scope: "board:play challenge:write",
            expiresAt: Date(timeIntervalSince1970: 1_900_000_000)
        )
        try await store.save(first)
        try await store.save(second)

        let loaded = try await store.load()
        #expect(loaded == second)
    }

    @Test
    func deleteRemovesEntry() async throws {
        let store = makeStore()

        let token = StoredToken(
            accessToken: "to-be-deleted",
            scope: "board:play",
            expiresAt: Date(timeIntervalSince1970: 2_000_000_000)
        )
        try await store.save(token)
        #expect(try await store.load() != nil)

        try await store.delete()
        #expect(try await store.load() == nil)
    }

    @Test
    func deleteOnEmptyStoreDoesNotThrow() async throws {
        let store = makeStore()
        try await store.delete()  // first call clears
        // Second call must be a no-op error-wise (idempotent logout).
        try await store.delete()
    }

    @Test
    func isExpiredReturnsTrueForPastTokens() {
        let token = StoredToken(
            accessToken: "stale",
            scope: "board:play",
            expiresAt: Date(timeIntervalSinceNow: -3600)
        )
        #expect(token.isExpired)
    }

    @Test
    func isExpiredReturnsFalseForFreshTokens() {
        let token = StoredToken(
            accessToken: "fresh",
            scope: "board:play",
            expiresAt: Date(timeIntervalSinceNow: 31_536_000)  // ~1 year
        )
        #expect(!token.isExpired)
    }

    @Test
    func isExpiredReturnsTrueWithinSixtySecondGuard() {
        // Tokens within 60s of expiry are treated as already expired so a
        // request kicked off right at the boundary doesn't race the server.
        let token = StoredToken(
            accessToken: "almost-stale",
            scope: "board:play",
            expiresAt: Date(timeIntervalSinceNow: 30)
        )
        #expect(token.isExpired)
    }
}
