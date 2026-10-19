import Foundation

struct ProcessResult: Equatable, Sendable {
    let status: Int32
    let stdout: String
    let stderr: String
}

enum ProcessError: Error, Equatable {
    case timedOut(seconds: TimeInterval)
}

enum ProcessRunner {
    /// Runs `executable` to completion off the main thread, terminating it after `timeout`.
    /// With `log`, stdout and stderr go to that file instead (long-running programs): the result's text is empty.
    static func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval = 10,
                    environment: [String: String]? = nil, log: URL? = nil) async throws -> ProcessResult {
        try await Task.detached(priority: .userInitiated) {
            try runBlocking(executable, arguments, timeout: timeout, environment: environment, log: log)
        }.value
    }

    // Output goes to temp files rather than pipes so a chatty child can never fill a pipe buffer and deadlock.
    private static func runBlocking(_ executable: URL, _ arguments: [String], timeout: TimeInterval,
                                    environment: [String: String]?, log: URL?) throws -> ProcessResult {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appending(path: "machub-\(UUID().uuidString)")
        let outURL = base.appendingPathExtension("out"), errURL = base.appendingPathExtension("err")
        fm.createFile(atPath: outURL.path, contents: nil)
        fm.createFile(atPath: errURL.path, contents: nil)
        defer {
            try? fm.removeItem(at: outURL)
            try? fm.removeItem(at: errURL)
        }
        let outHandle: FileHandle, errHandle: FileHandle
        if let log {
            try fm.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !fm.fileExists(atPath: log.path) { fm.createFile(atPath: log.path, contents: nil) }
            outHandle = try FileHandle(forWritingTo: log)
            outHandle.seekToEndOfFile()
            errHandle = outHandle
        } else {
            outHandle = try FileHandle(forWritingTo: outURL)
            errHandle = try FileHandle(forWritingTo: errURL)
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new } }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outHandle
        process.standardError = errHandle
        try process.run()

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if Date() >= deadline {
                process.terminate()
                process.waitUntilExit()
                throw ProcessError.timedOut(seconds: timeout)
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        try? outHandle.close()
        try? errHandle.close()

        func read(_ url: URL) -> String { String(decoding: (try? Data(contentsOf: url)) ?? Data(), as: UTF8.self) }
        return ProcessResult(status: process.terminationStatus, stdout: read(outURL), stderr: read(errURL))
    }
}
