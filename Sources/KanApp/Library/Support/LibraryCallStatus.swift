import Foundation
import KanCore

/// The small status badge of a list row.
enum LibraryCallBadge: Equatable {
    case recording
    case queued
    case paused
    /// Transcribing; overall progress 0…1 when known.
    case transcribing(Double?)
    case failed

    var label: String {
        switch self {
        case .recording: return "Recording"
        case .queued: return "Queued"
        case .paused: return "Paused"
        case .transcribing(let fraction):
            guard let fraction else { return "Transcribing" }
            return LibraryFormat.percent(fraction)
        case .failed: return "Failed"
        }
    }
}

/// The banner above a call's transcript while it is recorded, queued, transcribed or after it failed.
struct LibraryStatusBanner: Equatable {
    enum Kind: Equatable {
        case recording, queued, paused, transcribing, failed, cancelled
    }

    var kind: Kind
    var title: String
    var detail: String?
    /// 0…1 while transcribing, when known.
    var progress: Double?
    var canCancel: Bool
    var canRetry: Bool
}

/// Derives badges and banners from the record's status and the queue's live status. The queue's
/// status wins while a job is queued or running; afterwards the record (the source of truth) does.
/// Pure and thread-safe.
enum LibraryCallStatus {
    static let cancelledMessage = "Cancelled by user"

    static func badge(status: CallStatus, processing: ProcessingStatus?) -> LibraryCallBadge? {
        switch processing?.state {
        case .running?: return .transcribing(processing?.progress.map { min(1, max(0, $0.fraction)) })
        case .queued?: return .queued
        case .paused?: return .paused
        default: break
        }
        switch status {
        case .recording: return .recording
        case .queued: return .queued
        case .processing: return .transcribing(nil)
        case .failed: return .failed
        case .ready: return nil
        }
    }

    static func banner(status: CallStatus, processing: ProcessingStatus?, hasTranscript: Bool,
                       error: String?) -> LibraryStatusBanner? {
        let keepsPrevious = hasTranscript ? "The current transcript stays until the new one is ready." : nil
        switch processing?.state {
        case .running?:
            let progress = processing?.progress
            var parts: [String] = []
            if let stage = progress?.stage.displayName { parts.append(stage) }
            if let message = LibraryFormat.nonEmpty(progress?.message), message != parts.first { parts.append(message) }
            if let keepsPrevious { parts.append(keepsPrevious) }
            return LibraryStatusBanner(kind: .transcribing, title: "Transcribing on this Mac",
                                       detail: parts.isEmpty ? nil : parts.joined(separator: " · "),
                                       progress: progress.map { min(1, max(0, $0.fraction)) },
                                       canCancel: true, canRetry: false)
        case .queued?:
            return LibraryStatusBanner(kind: .queued, title: "Waiting to transcribe", detail: keepsPrevious,
                                       progress: nil, canCancel: true, canRetry: false)
        case .paused?:
            return LibraryStatusBanner(kind: .paused, title: "Transcription paused",
                                       detail: "It continues automatically when the call being recorded ends.",
                                       progress: nil, canCancel: true, canRetry: false)
        default:
            break
        }
        switch status {
        case .recording:
            return LibraryStatusBanner(kind: .recording, title: "Recording in progress",
                                       detail: "The transcript will appear after the call.", progress: nil,
                                       canCancel: false, canRetry: false)
        case .queued:
            return LibraryStatusBanner(kind: .queued, title: "Waiting to transcribe", detail: keepsPrevious,
                                       progress: nil, canCancel: true, canRetry: false)
        case .processing:
            return LibraryStatusBanner(kind: .transcribing, title: "Transcribing on this Mac", detail: keepsPrevious,
                                       progress: nil, canCancel: true, canRetry: false)
        case .failed:
            let message = LibraryFormat.nonEmpty(error)
            if message == cancelledMessage {
                return LibraryStatusBanner(kind: .cancelled, title: "Transcription cancelled",
                                           detail: hasTranscript ? "This is the previous transcript." : nil,
                                           progress: nil, canCancel: false, canRetry: true)
            }
            var detail = message ?? "Unknown error."
            if hasTranscript {
                detail += (detail.hasSuffix(".") || detail.hasSuffix("!") ? " " : ". ") + "This is the previous transcript."
            }
            return LibraryStatusBanner(kind: .failed, title: "Transcription failed", detail: detail, progress: nil,
                                       canCancel: false, canRetry: true)
        case .ready:
            return nil
        }
    }
}
