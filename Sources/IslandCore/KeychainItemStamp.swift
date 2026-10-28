import Foundation

/// One version of a Keychain item, from the creation and modification dates that
/// `security find-generic-password` prints without `-w`. Reading these never touches the secret.
public struct KeychainItemStamp: Equatable, Sendable {
    public let created: String
    public let modified: String

    public static func parse(_ output: String) -> Self? {
        func date(_ attribute: String) -> String? {
            guard let line = output.split(separator: "\n").first(where: { $0.contains("\"\(attribute)\"<timedate>=") }),
                  let open = line.firstIndex(of: "\"", after: "=") else { return nil }
            let value = line[line.index(after: open)...].prefix { $0.isNumber || $0 == "Z" }
            return value.count == 15 && value.hasSuffix("Z") ? String(value) : nil
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

private extension Substring {
    /// The first `character` after the first `marker`.
    func firstIndex(of character: Character, after marker: Character) -> Index? {
        guard let start = firstIndex(of: marker) else { return nil }
        return self[index(after: start)...].firstIndex(of: character)
    }
}
