import Foundation
import Security
@main enum DeniedReader {
 static func main() throws {
  var before = DarwinBoolean(false)
  precondition(SecKeychainGetUserInteractionAllowed(&before) == errSecSuccess)
  let start=Date()
  for _ in 0..<5 {
   do {
    _ = try SecureStore.read(account: "fixture", useCache: false)
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
  print("PASS 5 unauthorized reads returned promptly; interaction setting restored")
 }
}
