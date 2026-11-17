import CryptoKit
import Foundation
import KanCore

public enum ModelStoreError: Error, LocalizedError, Sendable, Equatable {
    case unknownModel(String)
    case notDownloadable(String)
    case alreadyDownloading(String)
    case httpStatus(Int)
    case sizeMismatch(expected: Int64, actual: Int64)
    case checksumMismatch(String)
    case insufficientDiskSpace(needed: Int64, available: Int64)
    case fileSystem(String)
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .unknownModel(let id): return "Unknown model “\(id)”."
        case .notDownloadable(let id): return "“\(id)” can't be downloaded."
        case .alreadyDownloading(let id): return "“\(id)” is already downloading."
        case .httpStatus(let code): return "The download server answered HTTP \(code)."
        case .sizeMismatch(let expected, let actual):
            return "The download is \(actual) bytes but should be \(expected) bytes."
        case .checksumMismatch(let name): return "\(name) is damaged (checksum mismatch); it was deleted."
        case .insufficientDiskSpace(let needed, let available):
            let format = ByteCountFormatter()
            return "Not enough disk space: \(format.string(fromByteCount: needed)) needed, \(format.string(fromByteCount: available)) free."
        case .fileSystem(let message): return message
        case .network(let message): return "Download failed: \(message)"
        }
    }
}

/// Downloads one file over HTTP(S) into `<destination>.partial`, resuming an existing partial file
/// with a Range request, then verifies size and SHA-256 and renames it into place atomically.
/// Transient network errors are retried (resuming each time). Cancelling the calling task stops the
/// transfer and keeps the partial file for later.
enum ResumableDownloader {
    static func download(from source: URL, to destination: URL, expectedSize: Int64?, sha256: String?,
                         configuration: URLSessionConfiguration = .default,
                         progress: @escaping @Sendable (Double) -> Void) async throws {
        let fileManager = FileManager.default
        let partial = destination.appendingPathExtension("partial")
        do {
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            throw ModelStoreError.fileSystem("Could not create \(destination.deletingLastPathComponent().path): \(error.localizedDescription)")
        }

        var failures = 0
        transfer: while true {
            try Task.checkCancellation()
            var offset = fileSize(partial) ?? 0
            if let expectedSize, offset > expectedSize {
                try? fileManager.removeItem(at: partial)
                offset = 0
            }
            if let expectedSize, offset == expectedSize { break transfer }
            try checkDiskSpace(at: destination.deletingLastPathComponent(), needed: max(0, (expectedSize ?? 0) - offset))

            let attempt = DownloadAttempt(source: source, partial: partial, offset: offset, expectedSize: expectedSize,
                                          progress: progress)
            do {
                switch try await attempt.run(configuration: configuration) {
                case .complete:
                    break transfer
                case .restart:
                    try? fileManager.removeItem(at: partial)
                    failures += 1
                    if failures > 3 { throw ModelStoreError.network("the server kept rejecting resumed downloads") }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failures += 1
                guard failures <= 3, isTransient(error) else { throw error }
                KanLog.warning("Download of \(source.lastPathComponent) interrupted (\(error.localizedDescription)); retrying",
                               category: "models")
                try await Task.sleep(nanoseconds: UInt64(failures) * 1_000_000_000)
            }
        }

        let actual = fileSize(partial) ?? 0
        if let expectedSize, actual != expectedSize {
            try? fileManager.removeItem(at: partial)
            throw ModelStoreError.sizeMismatch(expected: expectedSize, actual: actual)
        }
        if let sha256 {
            let digest = try sha256Hex(of: partial)
            guard digest == sha256.lowercased() else {
                try? fileManager.removeItem(at: partial)
                throw ModelStoreError.checksumMismatch(destination.lastPathComponent)
            }
        }
        do {
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: partial)
            } else {
                try fileManager.moveItem(at: partial, to: destination)
            }
        } catch {
            throw ModelStoreError.fileSystem("Could not install \(destination.lastPathComponent): \(error.localizedDescription)")
        }
        progress(1)
    }

    static func fileSize(_ url: URL) -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else { return nil }
        return size.int64Value
    }

    static func sha256Hex(of url: URL) throws -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw ModelStoreError.fileSystem("Could not read \(url.lastPathComponent)")
        }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 8 << 20) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func checkDiskSpace(at directory: URL, needed: Int64) throws {
        guard needed > 0,
              let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let available = values.volumeAvailableCapacityForImportantUsage
        else { return }
        let margin: Int64 = 200 << 20
        if available < needed + margin {
            throw ModelStoreError.insufficientDiskSpace(needed: needed + margin, available: available)
        }
    }

    private static func isTransient(_ error: Error) -> Bool {
        if case ModelStoreError.httpStatus(let code) = error { return code >= 500 || code == 429 }
        if case ModelStoreError.network = error { return true }
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return false }
        return [NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost, NSURLErrorNotConnectedToInternet,
                NSURLErrorCannotConnectToHost, NSURLErrorDNSLookupFailed, NSURLErrorResourceUnavailable,
                NSURLErrorCannotFindHost, NSURLErrorSecureConnectionFailed].contains(nsError.code)
    }
}

