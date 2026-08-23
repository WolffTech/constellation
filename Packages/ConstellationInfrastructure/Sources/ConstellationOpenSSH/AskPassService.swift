import Foundation
import os

let askPassLog = Logger(subsystem: "tech.wolff.Constellation", category: "askpass")

/// Resolves an opaque credential id to its secret. The app backs this with
/// Keychain; tests use a dictionary.
public protocol AskPassSecretProvider: Sendable {
    func secret(for credentialID: String) -> String?
}

public struct InMemorySecretProvider: AskPassSecretProvider {
    private let secrets: [String: String]
    public init(_ secrets: [String: String]) { self.secrets = secrets }
    public func secret(for credentialID: String) -> String? { secrets[credentialID] }
}

/// App-side listener for `constellation-askpass`.
///
/// Each ssh launch registers a one-shot token; a request must present a live
/// token or it is denied. Prompts the app cannot answer from the vault go to
/// `userPrompt`, which may block on UI (the helper waits up to five minutes).
@MainActor
public final class AskPassService {
    public typealias UserPrompt = @MainActor (AskPass.Request) -> AskPass.Response

    public let portName: String
    private let secrets: any AskPassSecretProvider
    private let userPrompt: UserPrompt
    private var liveTokens: Set<String> = []
    private var port: CFMessagePort?
    private var source: CFRunLoopSource?

    public init(secrets: any AskPassSecretProvider, userPrompt: @escaping UserPrompt) throws {
        self.portName = AskPass.portName(pid: getpid())
        self.secrets = secrets
        self.userPrompt = userPrompt

        var context = CFMessagePortContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)
        guard let port = CFMessagePortCreateLocal(nil, portName as CFString, { _, _, data, info in
            guard let info else { return nil }
            let service = Unmanaged<AskPassService>.fromOpaque(info).takeUnretainedValue()
            let response = MainActor.assumeIsolated { service.handle(data.map { $0 as Data }) }
            guard let encoded = try? JSONEncoder().encode(response) else { return nil }
            return Unmanaged.passRetained(encoded as CFData)
        }, &context, nil) else {
            throw AskPassServiceError.portUnavailable(portName)
        }
        self.port = port
        let source = CFMessagePortCreateRunLoopSource(nil, port, 0)
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    isolated deinit {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let port { CFMessagePortInvalidate(port) }
    }

    /// Issues a fresh token for one ssh launch.
    public func registerLaunch() -> String {
        let token = UUID().uuidString
        liveTokens.insert(token)
        return token
    }

    public func endLaunch(token: String) {
        liveTokens.remove(token)
    }

    /// Environment the ssh process needs to reach this service.
    public func environment(token: String, credentialID: String?, helperPath: String) -> [String: String] {
        var env = [
            "SSH_ASKPASS": helperPath,
            "SSH_ASKPASS_REQUIRE": "force",
            AskPass.EnvironmentKey.port: portName,
            AskPass.EnvironmentKey.token: token,
        ]
        if let credentialID { env[AskPass.EnvironmentKey.credentialID] = credentialID }
        return env
    }

    func handle(_ data: Data?) -> AskPass.Response {
        guard let data, let request = try? JSONDecoder().decode(AskPass.Request.self, from: data),
              liveTokens.contains(request.token) else {
            askPassLog.debug("askpass request denied (bytes=\(data?.count ?? -1, privacy: .public))")
            return .denied
        }
        askPassLog.debug("askpass request kind=\(request.kind.rawValue, privacy: .public) credential=\(request.credentialID ?? "-", privacy: .public)")
        switch request.kind {
        case .secret:
            if let id = request.credentialID, let secret = secrets.secret(for: id) {
                return .secret(secret)
            }
            return userPrompt(request)
        case .confirm:
            return userPrompt(request)
        case .none:
            return .confirmed(true)
        }
    }
}

public enum AskPassServiceError: Error, Sendable {
    case portUnavailable(String)
}
