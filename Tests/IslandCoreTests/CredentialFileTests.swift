import Foundation
import IslandCore

final class CredentialFileTests {
    private func sandbox() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("seacoffee-credentials-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func mode(_ url: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    func roundTripAndPermissions() throws {
        let root = try sandbox(); defer { try? FileManager.default.removeItem(at: root) }
        let file = CredentialFile(url: root.appendingPathComponent("SeaIsland/credentials.json"))
        expectEqual(try file.read(), CredentialFile.Contents(), "missing file is empty")
        try file.update { $0.secrets["sub2api"] = "sk-one"; $0.migrated.insert("sub2api") }
        expectEqual(try file.value("sub2api"), "sk-one")
        expectEqual(try file.read().migrated, ["sub2api"])
        expectEqual(try mode(file.url), 0o600)
        expectEqual(try mode(file.url.deletingLastPathComponent()), 0o700)
        try file.update { $0.secrets["sub2api"] = "sk-two" }
        expectEqual(try file.value("sub2api"), "sk-two")
        try file.update { $0.secrets["sub2api"] = nil }
        expectNil(try file.value("sub2api"))
        // Staging directories never outlive a write.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: file.url.deletingLastPathComponent().path)
        expectEqual(leftovers, ["credentials.json"])
    }

    func unsafeFiles() throws {
        let root = try sandbox(); defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("elsewhere.json")
        try Data(#"{"version":1,"secrets":{"a":"b"},"migrated":[]}"#.utf8).write(to: target)
        let link = CredentialFile(url: root.appendingPathComponent("link.json"))
        try FileManager.default.createSymbolicLink(at: link.url, withDestinationURL: target)
        expectThrows(try link.read())
        // Loose permissions from outside tampering are tightened on read.
        let loose = CredentialFile(url: target)
        chmod(target.path, 0o644)
        expectEqual(try loose.value("a"), "b")
        expectEqual(try mode(target), 0o600)
        try Data("not json".utf8).write(to: target)
        expectThrows(try loose.read())
    }
}
