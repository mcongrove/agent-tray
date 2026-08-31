import Foundation

struct ProcessResult: Sendable {
    let standardOutput: Data
    let standardError: Data
    let exitCode: Int32
    let timedOut: Bool
}

enum ProcessRunnerError: LocalizedError {
    case couldNotLaunch(String)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .couldNotLaunch(let message): message
        case .timedOut: "The agent did not respond in time."
        }
    }
}

enum ProcessRunner {
    static func run(
        executable: URL,
        arguments: [String],
        standardInput: Data? = nil,
        environment: [String: String]? = nil,
        inputCloseDelay: TimeInterval = 0,
        timeout: TimeInterval = 6
    ) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = executable
                process.arguments = arguments
                if let environment { process.environment = environment }

                let outputPipe = Pipe()
                let errorPipe = Pipe()
                let inputPipe = Pipe()
                process.standardOutput = outputPipe
                process.standardError = errorPipe
                process.standardInput = inputPipe

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: ProcessRunnerError.couldNotLaunch(error.localizedDescription))
                    return
                }

                if let standardInput {
                    inputPipe.fileHandleForWriting.write(standardInput)
                }
                if inputCloseDelay > 0 {
                    Thread.sleep(forTimeInterval: inputCloseDelay)
                }
                try? inputPipe.fileHandleForWriting.close()

                let deadline = Date().addingTimeInterval(timeout)
                while process.isRunning && Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.025)
                }

                let timedOut = process.isRunning
                if timedOut {
                    process.terminate()
                    Thread.sleep(forTimeInterval: 0.1)
                }

                let stdout = outputPipe.fileHandleForReading.readDataToEndOfFile()
                let stderr = errorPipe.fileHandleForReading.readDataToEndOfFile()
                if process.isRunning { process.waitUntilExit() }
                continuation.resume(returning: ProcessResult(
                    standardOutput: stdout,
                    standardError: stderr,
                    exitCode: process.terminationStatus,
                    timedOut: timedOut
                ))
            }
        }
    }
}
