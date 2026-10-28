#if os(macOS)
import Foundation

public struct ShellResult: Sendable {
    public let status: Int32
    public let out: String
    public let err: String
    public let timedOut: Bool

    public var ok: Bool { status == 0 && !timedOut }
}

public enum Shell {
    /// GUI apps start with a minimal PATH; add the usual tool locations so docker,
    /// brew and credential helpers resolve.
    static let environment: [String: String] = {
        var env = ProcessInfo.processInfo.environment
        let extra = ["/usr/local/bin", "/opt/homebrew/bin", "/Applications/Docker.app/Contents/Resources/bin",
                     "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        env["PATH"] = (extra + [env["PATH"] ?? ""]).joined(separator: ":")
        env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        env["HOMEBREW_NO_ENV_HINTS"] = "1"
        return env
    }()

    /// Runs a tool without a shell (arguments are never interpolated) and collects its output.
    public static func run(_ executable: String, _ args: [String], timeout: TimeInterval = 120,
                           captureStderr: Bool = true) async -> ShellResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = args
                process.environment = environment
                process.standardInput = FileHandle.nullDevice
                let outPipe = Pipe()
                let errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = captureStderr ? errPipe : FileHandle.nullDevice

                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: ShellResult(status: -1, out: "", err: "\(error.localizedDescription)", timedOut: false))
                    return
                }

                let lock = NSLock()
                var timedOut = false
                let killer = DispatchWorkItem {
                    if process.isRunning {
                        lock.lock(); timedOut = true; lock.unlock()
                        process.terminate()
                    }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)

                // Drain stderr concurrently so a chatty tool (du prints a line per
                // unreadable folder) can't fill the pipe and deadlock.
                var errData = Data()
                let group = DispatchGroup()
                if captureStderr {
                    group.enter()
                    DispatchQueue.global().async {
                        errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                        group.leave()
                    }
                }
                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                process.waitUntilExit()
                killer.cancel()

                lock.lock(); let didTimeOut = timedOut; lock.unlock()
                continuation.resume(returning: ShellResult(
                    status: process.terminationStatus,
                    out: String(decoding: outData, as: UTF8.self),
                    err: String(decoding: errData, as: UTF8.self),
                    timedOut: didTimeOut))
            }
        }
    }
}

/// Locates command-line tools without relying on the GUI app's PATH.
public enum Tools {
    public static let xcrun = "/usr/bin/xcrun"

    public static func find(_ name: String) -> String? {
        let home = NSHomeDirectory()
        let candidates = ["/usr/local/bin/\(name)", "/opt/homebrew/bin/\(name)", "/usr/bin/\(name)",
                          "/Applications/Docker.app/Contents/Resources/bin/\(name)", "\(home)/.local/bin/\(name)"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
#endif
