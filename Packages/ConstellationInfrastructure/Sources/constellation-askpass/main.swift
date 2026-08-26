// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-3.0-only

import ConstellationOpenSSH
import Foundation

// ssh runs this with the prompt as argv[1]. The answer is printed to stdout.
// A non-zero exit with no output means "no answer"; ssh then fails the step.

let environment = ProcessInfo.processInfo.environment
guard let portName = environment[AskPass.EnvironmentKey.port],
      let token = environment[AskPass.EnvironmentKey.token] else {
    FileHandle.standardError.write(Data("constellation-askpass: not launched by Constellation\n".utf8))
    exit(1)
}

let prompt = CommandLine.arguments.dropFirst().first ?? ""
let request = AskPass.Request(
    token: token,
    kind: AskPass.promptKind(sshPromptVariable: environment["SSH_ASKPASS_PROMPT"], promptText: prompt),
    prompt: prompt,
    credentialID: environment[AskPass.EnvironmentKey.credentialID])

guard let port = CFMessagePortCreateRemote(nil, portName as CFString) else {
    FileHandle.standardError.write(Data("constellation-askpass: Constellation is not listening\n".utf8))
    exit(1)
}

let payload = try JSONEncoder().encode(request)
var reply: Unmanaged<CFData>?
// The app may be waiting on the user, so allow a long reply window.
let status = CFMessagePortSendRequest(port, 1, payload as CFData, 10, 300, CFRunLoopMode.defaultMode.rawValue, &reply)
guard status == kCFMessagePortSuccess, let replyData = reply?.takeRetainedValue() as Data?,
      let response = try? JSONDecoder().decode(AskPass.Response.self, from: replyData) else {
    exit(1)
}

if let output = response.sshOutput {
    FileHandle.standardOutput.write(Data((output + "\n").utf8))
    exit(0)
}
exit(1)
