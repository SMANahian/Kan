import Foundation
import KanAI
import KanCore
import KanTestKit

/// Fixed clock for the tests: Tue 17 Nov 2026, 12:00 in New York.
let testNow = KanDate.parse("2026-11-17T12:00:00-05:00") ?? Date(timeIntervalSince1970: 0)

/// A made-up key in OpenAI's format. It must never show up in an error, a log line or anywhere but
/// the Authorization header.
let testKey = "sk-proj-KanSelfTest0123456789abcdefWXYZ"

enum Fixtures {
    static let callID = CallID(rawValue: "01KAX3A0000000000000000000")

    static func options(_ language: AIOutputLanguage = .english, model: String = "gpt-6.1-terra",
                        userName: String = "Nahian", key: String = testKey) -> AIOptions {
        AIOptions(apiKey: key, model: model, language: language, userName: userName)
    }

    static func segment(_ id: Int, _ start: Double, _ end: Double, _ speaker: String, _ text: String,
                        _ language: String = "en", flags: [SegmentFlag] = []) -> TranscriptSegment {
        TranscriptSegment(id: id, start: start, end: end, speakerID: speaker, channel: speaker == Speaker.meID ? .me : .them,
                          text: text, language: language, confidence: 0.9, flags: flags)
    }

    /// The echo-suspect line of `researchCall` (mic bleed): never sent.
    static let echoLine = "Speed perturbation and SpecAugment, a good baseline indeed."

    /// A code-switched research call. The user's speaker still has the automatic name "Me"; one
    /// remote speaker is named, one isn't; one mic line is an echo suspect.
    static func researchCall() -> CallRecord {
        let start = KanDate.parse("2026-11-14T10:00:12-05:00") ?? testNow
        return CallRecord(
            id: callID, title: "Zoom call with Prof. Rahman", tags: ["research", "thesis"],
            notes: "Try SpecAugment + speed perturbation on the Bangla set.\nAsk about compute.",
            startedAt: start, endedAt: start.addingTimeInterval(2533), timeZone: "America/New_York",
            source: CallSource(appName: "Zoom", bundleID: "us.zoom.xos", platform: .zoom),
            status: .ready, languages: ["en", "bn"],
            speakers: [
                Speaker(id: Speaker.meID, name: "Me", isMe: true, nameSource: .automatic, talkTime: 900),
                Speaker(id: "s1", name: "Prof. Rahman", isMe: false, nameSource: .user, talkTime: 1300),
                Speaker(id: "s2", name: "Speaker 2", isMe: false, nameSource: .automatic, talkTime: 200),
            ],
            segments: [
                segment(0, 5, 9.5, "me", "So I was thinking about data augmentation for low-resource Bangla ASR."),
                segment(1, 30, 36, "me", "আমি ভাবছিলাম OpenSLR-এর বাংলা ডেটাসেট দিয়ে শুরু করা যায়।", "bn"),
                segment(2, 41, 47.5, "s1", "That's interesting. How many hours of Bangla speech does it have?"),
                segment(3, 751, 760, "s1", "Speed perturbation and SpecAugment would be a good augmentation baseline."),
                segment(4, 761, 766, "me", echoLine, flags: [.echoSuspect]),
                segment(5, 800, 806, "s2", "আর ভাষার মডেল আলাদা করে train করো।", "bn"),
                segment(6, 2400, 2410, "me", "I'll send you the paper draft by Friday."),
            ],
            bookmarks: [Bookmark(id: "b1", time: 751, note: "augmentation idea", createdAt: start.addingTimeInterval(800))])
    }

