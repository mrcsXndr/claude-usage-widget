import Foundation

public struct ShellResult {
    public let status: Int32
    public let stdout: Data
    public let stderr: Data

    public var stderrLastLine: String {
        let text = String(data: stderr, encoding: .utf8) ?? ""
        return text.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
    }
}

/// Runs a program directly (no shell), with arguments as an array, and captures its output.
/// Secrets only ever come back on stdout; they are never passed as arguments.
public enum Shell {
    private final class Box { var data = Data() }

    public static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 30) throws -> ShellResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        try process.run()

        let out = Box()
        let err = Box()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            out.data = outPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            err.data = errPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        if group.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            throw UsageError.timeout("\(URL(fileURLWithPath: executable).lastPathComponent) after \(Int(timeout))s")
        }
        process.waitUntilExit()
        return ShellResult(status: process.terminationStatus, stdout: out.data, stderr: err.data)
    }
}
