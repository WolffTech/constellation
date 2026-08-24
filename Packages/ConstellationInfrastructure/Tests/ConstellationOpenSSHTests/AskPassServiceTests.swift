import Foundation
import Testing
@testable import ConstellationOpenSSH

@MainActor
struct AskPassServiceTests {
    private struct NoSecrets: AskPassSecretProvider {
        func secret(for credentialID: String) -> String? { nil }
    }

    @Test func aCancelledPromptRetiresTheLaunchSoRetriesStayQuiet() throws {
        var prompts = 0
        let service = try AskPassService(secrets: NoSecrets()) { _ in
            prompts += 1
            return .denied
        }
        let token = service.registerLaunch()
        let request = try JSONEncoder().encode(AskPass.Request(
            token: token, kind: .secret, prompt: "temp@box's password: ", credentialID: nil))

        #expect(service.handle(request) == .denied)
        #expect(service.handle(request) == .denied)
        #expect(service.handle(request) == .denied)
        #expect(prompts == 1)
    }

    @Test func anAnsweredPromptKeepsTheLaunchAlive() throws {
        var prompts = 0
        let service = try AskPassService(secrets: NoSecrets()) { _ in
            prompts += 1
            return .secret("hunter2")
        }
        let token = service.registerLaunch()
        let request = try JSONEncoder().encode(AskPass.Request(
            token: token, kind: .secret, prompt: "temp@box's password: ", credentialID: nil))

        #expect(service.handle(request) == .secret("hunter2"))
        #expect(service.handle(request) == .secret("hunter2"))
        #expect(prompts == 2)
    }
}
