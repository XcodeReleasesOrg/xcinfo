//
//  Copyright © 2022 xcodereleases.com
//  MIT license - see LICENSE.md
//

import Foundation

public struct ProcessResult: Sendable, Equatable {
    public var exitStatus: Int32
    public var stdout: String
    public var stderr: String

    public init(exitStatus: Int32, stdout: String = "", stderr: String = "") {
        self.exitStatus = exitStatus
        self.stdout = stdout
        self.stderr = stderr
    }
}

struct ProcessRunner {
    static func run(_ command: String, arguments: [String]) async throws -> ProcessResult {
        try await launch(executable: URL(fileURLWithPath: "/usr/bin/env"), arguments: [command] + arguments, input: nil)
    }

    static func runPrivileged(_ command: String, password: String, arguments: [String]) async throws -> ProcessResult {
        try await launch(
            executable: URL(fileURLWithPath: "/usr/bin/sudo"),
            arguments: ["-S", command] + arguments,
            input: Data("\(password)\n".utf8)
        )
    }

    private static func launch(executable: URL, arguments: [String], input: Data?) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        let stdinPipe = input.map { _ in Pipe() }
        if let stdinPipe {
            process.standardInput = stdinPipe
        }

        let (terminations, termination) = AsyncStream.makeStream(of: Int32.self)
        process.terminationHandler = { process in
            termination.yield(process.terminationStatus)
            termination.finish()
        }
        try process.run()
        if let stdinPipe, let input {
            stdinPipe.fileHandleForWriting.write(input)
            try? stdinPipe.fileHandleForWriting.close()
        }

        async let stdout = readToEnd(stdoutPipe)
        async let stderr = readToEnd(stderrPipe)
        var exitStatus: Int32 = -1
        for await status in terminations {
            exitStatus = status
        }
        return await ProcessResult(exitStatus: exitStatus, stdout: stdout, stderr: stderr)
    }

    private static func readToEnd(_ pipe: Pipe) async -> String {
        let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
