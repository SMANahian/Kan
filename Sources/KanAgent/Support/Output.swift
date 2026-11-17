import Foundation

/// Where the CLI writes text. `standardOutput` / `standardError` write straight to the file
/// descriptors (no stdio buffering, so output order is exactly the call order); tests capture
/// output with `TextSink.buffer()`.
///
/// Thread-safety: a sink may be used from any thread; writes are serialized by a lock.
public final class TextSink: @unchecked Sendable {
    private let lock = NSLock()
    private let handler: (String) -> Bool
    private var captured = ""
    private let captures: Bool
    /// False once a write failed (e.g. the reader closed the pipe); later writes are dropped.
    public private(set) var isOpen = true

    /// `write` returns false when the text couldn't be written.
    public init(_ write: @escaping (String) -> Bool) {
        self.handler = write
        self.captures = false
    }

    private init(capturing: Bool) {
        self.handler = { _ in true }
        self.captures = capturing
    }

    public static let standardOutput = TextSink { FileDescriptorWriter.write($0, to: STDOUT_FILENO) }
    public static let standardError = TextSink { FileDescriptorWriter.write($0, to: STDERR_FILENO) }

    /// A sink that keeps everything written to it (see `text`).
    public static func buffer() -> TextSink { TextSink(capturing: true) }

    @discardableResult
    public func write(_ text: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard isOpen else { return false }
        if captures {
            captured += text
            return true
        }
        if !handler(text) { isOpen = false }
        return isOpen
    }

    /// Everything written to a `buffer()` sink.
    public var text: String {
        lock.lock()
        defer { lock.unlock() }
        return captured
    }
}

/// Blocking writes to a file descriptor that cope with partial writes and EINTR.
enum FileDescriptorWriter {
    /// Returns false on an error such as EPIPE (with SIGPIPE ignored) — the reader went away.
    static func write(_ text: String, to descriptor: Int32) -> Bool {
        var data = Array(text.utf8)
        if data.isEmpty { return true }
        return data.withUnsafeMutableBytes { buffer -> Bool in
            guard var pointer = buffer.baseAddress else { return true }
            var remaining = buffer.count
            while remaining > 0 {
                let written = Darwin.write(descriptor, pointer, remaining)
                if written < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                remaining -= written
                pointer += written
            }
            return true
        }
    }
}

/// Newline-delimited messages on stdin/stdout for `kan mcp`.
public enum StdioLines {
    /// The next line from stdin without its line ending, nil at end of input.
    public static func readLine() -> String? {
        Swift.readLine(strippingNewline: true)
    }

    /// Writes one message and a newline to stdout. False when stdout is closed.
    public static func writeLine(_ message: String) -> Bool {
        FileDescriptorWriter.write(message + "\n", to: STDOUT_FILENO)
    }
}
