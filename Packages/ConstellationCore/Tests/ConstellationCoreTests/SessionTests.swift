import Testing
@testable import ConstellationCore

struct QuickConnectTargetTests {
    @Test func parsesSupportedTargets() throws {
        #expect(try QuickConnectTarget(parsing: "box.local") == QuickConnectTarget(host: "box.local"))
        #expect(try QuickConnectTarget(parsing: "nick@box.local:2222") == QuickConnectTarget(host: "box.local", username: "nick", port: 2222))
        #expect(try QuickConnectTarget(parsing: "[fe80::1]:2200") == QuickConnectTarget(host: "fe80::1", port: 2200))
        #expect(try QuickConnectTarget(parsing: "nick@fe80::1") == QuickConnectTarget(host: "fe80::1", username: "nick"))
    }

    @Test func rejectsMalformedTargets() {
        #expect(throws: QuickConnectError.self) { try QuickConnectTarget(parsing: "") }
        #expect(throws: QuickConnectError.self) { try QuickConnectTarget(parsing: "box:abc") }
        #expect(throws: QuickConnectError.validation(.invalidPort(70_000))) {
            try QuickConnectTarget(parsing: "box:70000")
        }
    }

    @Test func formatsIPv6WithoutAmbiguity() {
        #expect(QuickConnectTarget(host: "fe80::1", username: "nick", port: 2222).displayName == "nick@[fe80::1]:2222")
    }
}
