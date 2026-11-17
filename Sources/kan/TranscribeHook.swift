import Foundation
import KanTranscribe

/// `kan transcribe …` — the arguments after the word "transcribe", untouched.
enum TranscribeHook {
    static func run(_ arguments: [String]) async -> Int32 {
        await TranscribeCommand.run(arguments)
    }
}
