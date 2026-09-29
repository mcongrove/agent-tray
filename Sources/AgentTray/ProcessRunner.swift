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

struct JSONRPCExchange: Sendable {
    let line: String
    var waitForID: Int? = nil
}

enum ProcessRunner {
    static func runJSONRPC(
        executable: URL,
        arguments: [String],
        exchanges: [JSONRPCExchange],
        environment: [String: String]? = nil,
        timeout: TimeInterval = 10
    ) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    continuation.resume(returning: try converse(
                        executable: executable,
                        arguments: arguments,
                        exchanges: exchanges,
                        environment: environment,
                        timeout: timeout
                    ))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

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

    private static func converse(
        executable: URL,
        arguments: [String],
        exchanges: [JSONRPCExchange],
        environment: [String: String]?,
        timeout: TimeInterval
    ) throws -> ProcessResult {
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
            throw ProcessRunnerError.couldNotLaunch(error.localizedDescription)
        }

        let reader = PipeLineReader(handle: outputPipe.fileHandleForReading)
        let stdin = inputPipe.fileHandleForWriting
        var collected = Data()
        var timedOut = false
        let deadline = Date().addingTimeInterval(timeout)

        for exchange in exchanges {
            guard Date() < deadline else {
                timedOut = true
                break
            }
            do {
                try stdin.write(contentsOf: Data((exchange.line + "\n").utf8))
            } catch {
                break
            }
            guard let id = exchange.waitForID else { continue }
            var matched = false
            while Date() < deadline {
                guard let line = reader.readLine(deadline: deadline) else { break }
                collected.append(contentsOf: Data((line + "\n").utf8))
                if jsonRPCID(in: line) == id {
                    matched = true
                    break
                }
            }
            if !matched {
                timedOut = true
                break
            }
        }

        try? stdin.close()
        if process.isRunning {
            if !timedOut {
                let drainUntil = min(deadline, Date().addingTimeInterval(0.4))
                while Date() < drainUntil, let line = reader.readLine(deadline: drainUntil) {
                    collected.append(contentsOf: Data((line + "\n").utf8))
                }
            }
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
        } else {
            while let line = reader.readLine(deadline: Date().addingTimeInterval(0.1)) {
                collected.append(contentsOf: Data((line + "\n").utf8))
            }
        }
        reader.stop()

        let stderr = errorPipe.fileHandleForReading.readDataToEndOfFile()
        return ProcessResult(
            standardOutput: collected,
            standardError: stderr,
            exitCode: process.terminationStatus,
            timedOut: timedOut
        )
    }

    private static func jsonRPCID(in line: String) -> Int? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return (object["id"] as? NSNumber)?.intValue
    }
}

private final class PipeLineReader {
    private let handle: FileHandle
    private let condition = NSCondition()
    private var buffer = Data()
    private var lines: [String] = []

    init(handle: FileHandle) {
        self.handle = handle
        handle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.append(data)
        }
    }

    func stop() {
        handle.readabilityHandler = nil
        condition.lock()
        condition.broadcast()
        condition.unlock()
    }

    func readLine(deadline: Date) -> String? {
        condition.lock()
        defer { condition.unlock() }
        while lines.isEmpty {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { return nil }
            _ = condition.wait(until: Date().addingTimeInterval(min(remaining, 0.2)))
        }
        return lines.removeFirst()
    }

    private func append(_ data: Data) {
        condition.lock()
        defer {
            condition.broadcast()
            condition.unlock()
        }
        buffer.append(data)
        while let index = buffer.firstIndex(of: 0x0A) {
            let line = buffer[..<index]
            buffer.removeSubrange(...index)
            lines.append(String(data: line, encoding: .utf8) ?? "")
        }
    }
}
