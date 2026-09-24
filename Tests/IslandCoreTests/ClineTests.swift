import Foundation
import IslandCore

final class ClineTests {
    private func data(_ value: String) -> Data { Data(value.utf8) }

    func windows() throws {
        let usage = try ClineProtocol.usage(data(#"{"success":true,"data":{"limits":[{"type":"monthly","percentUsed":110},{"type":"five_hour","percentUsed":25.5,"resetsAt":"2026-09-22T12:00:00Z"},{"type":"weekly","percentUsed":0}]}}"#))
        expectEqual(usage.quotas.map(\.label), ["5 小时", "每周", "每月"])
        expectEqual(usage.quotas.map(\.percent), [75, 100, 0])
        expectEqual(usage.quotas.map(\.monetary), [false, false, false])
        expectEqual(usage.quotas.first?.resetsAt, UsageDecoder.date("2026-09-22T12:00:00Z"))
        expectNil(usage.balance)
        expectEqual(usage.source, "Cline Pass")
    }

    func invalidUsage() {
        for json in [
            #"{"success":true,"data":{"limits":[]}}"#,
            #"{"success":false,"data":{"limits":[{"type":"weekly","percentUsed":0}]}}"#,
            #"{"success":true,"data":{"limits":[{"type":"weekly"}]}}"#,
            #"{"success":true,"data":{"limits":[{"type":"weekly","percentUsed":true}]}}"#,
            #"{"success":true,"data":{"limits":[{"type":"weekly","percentUsed":"nan"}]}}"#,
            #"{"success":true,"data":{"limits":[{"type":"weekly","percentUsed":-1}]}}"#
        ] { expectThrows(try ClineProtocol.usage(data(json))) }
    }

    func tokens() throws {
        let first = try ClineCredentials.parse(data(#"{"success":true,"data":{"accessToken":"access1","refreshToken":"refresh1","expiresAt":"2026-09-23T00:00:00Z","userInfo":{"email":"test@example.com"}}}"#))
        let rotated = try ClineCredentials.parse(data(#"{"success":true,"data":{"accessToken":"access2","refreshToken":"refresh2","expiresAt":"2026-09-24T00:00:00Z"}}"#), previous: first)
        expectEqual(rotated.refreshToken, "refresh2")
        expectEqual(rotated.email, "test@example.com")
        let retained = try ClineCredentials.parse(data(#"{"success":true,"data":{"accessToken":"access3","expiresAt":"2026-09-25T00:00:00Z"}}"#), previous: rotated)
        expectEqual(retained.refreshToken, "refresh2")
        expectEqual(retained.accessToken, "access3")
        let restored = try JSONDecoder().decode(ClineCredentials.self, from: JSONEncoder().encode(retained))
        expectEqual(restored.expiresAt, retained.expiresAt)
        expectEqual(restored.refreshToken, retained.refreshToken)
        expectThrows(try ClineCredentials.parse(data(#"{"success":true,"data":{"accessToken":"a","expiresAt":"2026-09-25T00:00:00Z"}}"#)))
        expectThrows(try ClineCredentials.parse(data(#"{"success":true,"data":{"accessToken":"","refreshToken":"r","expiresAt":"invalid"}}"#)))
    }

    func deviceAuthorization() throws {
        let auth = try ClineDeviceAuthorization.parse(data(#"{"device_code":"secret","user_code":"ABCD","verification_uri":"https://auth.cline.bot/device","expires_in":300,"interval":5}"#))
        expectEqual(auth.userCode, "ABCD")
        expectEqual(auth.interval, 5)
        for url in ["http://auth.cline.bot/device", "https://cline.bot.evil.example/device", "https://evil.example/device", "https://user:pass@auth.cline.bot/device"] {
            let body = try JSONSerialization.data(withJSONObject: ["device_code": "d", "user_code": "u", "verification_uri": url])
            expectThrows(try ClineDeviceAuthorization.parse(body))
        }
        expectThrows(try ClineDeviceAuthorization.parse(data(#"{"device_code":"d","user_code":"u","verification_uri":"https://auth.cline.bot/device","interval":-1}"#)))
    }

    func polling() throws {
        expectEqual(try ClineProtocol.poll(data(#"{"error":"authorization_pending"}"#), status: 400), .pending)
        expectEqual(try ClineProtocol.poll(data(#"{"error":"slow_down"}"#), status: 400), .slowDown)
        expectEqual(try ClineProtocol.poll(data(#"{"access_token":"a","refresh_token":"r"}"#), status: 200), .authorized(access: "a", refresh: "r"))
        for error in ["access_denied", "expired_token", "invalid_grant", "server_error"] {
            expectThrows(try ClineProtocol.poll(data("{\"error\":\"\(error)\"}"), status: 400))
        }
        expectThrows(try ClineProtocol.poll(data(#"{"access_token":"a"}"#), status: 200))
        expectThrows(try ClineProtocol.poll(data(#"{"access_token":"a","refresh_token":"r"}"#), status: 500))
    }

    func authorizationAndErrors() throws {
        expectEqual(ClineProtocol.authorizationHeader("test-jwt"), "Bearer workos:test-jwt")
        expectEqual(ClineProtocol.authorizationHeader("workos:test-jwt"), "Bearer workos:test-jwt")
        try ClineProtocol.validateUsageStatus(200)
        do {
            try ClineProtocol.validateUsageStatus(401)
            expectEqual(true, false, "401 must reject credentials")
        } catch ClineError.signedOut { }
        do {
            try ClineProtocol.validateUsageStatus(403)
            expectEqual(true, false, "403 must report denied access")
        } catch ClineError.forbidden { }
        expectThrows(try ClineProtocol.validateUsageStatus(500))
        expectThrows(try ClineProtocol.validateUsageStatus(404))
    }

    func formEncoding() {
        expectEqual(String(decoding: ClineProtocol.form(["code": "a+b &c=d/中文"]), as: UTF8.self),
                    "code=a%2Bb%20%26c%3Dd%2F%E4%B8%AD%E6%96%87")
    }
}
