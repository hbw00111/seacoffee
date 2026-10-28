import Foundation

/// One version of a Keychain item, from the creation and modification dates that
/// `security find-generic-password` prints without `-w`. Reading these never touches the secret.
public struct KeychainItemStamp: Equatable, Sendable {
    public let created: String
    public let modified: String

    public static func parse(_ output: String) -> Self? {
        // e.g. `    "mdat"<timedate>=0x3230…5A00  "20261028011947Z\000"`
        func date(_ attribute: String) -> String? {
            guard let line = output.split(separator: "\n").first(where: { $0.contains("\"\(attribute)\"<timedate>=") })
            else { return nil }
            let parts = line.split(separator: "\"", omittingEmptySubsequences: false)
            guard parts.count > 3 else { return nil }
            let value = parts[3].prefix(15)
            return value.count == 15 && value.last == "Z" && value.dropLast().allSatisfy(\.isNumber) ? String(value) : nil
        }
        guard let created = date("cdat"), let modified = date("mdat") else { return nil }
        return Self(created: created, modified: modified)
    }

    /// Whether the item was rewritten in between. Nil when either side could not be read,
    /// so an unreadable item is never taken as a renewal or as a failed one.
    public static func changed(from before: Self?, to after: Self?) -> Bool? {
        guard let before, let after else { return nil }
        return before != after
    }
}
