import Darwin
import Foundation

import GohCore

// goh — CLI client. Thin. Talks to the daemon (`gohd`) over XPC and exits fast.

func write(_ text: String, to handle: FileHandle) {
    guard !text.isEmpty else { return }
    handle.write(Data(text.utf8))
}

let arguments = Array(CommandLine.arguments.dropFirst())

switch arguments {
case ["auth", "import", "safari"]:
    let command = AuthImportSafariCommand { request in
        let validationMode = GohXPCService.peerValidationMode(
            environment: ProcessInfo.processInfo.environment)
        let client = try GohXPCClient(
            machServiceName: GohXPCService.machServiceName,
            mode: validationMode)
        defer { client.cancel() }
        return try client.sendSync(request)
    }
    let result = command.run()
    write(result.standardOutput, to: .standardOutput)
    write(result.standardError, to: .standardError)
    exit(result.exitCode)
default:
    print("goh")
}