    /// The transcript lines Kan should send for `researchCall` (the user named "Nahian").
    static let researchLines = [
        "[00:00:05] Nahian: So I was thinking about data augmentation for low-resource Bangla ASR.",
        "[00:00:30] Nahian: আমি ভাবছিলাম OpenSLR-এর বাংলা ডেটাসেট দিয়ে শুরু করা যায়।",
        "[00:00:41] Prof. Rahman: That's interesting. How many hours of Bangla speech does it have?",
        "[00:12:31] Prof. Rahman: Speed perturbation and SpecAugment would be a good augmentation baseline.",
        "[00:13:20] Speaker 2: আর ভাষার মডেল আলাদা করে train করো।",
        "[00:40:00] Nahian: I'll send you the paper draft by Friday.",
    ]

    /// The whole input Kan should send for `researchCall`: its header, then its transcript lines.
    static let researchInput = """
        Current title: Zoom call with Prof. Rahman
        Date: Sat 14 Nov 2026, 10:00–10:42 (42 min)
        App: Zoom
        Participants: Nahian (me), Prof. Rahman, Speaker 2
        Tags: research, thesis

        My notes:
        Try SpecAugment + speed perturbation on the Bangla set.
        Ask about compute.

        Bookmarks:
        [00:12:31] augmentation idea

        Transcript:

        """ + researchLines.joined(separator: "\n") + "\n"

    /// An advisor meeting recorded with "Mic only (in-person)": one microphone, so the user's speaker
    /// holds every line, the advisor's and Karim's too.
    static func inPersonCall() -> CallRecord {
        let start = KanDate.parse("2026-11-16T15:00:00-05:00") ?? testNow
        return CallRecord(
            id: CallID(rawValue: "01KAX3B0000000000000000000"), title: "Recording", startedAt: start,
            endedAt: start.addingTimeInterval(1500), timeZone: "America/New_York",
            source: CallSource(appName: "Microphone", platform: .manual), status: .ready, languages: ["en"],
            speakers: [Speaker(id: Speaker.meID, name: "Me", isMe: true, nameSource: .automatic, talkTime: 20)],
            segments: [
                segment(0, 4, 9, "me", "Have you tried speed perturbation and SpecAugment? That should be your first baseline."),
                segment(1, 14, 18, "me", "Karim, can you share the cluster quota with him by Monday?"),
                segment(2, 25, 27, "me", "Sure, I'll send it tomorrow."),
            ])
    }

    /// A call without anything to send: no segments, or only blank and echo-suspect ones.
    static func untranscribedCall(segments: [TranscriptSegment] = []) -> CallRecord {
        var record = researchCall()
        record.segments = segments
        return record
    }

    /// `lines` turns of about `width` characters each, alternating speakers 3 s apart (never merged).
    static func longCall(lines: Int, width: Int = 100) -> CallRecord {
        var record = researchCall()
        let filler = String(repeating: "x", count: max(0, width - 12))
        record.segments = (0..<lines).map { i in
            let speaker = i % 2 == 0 ? "me" : "s1"
            return segment(i, Double(i) * 3, Double(i) * 3 + 1, speaker, String(format: "line %05d ", i) + filler)
        }
        record.endedAt = record.startedAt.addingTimeInterval(Double(lines) * 3 + 10)
        return record
    }
}

/// The `instructions` and `input` of a recorded Responses request.
func prompt(of request: RecordedRequest) throws -> (instructions: String, input: String) {
    let body = try request.json()
    return (try expectNotNil(body["instructions"] as? String, "instructions"), try expectNotNil(body["input"] as? String, "input"))
}

/// Runs `body` and returns the `AIError` it throws (fails when it throws something else or nothing).
func expectAIError<T>(_ expected: AIError? = nil, file: String = #fileID, line: Int = #line,
                      _ body: () async throws -> T) async throws -> AIError {
    do {
        _ = try await body()
    } catch let error as AIError {
        if let expected, error != expected {
            throw TestFailure("expected AIError.\(expected), got .\(error)", file: file, line: line)
        }
        return error
    } catch {
        throw TestFailure("expected an AIError, got \(error)", file: file, line: line)
    }
    throw TestFailure("expected an AIError, got a result", file: file, line: line)
}
