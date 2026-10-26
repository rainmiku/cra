import Foundation
import Security
import SQLite3

// The key Chromium encrypts Cra's cookies and saved passwords with: PBKDF2 of a
// random secret in Cra's own login-Keychain item. scripts/patch-cef-keychain.sh
// renames CEF's built-in "Chromium Safe Storage" item to this one, so Chromium and
// the importer share it.
//
// Builds before this ran Chromium with --use-mock-keychain, whose secret is the
// public "mock_password". The first launch with an old profile re-encrypts those
// values before Chromium opens the databases; until that succeeds Chromium keeps
// the mock key, so nothing becomes unreadable.

enum SafeStorage {
    static let service = "Cra Data Safe Storage"
    static let account = "Chromium"
    static let mockKey = ChromiumCrypto.key(fromSecret: "mock_password")

    /// True while the profile still uses the mock key (migration pending).
    private(set) static var usesMockKey = false

    /// Read once per launch; nil when the Keychain refuses (the user denied access).
    private static let keychainKey: Data? = secret().map(ChromiumCrypto.key(fromSecret:))

    /// The key the profile's databases and staged imports are encrypted with.
    static var profileKey: Data? { usesMockKey ? mockKey : keychainKey }

    private static var marker: URL { AppPaths.file("safe-storage-migrated") }
    /// Chromium's encrypted databases in the profile directory.
    private static let databases = ["Cookies", "Extension Cookies", "Login Data", "Login Data For Account", "Web Data", "Account Web Data"]
    /// Set in a database's meta table in the transaction that re-encrypts it.
    private static let metaKey = "cra_safe_storage_migrated"

    /// Called from main.swift before Chromium starts. Moves a profile written with
    /// the mock key to the Keychain key once, or keeps Chromium on the mock key for
    /// this launch when that is not possible yet.
    static func prepare(profileDir: URL) {
        guard !FileManager.default.fileExists(atPath: marker.path) else { return }
        if let key = keychainKey, migrate(databases.map { profileDir.appendingPathComponent($0) }, to: key),
           CredentialImport.reencryptPending(from: mockKey, to: key),
           FileManager.default.createFile(atPath: marker.path, contents: nil) {
            return
        }
        NSLog("Cra: cookies and passwords stay on the old key this launch (Keychain %@)", keychainKey == nil ? "unavailable" : "available")
        usesMockKey = true
        setenv("CRA_MOCK_KEYCHAIN", "1", 1)  // read by CraCEF.mm
    }

    /// All or nothing, so Chromium never sees some databases on each key: every
    /// database is re-encrypted in its own transaction, and they commit only when
    /// all succeeded. A missing database has nothing to migrate; a busy one fails
    /// the whole migration, which is retried next launch.
    private static func migrate(_ urls: [URL], to key: Data) -> Bool {
        var open: [OpaquePointer] = []
        defer { for db in open { sqlite3_exec(db, "ROLLBACK", nil, nil, nil); sqlite3_close(db) } }
        for url in urls where FileManager.default.fileExists(atPath: url.path) {
            var db: OpaquePointer?
            guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else { sqlite3_close(db); return false }
            open.append(db)
            sqlite3_busy_timeout(db, 500)
            guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK, reencrypt(db, to: key) else { return false }
            NSLog("Cra: re-encrypting %@ with the Keychain key", url.lastPathComponent)
        }
        return open.allSatisfy { sqlite3_exec($0, "COMMIT", nil, nil, nil) == SQLITE_OK }
    }

    /// Re-encrypts every v10 value in the database's BLOB columns and marks the
    /// database done, which keeps a retry after a partial commit from touching it again.
    private static func reencrypt(_ db: OpaquePointer, to key: Data) -> Bool {
        guard SQLite.rows(db, "SELECT 1 FROM meta WHERE key = '\(metaKey)'").isEmpty else { return true }
        let tables = SQLite.rows(db, "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'").compactMap { $0["name"] as? String }
        for table in tables {
            let blobColumns = SQLite.rows(db, "SELECT name FROM pragma_table_info('\(table)') WHERE upper(type) = 'BLOB'").compactMap { $0["name"] as? String }
            for column in blobColumns {
                for row in SQLite.rows(db, "SELECT rowid AS r, \"\(column)\" AS v FROM \"\(table)\" WHERE substr(\"\(column)\", 1, 3) = CAST('v10' AS BLOB)") {
                    // A value the mock key cannot open is unreadable either way; it stays as is.
                    guard let rowid = row["r"] as? Int64, let blob = row["v"] as? Data,
                          let plain = ChromiumCrypto.decrypt(blob, key: mockKey) else { continue }
                    guard run(db, "UPDATE \"\(table)\" SET \"\(column)\" = ? WHERE rowid = ?", [ChromiumCrypto.encrypt(plain, key: key), rowid]) else { return false }
                }
            }
        }
        return run(db, "INSERT OR REPLACE INTO meta (key, value) VALUES (?, '1')", [metaKey])
    }

    private static func run(_ db: OpaquePointer?, _ sql: String, _ values: [Any?]) -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        SQLite.bind(stmt, values)
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    /// Cra's secret, created the way Chromium creates it (16 random bytes, base64)
    /// when the item does not exist yet. Blocks on the Keychain prompt, if any.
    private static func secret() -> String? {
        let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        var result: AnyObject?
        var status = SecItemCopyMatching(item.merging([kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]) { $1 } as CFDictionary, &result)
        if status == errSecItemNotFound {
            var bytes = [UInt8](repeating: 0, count: 16)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
            let secret = Data(bytes).base64EncodedString()
            status = SecItemAdd(item.merging([kSecValueData as String: Data(secret.utf8)]) { $1 } as CFDictionary, nil)
            if status == errSecSuccess { return secret }
            if status == errSecDuplicateItem { return ChromiumCrypto.keychainSecret(service: service, account: account) }
        }
        guard status == errSecSuccess, let data = result as? Data else {
            NSLog("Cra: Keychain item %@ unavailable (%d)", service, status)
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}
