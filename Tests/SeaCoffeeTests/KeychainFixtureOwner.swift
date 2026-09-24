import Foundation
import Security
import LocalAuthentication
let service = CommandLine.arguments[1]
let context = LAContext(); context.interactionNotAllowed = true
let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: service, kSecAttrAccount as String: "fixture",
    kSecUseAuthenticationContext as String: context]
if CommandLine.arguments.contains("cleanup") {
    let result = SecItemDelete(query as CFDictionary)
    exit(result == errSecSuccess || result == errSecItemNotFound ? 0 : 1)
}

var insert = query; insert[kSecValueData as String] = Data("local-signing-fixture".utf8)
let status = SecItemAdd(insert as CFDictionary, nil)
guard status == errSecSuccess else { print("FAIL test item creation: \(status)"); exit(1) }
print("PASS first build created isolated test credential")

