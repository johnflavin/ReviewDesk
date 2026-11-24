import Foundation

struct ShellResult: Sendable {
    var status: Int32
    var stdout: String
    var stderr: String
    var timedOut = false
}

struct ShellError: LocalizedError {
    var command: String
    var status: Int32
    var output: String

    var errorDescription: String? {
        let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return "`\(command)` failed (exit \(status))" + (detail.isEmpty ? "" : ": \(detail.suffix(1200))")
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

enum Shell {
    /// Runs a command to completion. Cancelling the calling task terminates the process.
    static func run(_ executable: String, _ arguments: [String], cwd: String? = nil, input: Data? = nil,
                    env: [String: String] = [:]) async throws -> ShellResult {
        let process = makeProcess(executable, arguments, cwd: cwd, env: env)
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let stdin: Pipe? = input == nil ? nil : Pipe()
        if let stdin { process.standardInput = stdin } else { process.standardInput = FileHandle.nullDevice }
        try process.run()

        return await withTaskCancellationHandler {
            if let stdin, let input {
                let handle = stdin.fileHandleForWriting
                DispatchQueue.global(qos: .utility).async {
                    try? handle.write(contentsOf: input)
                    try? handle.close()
                }
            }
            async let out = readAll(stdout.fileHandleForReading)
            async let err = readAll(stderr.fileHandleForReading)
            let (o, e) = await (out, err)
            await waitForExit(process)
            return ShellResult(status: process.terminationStatus,
                               stdout: String(decoding: o, as: UTF8.self),
                               stderr: String(decoding: e, as: UTF8.self))
        } onCancel: {
            process.terminate()
        }
    }

    /// Runs a command and returns its trimmed stdout, throwing on a non-zero exit.
    @discardableResult
    static func check(_ executable: String, _ arguments: [String], cwd: String? = nil, input: Data? = nil,
                      env: [String: String] = [:]) async throws -> String {
        let result = try await run(executable, arguments, cwd: cwd, input: input, env: env)
        guard result.status == 0 else {
            throw ShellError(command: label(executable, arguments), status: result.status,
                             output: result.stderr.isEmpty ? result.stdout : result.stderr)
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Runs a command, passing each line of stdout to `onLine` as it arrives.
    static func stream(_ executable: String, _ arguments: [String], cwd: String?, timeout: TimeInterval?,
                       onLine: @escaping (String) -> Void) async throws -> ShellResult {
        let process = makeProcess(executable, arguments, cwd: cwd, env: [:])
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
        try process.run()

        let timedOut = Flag()
        let watchdog = timeout.map { limit in
            Task.detached {
                try? await Task.sleep(for: .seconds(limit))
                if !Task.isCancelled && process.isRunning {
                    timedOut.set()
                    process.terminate()
                }
            }
        }
        defer { watchdog?.cancel() }

        return try await withTaskCancellationHandler {
            async let err = readAll(stderr.fileHandleForReading)
            for try await line in stdout.fileHandleForReading.bytes.lines {
                onLine(line)
            }
            let e = await err
            await waitForExit(process)
            return ShellResult(status: process.terminationStatus, stdout: "",
                               stderr: String(decoding: e, as: UTF8.self), timedOut: timedOut.isSet)
        } onCancel: {
            process.terminate()
        }
    }

    static func label(_ executable: String, _ arguments: [String]) -> String {
        var shown: [String] = []
        var skipNext = false
        for arg in arguments {
            if skipNext { skipNext = false; continue }
            if arg == "-c" { skipNext = true; continue }
            shown.append(arg)
        }
        return ([URL(fileURLWithPath: executable).lastPathComponent] + shown.prefix(4)).joined(separator: " ")
    }

    private static func makeProcess(_ executable: String, _ arguments: [String], cwd: String?, env: [String: String]) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = Tools.environment.merging(env) { _, new in new }
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        return process
    }

    private static func readAll(_ handle: FileHandle) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: (try? handle.readToEnd()) ?? Data())
            }
        }
    }

    private static func waitForExit(_ process: Process) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                process.waitUntilExit()
                continuation.resume()
            }
        }
    }
}
