import Foundation
import Security

// scripts/check-credentials.sh compiles the real store with an isolated service name.
@main enum CredentialCacheChecks {
    static func main() throws {
        let account = "cache-fixture"
        defer { try? SecureStore.write("", account: account) }
        try check(SecureStore.read(account: account) == nil)
        try SecureStore.write("fixture-one", account: account)
        try check(SecureStore.read(account: account) == "fixture-one")
        // Remove only our test item directly, bypassing the in-process cache.
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: CommandLine.arguments[1], kSecAttrAccount as String: account]
        precondition(SecItemDelete(query as CFDictionary) == errSecSuccess)
        try check(SecureStore.read(account: account) == "fixture-one", "Repeated refresh should use memory")
        try check(SecureStore.read(account: account, useCache: false) == nil, "Verification must consult Keychain")
        try SecureStore.write("fixture-two", account: account)
        try check(SecureStore.read(account: account) == "fixture-two", "Saving replaces the cached absence")
        try SecureStore.write("fixture-three", account: account)
        try check(SecureStore.read(account: account) == "fixture-three", "Saving replaces the old value")
        try SecureStore.write("", account: account)
        try check(SecureStore.read(account: account) == nil, "Logout clears the cache")
        print("PASS credential caching, verification bypass, replacement, and deletion (isolated test service)")
    }
    static func check(_ value: @autoclosure () throws -> Bool, _ message: String = "") rethrows { let passed = try value(); precondition(passed, message) }
}
