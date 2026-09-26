import Foundation
import IslandCore
import Security
@main enum DeniedReader {
 static func main() throws {
  var before = DarwinBoolean(false)
  precondition(SecKeychainGetUserInteractionAllowed(&before) == errSecSuccess)
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("seacoffee-denied-\(UUID().uuidString)")
  defer { try? FileManager.default.removeItem(at: root) }
  SecureStore.file = CredentialFile(url: root.appendingPathComponent("credentials.json"))
  let start=Date()
  for _ in 0..<5 {
   do {
    _ = try SecureStore.read(account: "fixture")
    fatalError("Read unexpectedly authorized")
   } catch {
    let status=(error as NSError).code
    precondition(status == Int(errSecInteractionNotAllowed) || status == Int(errSecAuthFailed), "Unexpected status: \(status)")
   }
  }
  var after=DarwinBoolean(false)
  precondition(SecKeychainGetUserInteractionAllowed(&after) == errSecSuccess)
  precondition(before.boolValue == after.boolValue)
  precondition(Date().timeIntervalSince(start)<3)
  // An unreadable legacy item is not absence: it must stay eligible for a later authorized import.
  let migrated = try SecureStore.file.read().migrated
  precondition(migrated.isEmpty)
  print("PASS 5 unauthorized legacy imports returned promptly; not marked migrated; interaction setting restored")
 }
}