/// One HTTP request of a download. All delegate callbacks run on one serial queue; `lock` guards
/// the state shared with `run`/`cancel`.
private final class DownloadAttempt: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    enum Outcome { case complete, restart }

    private let source: URL
    private let partial: URL
    private let offset: Int64
    private let expectedSize: Int64?
    private let progress: @Sendable (Double) -> Void

    private let lock = NSLock()
    private var continuation: CheckedContinuation<Outcome, Error>?
    private var task: URLSessionDataTask?
    private var cancelled = false

    // Delegate-queue state.
    private var handle: FileHandle?
    private var written: Int64 = 0
    private var total: Int64?
    private var failure: Error?
    private var outcome: Outcome = .complete
    /// The request was stopped on purpose (resume rejected, nothing left to send); report `outcome`.
    private var stoppedByUs = false
    private var lastReported = -1.0

    init(source: URL, partial: URL, offset: Int64, expectedSize: Int64?, progress: @escaping @Sendable (Double) -> Void) {
        self.source = source
        self.partial = partial
        self.offset = offset
        self.expectedSize = expectedSize
        self.progress = progress
    }

    func run(configuration: URLSessionConfiguration) async throws -> Outcome {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Outcome, Error>) in
                let queue = OperationQueue()
                queue.maxConcurrentOperationCount = 1
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
                var request = URLRequest(url: source)
                if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
                let task = session.dataTask(with: request)
                let alreadyCancelled = lock.withLock { () -> Bool in
                    self.continuation = continuation
                    self.task = task
                    return cancelled
                }
                task.resume()
                if alreadyCancelled { task.cancel() }
                session.finishTasksAndInvalidate()
            }
        } onCancel: {
            let task = lock.withLock { () -> URLSessionDataTask? in
                cancelled = true
                return self.task
            }
            task?.cancel()
        }
    }

    // MARK: URLSessionDataDelegate

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        var redirected = request
        if offset > 0 { redirected.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
        completionHandler(redirected)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            failure = ModelStoreError.network("not an HTTP response")
            completionHandler(.cancel)
            return
        }
        do {
            switch http.statusCode {
            case 206:
                guard let range = Self.contentRange(http.value(forHTTPHeaderField: "Content-Range")),
                      range.start == offset else {
                    outcome = .restart
                    stoppedByUs = true
                    completionHandler(.cancel)
                    return
                }
                total = range.total ?? expectedSize
                try openPartial(truncatingTo: offset)
            case 200:
                // The server ignored the Range header: start over.
                total = http.expectedContentLength > 0 ? http.expectedContentLength : expectedSize
                try openPartial(truncatingTo: 0)
            case 416:
                // Nothing left to send; the caller re-checks the partial's size.
                outcome = .restart
                if let expectedSize, offset == expectedSize { outcome = .complete }
                stoppedByUs = true
                completionHandler(.cancel)
                return
            default:
                failure = ModelStoreError.httpStatus(http.statusCode)
                completionHandler(.cancel)
                return
            }
        } catch {
            failure = error
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard failure == nil, let handle else { return }
        do {
            try handle.write(contentsOf: data)
        } catch {
            failure = ModelStoreError.fileSystem("Could not write \(partial.lastPathComponent): \(error.localizedDescription)")
            dataTask.cancel()
            return
        }
        written += Int64(data.count)
        if let total, total > 0 {
            let fraction = min(1, Double(written) / Double(total))
            if fraction - lastReported >= 0.005 || fraction >= 1 {
                lastReported = fraction
                progress(fraction)
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? handle?.close()
        handle = nil
        let (continuation, wasCancelled) = lock.withLock { () -> (CheckedContinuation<Outcome, Error>?, Bool) in
            defer { self.continuation = nil }
            return (self.continuation, cancelled)
        }
        guard let continuation else { return }
        if wasCancelled {
            continuation.resume(throwing: CancellationError())
        } else if let failure {
            continuation.resume(throwing: failure)
        } else if stoppedByUs {
            continuation.resume(returning: outcome)
        } else if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume(returning: .complete)
        }
    }

    // MARK: Helpers

    private func openPartial(truncatingTo length: Int64) throws {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: partial.path) {
            guard fileManager.createFile(atPath: partial.path, contents: nil) else {
                throw ModelStoreError.fileSystem("Could not create \(partial.path)")
            }
        }
        let handle = try FileHandle(forWritingTo: partial)
        try handle.truncate(atOffset: UInt64(length))
        try handle.seekToEnd()
        written = length
        self.handle = handle
    }

    /// Parses "bytes 100-199/1000" (total may be "*").
    static func contentRange(_ header: String?) -> (start: Int64, total: Int64?)? {
        guard let header, header.lowercased().hasPrefix("bytes ") else { return nil }
        let spec = header.dropFirst(6)
        let parts = spec.split(separator: "/", maxSplits: 1)
        guard let range = parts.first, let dash = range.firstIndex(of: "-"),
              let start = Int64(range[range.startIndex..<dash].trimmingCharacters(in: .whitespaces)) else { return nil }
        let total = parts.count > 1 ? Int64(parts[1].trimmingCharacters(in: .whitespaces)) : nil
        return (start, total)
    }
}
