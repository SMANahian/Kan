import Foundation
import KanCore

/// Restricted {bn, en} language-ID evidence for one unit.
public struct LanguageEvidence: Sendable, Hashable {
    public var range: TimeRange
    /// Probability mass for Bangla (with turbo: Bangla + other Indic languages).
    public var bangla: Double
    public var english: Double
    /// Diarized speaker of the unit on the remote track; nil on a single-voice track (the mic).
    public var speaker: String?

    public init(range: TimeRange, bangla: Double, english: Double, speaker: String? = nil) {
        self.range = range
        self.bangla = bangla
        self.english = english
        self.speaker = speaker
    }

    public var preferred: String { bangla >= english ? "bn" : "en" }

    /// |ln p(bn) − ln p(en)|: 1.0 means one language is e (2.7) times likelier.
    public var margin: Double { abs(log(max(bangla, 1e-9)) - log(max(english, 1e-9))) }
}

public struct LanguageDecision: Sendable, Hashable {
    public var language: String
    public var margin: Double
    /// Taken from a neighbouring unit because this one was too short or ambiguous.
    public var inherited: Bool

    public init(language: String, margin: Double, inherited: Bool) {
        self.language = language
        self.margin = margin
        self.inherited = inherited
    }
}

/// Routing thresholds.
public struct LanguageRouting: Sendable, Equatable {
    /// Units shorter than this inherit the decision of a confident unit (of the same speaker first).
    public var minimumDuration: Double = 2.0
    /// Units with a smaller |ln p(bn) − ln p(en)| inherit too.
    public var minimumMargin: Double = 1.0
    /// When Whisper gives bn + en less than this, the unit is something else (noise, music) and inherits.
    public var minimumMass: Double = 0.1

    public init() {}
}

/// Decides Bangla vs English per unit of one track. Pure.
public enum LanguageRouter {
    /// Languages whose probability turbo assigns to Bangla speech (it reads bangla.wav as Hindi).
    public static let indicLanguages = ["hi", "as", "ur", "gu", "mr", "ne", "pa", "or", "sa", "si", "ta", "te", "kn", "ml"]

    /// Evidence from Whisper's full language distribution (`probability(code)`).
    public static func evidence(range: TimeRange, speaker: String? = nil, weakBanglaLanguageID: Bool,
                                probability: (String) -> Double) -> LanguageEvidence {
        var bangla = probability("bn")
        if weakBanglaLanguageID { bangla += indicLanguages.reduce(0) { $0 + probability($1) } }
        return LanguageEvidence(range: range, bangla: bangla, english: probability("en"), speaker: speaker)
    }

    /// Long enough, clearly one language, and actually speech in one of the two.
    public static func isConfident(_ unit: LanguageEvidence, routing: LanguageRouting = LanguageRouting()) -> Bool {
        unit.range.duration >= routing.minimumDuration && isClear(unit, routing: routing)
    }

    /// Clearly one language and actually speech in one of the two, however short the unit.
    static func isClear(_ unit: LanguageEvidence, routing: LanguageRouting) -> Bool {
        unit.margin >= routing.minimumMargin && unit.bangla + unit.english >= routing.minimumMass
    }

    /// Placeholder evidence for a unit whose language ID was skipped: never confident, so it inherits.
    public static func undecided(_ range: TimeRange, speaker: String? = nil) -> LanguageEvidence {
        LanguageEvidence(range: range, bangla: 0.5, english: 0.5, speaker: speaker)
    }

    /// One decision per unit (same order). `.bangla` / `.english` modes skip language ID entirely.
    ///
    /// In `.auto`, a unit that is short, ambiguous or neither language takes the decision of the
    /// nearest confident unit of the same speaker (earlier one on ties): someone answering in Bangla
    /// between another participant's English turns keeps Bangla. A speaker without any confident unit
    /// keeps a clear measurement of a short unit (their own voice is better evidence than someone
    /// else's language), and otherwise takes the nearest confident unit of anyone on the track; with
    /// none at all, a unit keeps its own guess.
    public static func decide(_ units: [LanguageEvidence], mode: LanguageMode,
                              routing: LanguageRouting = LanguageRouting()) -> [LanguageDecision] {
        switch mode {
        case .bangla:
            return units.map { _ in LanguageDecision(language: "bn", margin: .infinity, inherited: false) }
        case .english:
            return units.map { _ in LanguageDecision(language: "en", margin: .infinity, inherited: false) }
        case .auto:
            break
        }
        let confident = units.map { isConfident($0, routing: routing) }
        func nearestConfident(to index: Int, sameSpeaker: Bool) -> Int? {
            var best: (distance: Double, index: Int)?
            for (other, isConfident) in confident.enumerated() where isConfident && other != index {
                if sameSpeaker && units[other].speaker != units[index].speaker { continue }
                let distance = units[other].range.gap(to: units[index].range)
                if let current = best, distance >= current.distance { continue }
                best = (distance, other)
            }
            return best?.index
        }
        return units.enumerated().map { index, unit in
            if confident[index] {
                return LanguageDecision(language: unit.preferred, margin: unit.margin, inherited: false)
            }
            if let neighbour = nearestConfident(to: index, sameSpeaker: true) {
                return LanguageDecision(language: units[neighbour].preferred, margin: unit.margin, inherited: true)
            }
            if !isClear(unit, routing: routing), let neighbour = nearestConfident(to: index, sameSpeaker: false) {
                return LanguageDecision(language: units[neighbour].preferred, margin: unit.margin, inherited: true)
            }
            return LanguageDecision(language: unit.preferred, margin: unit.margin, inherited: false)
        }
    }

    /// Speakers (nil: the track's only voice) with at least one confident unit. A short unit of such
    /// a speaker inherits from them, so its own language ID can be skipped.
    public static func settledSpeakers(_ units: [LanguageEvidence], routing: LanguageRouting = LanguageRouting()) -> Set<String?> {
        Set(units.filter { isConfident($0, routing: routing) }.map(\.speaker))
    }
}
