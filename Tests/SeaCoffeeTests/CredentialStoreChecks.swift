import Foundation
import IslandCore
import Security

// scripts/check-credentials.sh compiles the real store with an isolated service name and a temporary file.
@main enum CredentialStoreChecks {
    static func main() throws {
        let service = CommandLine.arguments[1]
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("seacoffee-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        SecureStore.file = CredentialFile(url: root.appendingPathComponent("credentials.json"))
        let account = "store-fixture"
        func legacy(_ value: String?) {
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service, kSecAttrAccount as String: account]
            SecItemDelete(query as CFDictionary)
            guard let value else { return }
            var insert = query; insert[kSecValueData as String] = Data(value.utf8)
            precondition(SecItemAdd(insert as CFDictionary, nil) == errSecSuccess)
        }
        defer { legacy(nil) }

        legacy("from-old-build")
        try check(SecureStore.containsKey(account: account), "Existence sees an unimported legacy item")
        try check(SecureStore.read(account: account) == "from-old-build", "Legacy item is imported")
        try check(SecureStore.file.value(account) == "from-old-build", "Imported value is persisted")
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account]
        try check(SecItemCopyMatching(query as CFDictionary, nil) == errSecItemNotFound, "Legacy item is removed")

        try SecureStore.writeAndVerify("fixture-two", account: account)
        legacy("stale-old-build")
        try check(SecureStore.read(account: account) == "fixture-two", "A newer value is never replaced by a legacy copy")
        try SecureStore.write("", account: account)
        try check(SecureStore.read(account: account) == nil, "Logout clears the value")
        try check(!SecureStore.containsKey(account: account), "Migrated absence ignores stale legacy items")
        print("PASS file store, verification, replacement, deletion, and one-time legacy import (isolated test service)")
    }
    static func check(_ value: @autoclosure () throws -> Bool, _ message: String = "") rethrows { let passed = try value(); precondition(passed, message) }
}
