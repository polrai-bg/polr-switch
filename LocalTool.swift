import Foundation

func runLocalTool(_ path: String, _ arguments: [String]) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = arguments
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        task.terminationHandler = { process in
            if process.terminationStatus == 0 {
                continuation.resume()
            } else {
                continuation.resume(throwing: ProfileError.message(
                    "\(URL(fileURLWithPath: path).lastPathComponent) failed (exit \(process.terminationStatus)). Check the app signature, folder permissions, and available disk space before retrying."))
            }
        }
        do { try task.run() }
        catch { task.terminationHandler = nil; continuation.resume(throwing: error) }
    }
}
