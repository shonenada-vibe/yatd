import Foundation

/// Runs `ntn`. stdin must be closed: with it open, `ntn api` waits for input and hangs.
public struct NtnCLI: NotionTransport {
    public let executable: URL

    public init(executable: URL) {
        self.executable = executable
    }

    /// Finds `ntn` at an explicit path, in common install locations, or via the login shell's PATH.
    public static func locate(preferred: String? = nil) -> NtnCLI? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        var candidates = [preferred].compactMap { $0 }.filter { !$0.isEmpty }
        candidates += ["\(home)/.local/bin/ntn", "/opt/homebrew/bin/ntn", "/usr/local/bin/ntn"]
        if let path = candidates.first(where: { fm.isExecutableFile(atPath: $0) }) {
            return NtnCLI(executable: URL(fileURLWithPath: path))
        }
        // GUI apps don't inherit the shell PATH; ask a login shell.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "command -v ntn"]
        let out = Pipe()
        p.standardOutput = out
        p.standardInput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        let path = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return fm.isExecutableFile(atPath: path) ? NtnCLI(executable: URL(fileURLWithPath: path)) : nil
    }

    public func api(_ path: String, method: String, body: [String: Any]?) async throws -> Data {
        var args = ["api", path, "-X", method]
        if let body {
            let json = try JSONSerialization.data(withJSONObject: body)
            args += ["-d", String(decoding: json, as: UTF8.self)]
        }
        return try await run(args)
    }

    public func run(_ args: [String], timeout: TimeInterval = 30) async throws -> Data {
        let executable = executable
        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = executable
                p.arguments = args
                p.standardInput = FileHandle.nullDevice
                let out = Pipe(), err = Pipe()
                p.standardOutput = out
                p.standardError = err
                do { try p.run() } catch {
                    cont.resume(throwing: NotionError.cliNotFound)
                    return
                }
                let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
                // Read both pipes before waiting so large outputs can't deadlock.
                let errBox = DataBox()
                let errDone = DispatchSemaphore(value: 0)
                DispatchQueue.global().async {
                    errBox.data = err.fileHandleForReading.readDataToEndOfFile()
                    errDone.signal()
                }
                let data = out.fileHandleForReading.readDataToEndOfFile()
                errDone.wait()
                let errData = errBox.data
                p.waitUntilExit()
                killer.cancel()
                if p.terminationStatus == 0 {
                    cont.resume(returning: data)
                } else {
                    let msg = String(decoding: errData.isEmpty ? data : errData, as: UTF8.self)
                    cont.resume(throwing: NotionError.cliFailed(status: p.terminationStatus, stderr: msg))
                }
            }
        }
    }
}

/// Written once by the stderr reader, read after its semaphore signals.
private final class DataBox: @unchecked Sendable {
    var data = Data()
}
