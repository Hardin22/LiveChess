import Foundation
import Security

/// The bearer token returned by Lichess' OAuth token endpoint, plus everything
/// the app needs to know whether it's still usable.
///
/// `expiresAt` is precomputed at exchange time (`Date() + expires_in`) so the
/// app can short-circuit a network call when the token is obviously stale.
/// `scope` is kept around so we can refuse to call an endpoint whose required
/// scope wasn't granted (better diagnostics than a server-side 403).
struct StoredToken: Sendable, Codable, Equatable {
    let accessToken: String
    let scope: String
    let expiresAt: Date

    /// True when the token's TTL has already elapsed. We treat anything
    /// within 60 s of expiry as already expired so a request kicked off at
    /// the boundary doesn't race.
    var isExpired: Bool {
        Date() >= expiresAt.addingTimeInterval(-60)
    }
}

/// Keychain-backed persistence for the Lichess OAuth bearer token.
///
/// We use `kSecClassGenericPassword` (the standard for app-issued
/// credentials) with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`
/// accessibility, which:
///
///   * keeps the token available across app launches and reboots after the
///     user has unlocked the device once,
///   * scopes it to *this* device only, so a tap on "Restore from iCloud
///     backup" on a new device does not also restore the Lichess session
///     (the user will be asked to re-authenticate),
///   * prevents export to off-device backups.
///
/// All operations are funnelled through the actor so concurrent callers
/// (e.g. the auth service writing while the API client reads) cannot race
/// on a shared keychain entry. Keychain SPI is itself thread-safe, but
/// serialising at the Swift layer also avoids races on `isExpired` checks
/// the higher layers may want to do.
actor LichessTokenStore {

    /// Default service identifier used in production; tests construct the
    /// store with a unique service so they don't trample on the prod entry.
    static let defaultService = "com.francescoalbano.LiveChess.lichess"
    static let defaultAccount = "oauth-token"

    enum StoreError: Error, Sendable, Equatable {
        /// Wraps a non-success `OSStatus` from the Security framework. The
        /// numeric value is preserved so callers can match on
        /// `errSecAuthFailed`, `errSecDuplicateItem`, etc. when needed.
        case keychain(OSStatus)
        /// The stored blob couldn't be decoded into `StoredToken`. Usually
        /// means the schema changed under us; the wipe-and-reauth fallback
        /// is fine.
        case decoding
    }

    private let service: String
    private let account: String

    init(
        service: String = LichessTokenStore.defaultService,
        account: String = LichessTokenStore.defaultAccount
    ) {
        self.service = service
        self.account = account
    }

    /// Reads the previously-saved token, if any. Returns `nil` when the
    /// keychain entry is absent (the typical "first launch" case); throws
    /// only on actual keychain failures.
    func load() throws -> StoredToken? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw StoreError.keychain(status)
        }
        guard let data = item as? Data else {
            throw StoreError.decoding
        }
        do {
            return try Self.decoder.decode(StoredToken.self, from: data)
        } catch {
            throw StoreError.decoding
        }
    }

    /// Persists the token, overwriting any previous entry for the same
    /// `service`/`account` pair. We do an explicit `SecItemDelete` first
    /// rather than `SecItemUpdate` so the accessibility attribute is
    /// guaranteed to be the one we want, even if a prior version of the
    /// app had used a less restrictive setting.
    func save(_ token: StoredToken) throws {
        let data = try Self.encoder.encode(token)
        var attributes = baseQuery()
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] =
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        // Idempotent overwrite: ignore "not found" on the delete, since the
        // first save on a fresh install will hit it.
        let deleteStatus = SecItemDelete(baseQuery() as CFDictionary)
        guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
            throw StoreError.keychain(deleteStatus)
        }

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw StoreError.keychain(status)
        }
    }

    /// Drops the stored token. Calling this on an already-empty store is a
    /// no-op (logout flow needs to be safe to call any number of times).
    func delete() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw StoreError.keychain(status)
        }
    }

    // MARK: - Private

    /// Common query attributes shared by load/save/delete.
    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
