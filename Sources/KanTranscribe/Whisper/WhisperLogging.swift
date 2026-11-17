import CWhisper
import Foundation
import KanCore

/// Routes whisper.cpp and ggml (Metal backend) log lines to `KanLog`, warnings and errors only.
/// `whisper_log_set` also installs the sink for ggml, so the Metal backend is covered too.
enum WhisperLogging {
    static func install() { _ = installed }

    private static let installed: Void = { whisper_log_set(whisperLogSink, nil) }()

    /// Level of the previous message, so `GGML_LOG_LEVEL_CONT` continuations follow their parent.
    fileprivate static let lastLevel = LockedValue<UInt32>(GGML_LOG_LEVEL_NONE.rawValue)
}

private let whisperLogSink: ggml_log_callback = { level, text, _ in
    guard let text else { return }
    var effective = level.rawValue
    if effective == GGML_LOG_LEVEL_CONT.rawValue {
        effective = WhisperLogging.lastLevel.value
    } else {
        WhisperLogging.lastLevel.value = effective
    }
    guard effective == GGML_LOG_LEVEL_WARN.rawValue || effective == GGML_LOG_LEVEL_ERROR.rawValue else { return }
    let message = String(cString: text).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !message.isEmpty else { return }
    if effective == GGML_LOG_LEVEL_ERROR.rawValue {
        KanLog.error(message, category: "whisper")
    } else {
        KanLog.warning(message, category: "whisper")
    }
}

/// A value guarded by a lock.
final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) { storage = value }

    var value: Value {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }

    func withValue<T>(_ body: (inout Value) throws -> T) rethrows -> T {
        try lock.withLock { try body(&storage) }
    }
}
