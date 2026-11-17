import AVFoundation
import Foundation
import KanCore
import KanTestKit
import KanTranscribe

/// Probabilities at 32 ms frames: `base` everywhere, `dips` (time → value) at single frames.
private func probabilities(duration: Double, base: Float = 0.9, dips: [(Double, Float)] = []) -> SpeechProbabilities {
    let frame = Double(SpeechProbabilities.windowSamples) / 16_000
    var values = [Float](repeating: base, count: Int((duration / frame).rounded(.up)))
    for (time, value) in dips {
        let index = Int(time / frame)
        if values.indices.contains(index) { values[index] = value }
    }
    return SpeechProbabilities(values: values)
}

private func unit(_ start: Double, _ end: Double, _ language: String) -> LanguageUnit {
    LanguageUnit(range: TimeRange(start, end), language: language)
}

func chunkPlannerSuite() -> TestSuite {
    let suite = TestSuite("ChunkPlanner")
    suite.test("splits long speech at the quietest frame between 0.5× and 1× the maximum") {
        // Deep dip at 3 s is outside [4 s, 8 s]; the dip at 6 s is the cut.
        let probs = probabilities(duration: 20, dips: [(3.0, 0.01), (6.0, 0.1)])
        let pieces = ChunkPlanner.split([TimeRange(0, 20)], probabilities: probs, maxLength: 8)
        try expectClose(pieces[0].end, 6.0, tolerance: 0.04, "first cut \(pieces)")
        try expect(pieces.allSatisfy { $0.duration <= 8 + 1e-9 }, "\(pieces)")
        try expectClose(pieces.last?.end ?? 0, 20, tolerance: 1e-9)
        for (a, b) in zip(pieces, pieces.dropFirst()) { try expectClose(a.end, b.start, tolerance: 1e-9) }
    }
    suite.test("leaves ranges within the maximum untouched") {
        let ranges = [TimeRange(1, 5), TimeRange(6, 13.9)]
        try expectEqual(ChunkPlanner.split(ranges, probabilities: probabilities(duration: 15), maxLength: 8), ranges)
    }
    suite.test("language units are at most 15 s") {
        let units = ChunkPlanner.languageUnits(speech: [TimeRange(0, 40)], probabilities: probabilities(duration: 40),
                                               limits: ChunkLimits(banglaTokenizer: true))
        try expect(units.count >= 3 && units.allSatisfy { $0.duration <= 15 + 1e-9 }, "\(units)")
    }
    suite.test("merges same-language neighbours within 1.5 s up to the Bangla cap") {
        let units = [unit(0, 5, "en"), unit(5.5, 10, "en"), unit(10.5, 14, "bn"), unit(14.2, 20, "bn")]
        let probs = probabilities(duration: 20)
        let stock = ChunkPlanner.decodeChunks(units: units, probabilities: probs, limits: ChunkLimits(banglaTokenizer: false))
        try expectEqual(stock.map(\.language), ["en", "bn", "bn"], "stock tokenizer: 9.5 s of Bangla exceeds 8 s")
        try expectEqual(stock[0].range, TimeRange(0, 10))
        let tuned = ChunkPlanner.decodeChunks(units: units, probabilities: probs, limits: ChunkLimits(banglaTokenizer: true))
        try expectEqual(tuned.map(\.language), ["en", "bn"])
        try expectEqual(tuned[1].range, TimeRange(10.5, 20))
    }
    suite.test("never merges across gaps over 1.5 s or across languages") {
        let units = [unit(0, 3, "en"), unit(4.6, 6, "en"), unit(6.5, 8, "bn"), unit(8.2, 9, "en")]
        let chunks = ChunkPlanner.decodeChunks(units: units, probabilities: probabilities(duration: 10),
                                               limits: ChunkLimits(banglaTokenizer: true))
        try expectEqual(chunks.map(\.language), ["en", "en", "bn", "en"])
    }
    suite.test("English chunks stay within 25 s") {
        let units = [unit(0, 10, "en"), unit(10.5, 20, "en"), unit(20.5, 30, "en")]
        let chunks = ChunkPlanner.decodeChunks(units: units, probabilities: probabilities(duration: 30),
                                               limits: ChunkLimits(banglaTokenizer: false))
        try expectEqual(chunks.map(\.range), [TimeRange(0, 20), TimeRange(20.5, 30)])
    }
    suite.test("a unit longer than its cap is split") {
        let limits = ChunkLimits(banglaTokenizer: false)
        let two = ChunkPlanner.decodeChunks(units: [unit(0, 14, "bn")], probabilities: probabilities(duration: 14, dips: [(7.0, 0.05)]),
                                            limits: limits)
        try expectEqual(two.count, 2)
        try expect(two.allSatisfy { $0.range.duration <= 8 + 1e-9 && $0.language == "bn" })
        try expectClose(two[0].range.end, 7.0, tolerance: 0.04)
        // A pause at 5 s leaves 9 s, which needs one more cut.
        let three = ChunkPlanner.decodeChunks(units: [unit(0, 14, "bn")], probabilities: probabilities(duration: 14, dips: [(5.0, 0.05)]),
                                              limits: limits)
        try expectEqual(three.count, 3)
        try expect(three.allSatisfy { $0.range.duration <= 8 + 1e-9 })
    }
    suite.test("speaker change points ignore backchannels inside another speaker's turn") {
        func turn(_ speaker: String, _ start: Double, _ end: Double) -> SpeakerTurn { SpeakerTurn(speaker: speaker, start: start, end: end) }
        try expectEqual(ChunkPlanner.speakerChangePoints([turn("A", 0, 5), turn("B", 5.5, 9)]), [5.25])
        try expectEqual(ChunkPlanner.speakerChangePoints([turn("A", 0, 10), turn("B", 4, 4.5), turn("A", 10.5, 15)]), [],
                        "a contained 'yeah' is not a change; A continues")
        let overlap = ChunkPlanner.speakerChangePoints([turn("A", 0, 5), turn("B", 4.8, 9), turn("A", 9.2, 12)])
        try expectEqual(overlap.count, 2)
        try expectClose(overlap[0], 4.9, tolerance: 1e-9)
        try expectClose(overlap[1], 9.1, tolerance: 1e-9)
    }
    suite.test("speech is cut at change points that aren't too close to its edges") {
        try expectEqual(ChunkPlanner.cut([TimeRange(0, 10)], at: [5.25]), [TimeRange(0, 5.25), TimeRange(5.25, 10)])
        try expectEqual(ChunkPlanner.cut([TimeRange(0, 10)], at: [0.2, 9.9]), [TimeRange(0, 10)])
        try expectEqual(ChunkPlanner.cut([TimeRange(0, 4), TimeRange(6, 9)], at: [5, 7.5]),
                        [TimeRange(0, 4), TimeRange(6, 7.5), TimeRange(7.5, 9)])
    }
    suite.test("units of different speakers are never decoded together") {
        let units = [LanguageUnit(range: TimeRange(0, 3), language: "bn", speaker: "C0"),
                     LanguageUnit(range: TimeRange(3.2, 6), language: "bn", speaker: "C1"),
                     LanguageUnit(range: TimeRange(6.3, 8), language: "bn", speaker: "C1")]
        let chunks = ChunkPlanner.decodeChunks(units: units, probabilities: probabilities(duration: 8),
                                               limits: ChunkLimits(banglaTokenizer: true))
        try expectEqual(chunks.map(\.range), [TimeRange(0, 3), TimeRange(3.2, 8)])
    }
    suite.test("halves a truncated chunk in its middle 40 % at the quietest frame") {
        let halves = try expectNotNil(ChunkPlanner.halve(TimeRange(10, 20), probabilities: probabilities(duration: 20, dips: [(12.5, 0.05), (16.0, 0.2)])))
        try expectClose(halves.0.end, 16.0, tolerance: 0.04, "12.5 s is outside the middle 40 % [13, 17]")
        try expectEqual(halves.0.end, halves.1.start)
        try expect(ChunkPlanner.halve(TimeRange(0, 1.5), probabilities: .empty) == nil)
    }
    return suite
}

func speechSegmenterSuite() -> TestSuite {
    let suite = TestSuite("SpeechSegmenter")
    func probs(_ spans: [(Double, Double)], duration: Double) -> SpeechProbabilities {
        let frame = Double(SpeechProbabilities.windowSamples) / 16_000
        let count = Int(duration / frame)
        return SpeechProbabilities(values: (0..<count).map { i in
            let t = (Double(i) + 0.5) * frame
            return spans.contains { t >= $0.0 && t < $0.1 } ? 0.95 : 0.02
        })
    }
    suite.test("bridges pauses shorter than the minimum silence and pads segments") {
        let segments = SpeechSegmenter.segments(from: probs([(1, 3), (3.15, 5)], duration: 8))
        try expectEqual(segments.count, 1, "\(segments)")
        try expectClose(segments[0].start, 0.9, tolerance: 0.05)
        try expectClose(segments[0].end, 5.1, tolerance: 0.05)
    }
    suite.test("drops blips shorter than the minimum speech duration") {
        let segments = SpeechSegmenter.segments(from: probs([(1, 3), (6, 6.1)], duration: 8))
        try expectEqual(segments.count, 1, "\(segments)")
    }
    suite.test("keeps separate segments across real pauses") {
        let segments = SpeechSegmenter.segments(from: probs([(1, 3), (4, 6)], duration: 8))
        try expectEqual(segments.count, 2, "\(segments)")
        try expectClose(segments[0].end, 3.1, tolerance: 0.05)
        try expectClose(segments[1].start, 3.9, tolerance: 0.05)
    }
    suite.test("speech running to the end is closed at the audio end") {
        let segments = SpeechSegmenter.segments(from: probs([(2, 10)], duration: 5), audioDuration: 4.9)
        try expectEqual(segments.count, 1)
        try expectClose(segments[0].end, 4.9, tolerance: 0.001)
    }
    suite.test("no speech gives no segments") {
        try expect(SpeechSegmenter.segments(from: probs([], duration: 5)).isEmpty)
        try expect(SpeechSegmenter.segments(from: .empty).isEmpty)
    }
    return suite
}

func languageRouterSuite() -> TestSuite {
    let suite = TestSuite("LanguageRouter")
    func evidence(_ start: Double, _ end: Double, bn: Double, en: Double) -> LanguageEvidence {
        LanguageEvidence(range: TimeRange(start, end), bangla: bn, english: en)
    }
    suite.test("fixed modes skip language ID") {
        let units = [evidence(0, 5, bn: 0.01, en: 0.99), evidence(6, 9, bn: 0.99, en: 0.01)]
        try expectEqual(LanguageRouter.decide(units, mode: .bangla).map(\.language), ["bn", "bn"])
        try expectEqual(LanguageRouter.decide(units, mode: .english).map(\.language), ["en", "en"])
        try expect(LanguageRouter.decide(units, mode: .english).allSatisfy { !$0.inherited })
    }
    suite.test("confident units keep their language") {
        let units = [evidence(0, 5, bn: 0.95, en: 0.01), evidence(6, 12, bn: 0.02, en: 0.97)]
        try expectEqual(LanguageRouter.decide(units, mode: .auto).map(\.language), ["bn", "en"])
    }
    suite.test("short units inherit the nearest confident unit on the track") {
        let units = [evidence(0, 5, bn: 0.95, en: 0.01), evidence(5.5, 6.5, bn: 0.05, en: 0.9),
                     evidence(20, 30, bn: 0.01, en: 0.95)]
        let decisions = LanguageRouter.decide(units, mode: .auto)
        try expectEqual(decisions.map(\.language), ["bn", "bn", "en"])
        try expectEqual(decisions.map(\.inherited), [false, true, false])
    }
    suite.test("low-margin and non-speech units inherit") {
        let units = [evidence(0, 4, bn: 0.03, en: 0.90), evidence(4.5, 8, bn: 0.45, en: 0.40),
                     evidence(9, 12, bn: 0.02, en: 0.03)]
        let decisions = LanguageRouter.decide(units, mode: .auto)
        try expectEqual(decisions.map(\.language), ["en", "en", "en"])
        try expectEqual(decisions.map(\.inherited), [false, true, true])
    }
    suite.test("without confident units every unit keeps its own guess") {
        let units = [evidence(0, 1, bn: 0.6, en: 0.3), evidence(2, 3, bn: 0.2, en: 0.7)]
        try expectEqual(LanguageRouter.decide(units, mode: .auto).map(\.language), ["bn", "en"])
    }
    suite.test("turbo: Bangla + other Indic mass is compared with English") {
        let probabilities: [String: Double] = ["bn": 0.03, "hi": 0.25, "gu": 0.04, "en": 0.05]
        let lookup: (String) -> Double = { probabilities[$0] ?? 0 }
        let stock = LanguageRouter.evidence(range: TimeRange(0, 5), weakBanglaLanguageID: false, probability: lookup)
        let turbo = LanguageRouter.evidence(range: TimeRange(0, 5), weakBanglaLanguageID: true, probability: lookup)
        try expectEqual(stock.preferred, "en")
        try expectEqual(turbo.preferred, "bn")
        try expectClose(turbo.bangla, 0.32, tolerance: 1e-9)
    }
    suite.test("undecided units are never confident and inherit") {
        let undecided = LanguageRouter.undecided(TimeRange(5, 6))
        try expect(!LanguageRouter.isConfident(undecided))
        let units = [evidence(0, 4, bn: 0.02, en: 0.95), undecided]
        try expectEqual(LanguageRouter.decide(units, mode: .auto).map(\.language), ["en", "en"])
    }
    func spoken(_ speaker: String, _ start: Double, _ end: Double, bn: Double, en: Double) -> LanguageEvidence {
        LanguageEvidence(range: TimeRange(start, end), bangla: bn, english: en, speaker: speaker)
    }
    suite.test("short units inherit from their own speaker first (remote track)") {
        // A speaks English in long turns; B answers in Bangla, often briefly, right after A.
        let units = [spoken("A", 0, 8, bn: 0.02, en: 0.95), spoken("B", 8.5, 14.5, bn: 0.93, en: 0.03),
                     spoken("A", 15, 25, bn: 0.01, en: 0.97), LanguageRouter.undecided(TimeRange(25.2, 26.6), speaker: "B"),
                     spoken("A", 27, 35, bn: 0.02, en: 0.96), LanguageRouter.undecided(TimeRange(35.3, 36.5), speaker: "B")]
        let decisions = LanguageRouter.decide(units, mode: .auto)
        try expectEqual(decisions.map(\.language), ["en", "bn", "en", "bn", "en", "bn"])
        try expectEqual(decisions.map(\.inherited), [false, false, false, true, false, true])
    }
    suite.test("a speaker without a confident unit keeps a clear short measurement, else takes anyone's nearest") {
        let units = [spoken("A", 0, 8, bn: 0.02, en: 0.95), spoken("B", 8.3, 9.7, bn: 0.90, en: 0.05),
                     spoken("B", 10, 11, bn: 0.40, en: 0.35), spoken("A", 11.5, 20, bn: 0.01, en: 0.97)]
        let decisions = LanguageRouter.decide(units, mode: .auto)
        try expectEqual(decisions.map(\.language), ["en", "bn", "en", "en"])
        try expectEqual(decisions.map(\.inherited), [false, false, true, false])
    }
    suite.test("only speakers with a confident unit are settled (their short units skip language ID)") {
        let units = [spoken("A", 0, 8, bn: 0.02, en: 0.95), spoken("B", 8.3, 9.7, bn: 0.90, en: 0.05),
                     spoken("C", 10, 14, bn: 0.40, en: 0.35)]
        try expectEqual(LanguageRouter.settledSpeakers(units), ["A"])
        try expectEqual(LanguageRouter.settledSpeakers([evidence(0, 5, bn: 0.9, en: 0.01)]), [nil], "the mic track's one voice")
        try expect(LanguageRouter.settledSpeakers([evidence(0, 1, bn: 0.9, en: 0.01)]).isEmpty)
    }
    suite.test("evidence carries the unit's speaker") {
        let evidence = LanguageRouter.evidence(range: TimeRange(0, 3), speaker: "S2", weakBanglaLanguageID: false) { $0 == "bn" ? 0.9 : 0.05 }
        try expectEqual(evidence.speaker, "S2")
        try expectEqual(evidence.preferred, "bn")
        try expectEqual(LanguageRouter.undecided(TimeRange(0, 1), speaker: "S2").speaker, "S2")
        try expect(LanguageRouter.undecided(TimeRange(0, 1)).speaker == nil)
    }
    suite.test("margin is the absolute log ratio") {
        try expectClose(evidence(0, 1, bn: 0.5, en: 0.05).margin, log(10), tolerance: 1e-9)
        try expectClose(evidence(0, 1, bn: 0.05, en: 0.5).margin, log(10), tolerance: 1e-9)
    }
    return suite
}

func textPostProcessorSuite() -> TestSuite {
    let suite = TestSuite("TextPostProcessor")
    suite.test("NFC: precomposed and decomposed nukta letters become identical bytes") {
        let precomposed = "\u{09DF}\u{09BE}"          // য়া as one code point + vowel sign
        let decomposed = "\u{09AF}\u{09BC}\u{09BE}"    // য + nukta + vowel sign
        let a = TextPostProcessor.clean(precomposed), b = TextPostProcessor.clean(decomposed)
        try expectEqual(Array(a.utf8), Array(b.utf8))
        try expectEqual(a.unicodeScalars.map(\.value), [0x09AF, 0x09BC, 0x09BE], "U+09DF is a composition exclusion")
    }
    suite.test("'.' becomes '।' after Bengali text only") {
        try expectEqual(TextPostProcessor.clean("আমি ভাত খাই."), "আমি ভাত খাই।")
        try expectEqual(TextPostProcessor.clean("আমি model train করি. Then we test."), "আমি model train করি। Then we test.")
        try expectEqual(TextPostProcessor.clean("I eat rice."), "I eat rice.")
        try expectEqual(TextPostProcessor.clean("দাম ৩.৫ টাকা"), "দাম ৩.৫ টাকা", "decimal point")
        try expectEqual(TextPostProcessor.clean("তারপর..."), "তারপর...", "ellipsis")
        try expectEqual(TextPostProcessor.clean("কথা ."), "কথা।")
    }
    suite.test("whitespace cleanup") {
        try expectEqual(TextPostProcessor.clean("  hello ,\tworld \n ."), "hello, world.")
        try expectEqual(TextPostProcessor.clean(" আমি   যাব ।"), "আমি যাব।")
        try expectEqual(TextPostProcessor.clean("broken \u{FFFD} char"), "broken char")
    }
    suite.test("de-loop collapses ≥ 3 repeats and keeps two-fold reduplication") {
        try expectEqual(TextPostProcessor.deloop("আস্তে আস্তে চলো"), "আস্তে আস্তে চলো")
        try expectEqual(TextPostProcessor.deloop("কী কী লাগবে"), "কী কী লাগবে")
        try expectEqual(TextPostProcessor.deloop("না না না না"), "না")
        try expectEqual(TextPostProcessor.deloop("thank you thank you thank you so much"), "thank you so much")
        try expectEqual(TextPostProcessor.deloop("আমি যাব আমি যাব আমি যাব বাড়ি"), "আমি যাব বাড়ি")
        try expectEqual(TextPostProcessor.deloop("okay. okay, okay! fine"), "okay. fine", "punctuation-insensitive")
        try expectEqual(TextPostProcessor.deloopIndices(["a", "b", "b", "b", "c"]), [0, 1, 4])
    }
    suite.test("detects a prompt-induced repeated phrase") {
        try expect(TextPostProcessor.hasRepeatedPhrase("এই প্রজেক্টে আমাদের প্রথম কাজ হবে দেটাশেট সম্রহ করা, তার পর model training প্রথম কাজ হবে দেটাশেট সম্রহ করা।"))
        try expect(!TextPostProcessor.hasRepeatedPhrase("এই প্রজেক্টে আমাদের প্রথম কাজ হবে ডেটাসেট সংগ্রহ করা, তারপর মডেল ট্রেনিং।"))
    }
    suite.test("known hallucinations are dropped only on near-silence or exact match with high no-speech") {
        func drop(_ text: String, language: String = "en", noSpeech: Double = 0.02, silent: Bool = false) -> TextPostProcessor.DropReason? {
            TextPostProcessor.dropReason(text: text, language: language, noSpeechProbability: noSpeech,
                                         averageLogProbability: -0.3, nearSilent: silent)
        }
        try expect(drop("Thank you.") == nil, "a real 'Thank you.' stays")
        try expectEqual(drop("Thank you.", silent: true), .hallucination)
        try expectEqual(drop("Thank you.", noSpeech: 0.5), .hallucination)
        try expectEqual(drop("Thanks for watching!", noSpeech: 0.4), .hallucination)
        try expect(drop("Thanks for watching!") == nil)
        try expectEqual(drop("Subtitles by the Amara.org community", noSpeech: 0.35), .hallucination)
        try expectEqual(drop("So thanks for watching and see you next time", silent: true), .hallucination)
        try expect(drop("So thanks for watching and see you next time") == nil)
        try expectEqual(drop("Thank you.", language: "bn"), .hallucination, "English boilerplate from a Bangla chunk")
        try expect(drop("ধন্যবাদ, thank you", language: "bn") == nil)
        try expect(drop("Thank you for the idea about augmentation.") == nil)
    }
    suite.test("whisper's no-speech rule and empty text") {
        try expectEqual(TextPostProcessor.dropReason(text: "hmm okay", language: "en", noSpeechProbability: 0.7,
                                                     averageLogProbability: -1.5, nearSilent: false), .noSpeech)
        try expect(TextPostProcessor.dropReason(text: "hmm okay", language: "en", noSpeechProbability: 0.7,
                                                averageLogProbability: -0.4, nearSilent: false) == nil)
        try expectEqual(TextPostProcessor.dropReason(text: " ... । ", language: "bn", noSpeechProbability: 0,
                                                     averageLogProbability: 0, nearSilent: false), .empty)
    }
    suite.test("Bengali script share") {
        try expectClose(TextPostProcessor.bengaliLetterFraction("আমি"), 1, tolerance: 1e-9)
        try expectClose(TextPostProcessor.bengaliLetterFraction("abc"), 0, tolerance: 1e-9)
        try expect(TextPostProcessor.containsBengali("model তৈরি"))
    }
    suite.test("initial prompt: vocabulary, Bangla-only terms for the fine-tune, code-switch sentence for stock Bangla") {
        let stock = try expectNotNil(ModelCatalog.spec("large-v3"))
        let tuned = try expectNotNil(ModelCatalog.spec("bengali-medium-q8_0"))
        let vocabulary = "Nahian, diarization,\nরহমান"
        try expectEqual(TranscriptionPipeline.initialPrompt(vocabulary: vocabulary, language: "en", spec: stock, codeSwitch: nil),
                        "Nahian, diarization, রহমান.")
        try expectEqual(TranscriptionPipeline.initialPrompt(vocabulary: vocabulary, language: "bn", spec: tuned, codeSwitch: nil),
                        "রহমান।")
        try expectEqual(TranscriptionPipeline.initialPrompt(vocabulary: "", language: "bn", spec: stock, codeSwitch: "আজকের meeting-এ"),
                        "আজকের meeting-এ")
        try expect(TranscriptionPipeline.initialPrompt(vocabulary: " , ", language: "en", spec: stock, codeSwitch: nil) == nil)
    }
    return suite
}

func tokenAssemblerSuite() -> TestSuite {
    let suite = TestSuite("TokenAssembler")
    suite.test("merges UTF-8 byte fragments into Bangla words before decoding") {
        // " আমি" + " আজকে", split mid-character the way byte-level BPE does.
        let pieces = [
            TokenPiece(bytes: [0x20, 0xE0, 0xA6], start: 0.00, end: 0.05, probability: 0.9),
            TokenPiece(bytes: [0x86, 0xE0], start: 0.05, end: 0.10, probability: 0.8),
            TokenPiece(bytes: [0xA6, 0xAE, 0xE0, 0xA6, 0xBF], start: 0.10, end: 0.27, probability: 0.7),
            TokenPiece(bytes: [0x20] + Array("আজ".utf8), start: 0.27, end: 0.35, probability: 1.0),
            TokenPiece(bytes: Array("কে".utf8), start: 0.35, end: 0.45, probability: 0.6),
        ]
        let words = TokenAssembler.words(from: pieces)
        try expectEqual(words.map(\.text), ["আমি", "আজকে"])
        try expectClose(words[0].start, 0, tolerance: 1e-9)
        try expectClose(words[0].end, 0.27, tolerance: 1e-9)
        try expectClose(words[0].probability, 0.8, tolerance: 1e-9)
        try expectClose(words[1].end, 0.45, tolerance: 1e-9)
        try expectEqual(TokenAssembler.text(from: pieces), "আমি আজকে")
    }
    suite.test("punctuation without a leading space stays with its word") {
        let words = TokenAssembler.words(from: [TokenPiece(" Hello", start: 0, end: 0.3), TokenPiece(",", start: 0.3, end: 0.35),
                                                TokenPiece(" world", start: 0.4, end: 0.7), TokenPiece(".", start: 0.7, end: 0.75)])
        try expectEqual(words.map(\.text), ["Hello,", "world."])
    }
    suite.test("a character cut by a segment boundary is repaired") {
        // Segment 1 ends with the first two bytes of "ব" (e0 a6 ac); segment 2 starts with the third.
        let first = [TokenPiece(" নতুন", start: 0, end: 0.5), TokenPiece(bytes: [0x20, 0xE0, 0xA6, 0x97, 0xE0, 0xA6], start: 0.5, end: 0.7, probability: 1)]
        let second = [TokenPiece(bytes: [0xAC] + Array("েষণা".utf8), start: 0.8, end: 1.2, probability: 1), TokenPiece(" কথা", start: 1.2, end: 1.5)]
        let repaired = TokenAssembler.repairBoundaries([first, second])
        try expectEqual(TokenAssembler.text(from: repaired[0]), "নতুন গব")
        try expectEqual(TokenAssembler.text(from: repaired[1]), "েষণা কথা")
        try expectEqual(TokenAssembler.repairBoundaries([[TokenPiece(" ok", start: 0, end: 1)], [TokenPiece(" fine", start: 1, end: 2)]]).map { TokenAssembler.text(from: $0) },
                        ["ok", "fine"])
    }
    suite.test("a first token without a space still starts a word") {
        try expectEqual(TokenAssembler.words(from: [TokenPiece("Hi", start: 0, end: 0.2), TokenPiece(" there", start: 0.2, end: 0.5)]).map(\.text),
                        ["Hi", "there"])
    }
    suite.test("an incomplete trailing character is dropped, never shown as �") {
        let pieces = [TokenPiece(" ক", start: 0, end: 0.1), TokenPiece(bytes: [0xE0, 0xA6], start: 0.1, end: 0.2, probability: 0.5)]
        try expectEqual(TokenAssembler.text(from: pieces), "ক")
        try expectEqual(TokenAssembler.words(from: pieces).map(\.text), ["ক"])
    }
    return suite
}

func transcriptAssemblerSuite() -> TestSuite {
    let suite = TestSuite("TranscriptAssembler")
    func word(_ text: String, _ start: Double, _ end: Double) -> RecognizedWord {
        RecognizedWord(text: text, start: start, end: end, probability: 0.9)
    }
    func segment(_ channel: AudioChannel, _ words: [RecognizedWord], language: String = "en") -> RecognizedSegment {
        RecognizedSegment(channel: channel, range: TimeRange(words.first?.start ?? 0, words.last?.end ?? 0),
                          text: words.map(\.text).joined(separator: " "), language: language, words: words, confidence: 0.9)
    }
    let turns = [SpeakerTurn(speaker: "A", start: 0, end: 5), SpeakerTurn(speaker: "B", start: 5, end: 10)]

    suite.test("each word goes to the turn it overlaps most") {
        let labels = TranscriptAssembler.assignSpeakers([word("x", 4.5, 5.4), word("y", 4.8, 5.6)], turns: turns)
        try expectEqual(labels, ["A", "B"])
    }
    suite.test("words between turns take the nearest turn within 1 s, else the previous word's speaker") {
        let sparse = [SpeakerTurn(speaker: "A", start: 0, end: 2), SpeakerTurn(speaker: "B", start: 6, end: 8)]
        let labels = TranscriptAssembler.assignSpeakers([word("lead", 1.5, 1.8), word("near", 2.5, 2.8),
                                                         word("far", 4.0, 4.2), word("late", 5.5, 5.8)], turns: sparse)
        try expectEqual(labels, ["A", "A", "A", "B"])
        let leading = TranscriptAssembler.assignSpeakers([word("orphan", 3.6, 3.8), word("b", 6.1, 6.4)], turns: sparse)
        try expectEqual(leading, ["B", "B"], "leading unplaced words take the first known label")
    }
    suite.test("a segment is split where the speaker changes") {
        let s = segment(.them, [word("so", 3.0, 3.3), word("we", 3.4, 3.6), word("agree.", 3.7, 4.5),
                                word("Yes,", 5.6, 6.0), word("exactly.", 6.1, 6.8)])
        let parts = TranscriptAssembler.splitBySpeaker(s, turns: turns)
        try expectEqual(parts.map(\.speaker), ["A", "B"])
        try expectEqual(parts.map(\.segment.text), ["so we agree.", "Yes, exactly."])
        try expectClose(parts[0].segment.range.start, 3.0, tolerance: 1e-9)
        try expectClose(parts[1].segment.range.start, 5.6, tolerance: 1e-9)
        try expectClose(parts[1].segment.range.end, 6.8, tolerance: 1e-9)
    }
    suite.test("a lone short word between two words of one speaker is treated as jitter") {
        let jitter = [SpeakerTurn(speaker: "A", start: 0, end: 2), SpeakerTurn(speaker: "B", start: 2, end: 2.3),
                      SpeakerTurn(speaker: "A", start: 2.3, end: 5)]
        let s = segment(.them, [word("one", 1.0, 1.5), word("two", 2.0, 2.3), word("three", 2.5, 3.0)])
        try expectEqual(TranscriptAssembler.splitBySpeaker(s, turns: jitter).count, 1)
    }
    suite.test("speakers: me first, then s1, s2 by first appearance, with talk time and ordered ids") {
        let diarized = [SpeakerTurn(speaker: "C1", start: 0, end: 3), SpeakerTurn(speaker: "C0", start: 4, end: 6)]
        let input = TranscriptAssembler.Input(
            me: [segment(.me, [word("হ্যাঁ", 3.2, 3.8)], language: "bn")],
            them: [segment(.them, [word("first", 0.5, 2.5)]), segment(.them, [word("second", 4.2, 5.2)])],
            turns: diarized, embeddings: ["C0": [0, 1], "C1": [1, 0]], userName: "Nahian", includeMe: true)
        let output = TranscriptAssembler.assemble(input)
        try expectEqual(output.speakers.map(\.id), ["me", "s1", "s2"])
        try expectEqual(output.speakers.map(\.name), ["Nahian", "Speaker 1", "Speaker 2"])
        try expectEqual(output.segments.map(\.speakerID), ["s1", "me", "s2"])
        try expectEqual(output.segments.map(\.id), [0, 1, 2])
        try expectClose(output.speakers[1].talkTime, 2.0, tolerance: 1e-9)
        try expectEqual(output.speakerEmbeddings["s1"], [1, 0])
        try expectEqual(output.speakerEmbeddings["s2"], [0, 1])
        try expectEqual(output.languages, ["en", "bn"])
    }
    suite.test("without diarization all remote speech is Speaker 1; no mic track means no 'me'") {
        let output = TranscriptAssembler.assemble(TranscriptAssembler.Input(
            me: [], them: [segment(.them, [word("a", 0, 1)]), segment(.them, [word("b", 9, 10)])], includeMe: false))
        try expectEqual(output.speakers.map(\.id), ["s1"])
        try expectEqual(output.segments.map(\.speakerID), ["s1", "s1"])
    }
    suite.test("echo: a mic segment repeating the remote text is flagged, not removed") {
        let remote = "I think the key question is whether we can fine tune a multilingual model"
        let input = TranscriptAssembler.Input(
            me: [segment(.me, [word("the key question is whether we can fine tune", 1.2, 4.0)]),
                 segment(.me, [word("Right, we could also try data augmentation", 6.0, 8.0)])],
            them: [segment(.them, [word(remote, 1.0, 4.5)])], includeMe: true, flagEchoes: true)
        let output = TranscriptAssembler.assemble(input)
        try expectEqual(output.segments.count, 3)
        let mine = output.segments.filter { $0.speakerID == "me" }
        try expectEqual(mine.map { $0.flags.contains(.echoSuspect) }, [true, false])
        try expectEqual(output.echoSuspects, 1)
        try expectClose(output.speakers[0].talkTime, 2.0, tolerance: 1e-9, "echo excluded from talk time")
    }
    suite.test("echo: my turns that the other side answers by repeating me, or that I answer by repeating them, stay") {
        // A headphone call as the reviewer ran it: every word below was really said by its speaker.
        func said(_ channel: AudioChannel, _ start: Double, _ end: Double, _ text: String, _ language: String) -> RecognizedSegment {
            RecognizedSegment(channel: channel, range: TimeRange(start, end), text: text, language: language, confidence: 0.9)
        }
        let input = TranscriptAssembler.Input(
            me: [said(.me, 10.0, 24.8, "So my plan is to pretrain the encoder on the unlabeled recordings first and then fine tune "
                      + "on the transcribed calls, I think that would help a lot with the accent problem", "en"),
                 said(.me, 33.4, 35.4, "হ্যাঁ আমরা চেষ্টা করে দেখতে পারি", "bn")],
            them: [said(.them, 25.3, 27.0, "Yes, I think that would help.", "en"),
                   said(.them, 28.0, 33.0, "আমার মনে হয় এই পদ্ধতিটা চেষ্টা করে দেখতে পারি", "bn")],
            includeMe: true, flagEchoes: true)
        let output = TranscriptAssembler.assemble(input)
        try expectEqual(output.echoSuspects, 0)
        try expect(!output.segments.contains { $0.flags.contains(.echoSuspect) })
        try expectClose(output.speakers[0].talkTime, 16.8, tolerance: 1e-9)
    }
    return suite
}

func echoDedupSuite() -> TestSuite {
    let suite = TestSuite("EchoDedup")
    suite.test("an echo fragment matches the far-end segment") {
        try expect(EchoDedup.similarity("talk about the research idea on speech recognition", GroundTruth.a1) >= 0.9)
    }
    suite.test("different turns don't match") {
        try expect(EchoDedup.similarity(GroundTruth.a2, GroundTruth.b1) < 0.3)
        try expect(EchoDedup.similarity(GroundTruth.bn1, GroundTruth.bn2) < 0.3)
    }
    suite.test("identical Bangla matches") {
        try expectClose(EchoDedup.similarity(GroundTruth.bn2, GroundTruth.bn2), 1, tolerance: 1e-9)
    }
    suite.test("very short texts are never judged by text") {
        try expectEqual(EchoDedup.similarity("okay", "okay"), 0)
        try expectEqual(EchoDedup.similarity("হ্যাঁ", "হ্যাঁ"), 0)
    }
    func said(_ channel: AudioChannel, _ start: Double, _ end: Double, _ text: String, language: String = "en") -> RecognizedSegment {
        RecognizedSegment(channel: channel, range: TimeRange(start, end), text: text, language: language)
    }
    /// A segment whose words are spread evenly over its range (what the recognizer reports).
    func timed(_ channel: AudioChannel, _ start: Double, _ end: Double, _ text: String) -> RecognizedSegment {
        let tokens = text.split(separator: " ").map(String.init)
        let step = (end - start) / Double(max(1, tokens.count))
        let words = tokens.enumerated().map { index, token in
            RecognizedWord(text: token, start: start + Double(index) * step, end: start + Double(index + 1) * step, probability: 0.9)
        }
        return RecognizedSegment(channel: channel, range: TimeRange(start, end), text: text, language: "en", words: words)
    }
    suite.test("an echo coincides with the remote speech, delayed by the lag; a repeat after it doesn't") {
        let them = [said(.them, 8, 12.2, GroundTruth.b2)]
        let me = [said(.me, 8.12, 12.32, GroundTruth.b2),        // the loudspeaker echo
                  said(.me, 13.0, 17.2, GroundTruth.b2),         // the same words, said after the remote turn
                  said(.me, 30, 34.2, GroundTruth.b2)]
        try expectEqual(EchoDedup.echoSuspects(me: me, them: them), [0])
        try expectEqual(EchoDedup.echoSuspects(me: me, them: them, lag: 0.12...0.12), [0])
        // Delayed beyond the measured lag by more than the timing tolerance: not that echo.
        try expectEqual(EchoDedup.echoSuspects(me: [said(.me, 10.0, 14.2, GroundTruth.b2)], them: them, lag: 0.12...0.12), [])
        // An unmeasured AirPlay-like delay still matches.
        try expectEqual(EchoDedup.echoSuspects(me: [said(.me, 8.7, 12.9, GroundTruth.b2)], them: them), [0])
    }
    suite.test("agreeing by repeating the other side's words is not echo (English and Bangla)") {
        let english = said(.them, 0, 6, "I think we can try this approach and see if it helps with the accent problem")
        let reply = said(.me, 6.4, 8.4, "Yes we can try this approach")
        let bangla = said(.them, 20, 25, "আমার মনে হয় এই পদ্ধতিটা চেষ্টা করে দেখতে পারি", language: "bn")
        let agreement = said(.me, 25.3, 27.3, "হ্যাঁ আমরা চেষ্টা করে দেখতে পারি", language: "bn")
        try expect(EchoDedup.containment(of: reply.text, in: english.text) >= 0.8, "the words do repeat")
        try expectEqual(EchoDedup.echoSuspects(me: [reply, agreement], them: [english, bangla]), [])
        try expectEqual(EchoDedup.echoSuspects(me: [reply, agreement], them: [english, bangla], lag: 0.05...0.05), [])
    }
    suite.test("a long turn is not the echo of a short reply that repeats part of it") {
        let monologue = said(.me, 10.0, 24.8, "So my plan is to pretrain the encoder on the unlabeled recordings first and then fine tune "
                                + "on the transcribed calls, I think that would help a lot with the accent problem")
        let reply = said(.them, 25.3, 27.0, "Yes, I think that would help.")
        try expect(EchoDedup.similarity(monologue.text, reply.text) >= 0.8, "symmetric containment can't tell them apart")
        try expect(EchoDedup.containment(of: monologue.text, in: reply.text) < 0.3)
        try expectEqual(EchoDedup.echoSuspects(me: [monologue], them: [reply]), [])
        try expectEqual(EchoDedup.echoSuspects(me: [said(.me, 27.4, 29.0, "Yes I think so too")],
                                               them: [said(.them, 12, 27.0, "Well I think so, and the second part I think so too")],
                                               lag: 0.05...0.05), [])
    }
    suite.test("only what the remote side said at that moment counts, by word time") {
        // The reply repeats words the remote side said at its start, ten seconds before the reply.
        let remote = timed(.them, 0, 10, "we can try this approach first and later we will look at the other ideas together")
        let reply = said(.me, 10.3, 11.8, "we can try this approach")
        try expectEqual(EchoDedup.echoSuspects(me: [reply], them: [remote]), [])
        // The same words, echoed while they are being played, are flagged.
        try expectEqual(EchoDedup.echoSuspects(me: [said(.me, 0.1, 2.6, "we can try this approach")], them: [remote]), [0])
    }
    suite.test("an echo across two remote segments is flagged; a segment with my own words added is kept") {
        let them = [said(.them, 10, 13, "the key question is whether we can"), said(.them, 13.2, 16, "fine tune a multilingual model")]
        let echo = said(.me, 10.15, 16.2, "the key question is whether we can fine tune a multilingual model")
        let mixed = said(.me, 10.15, 20, "the key question is whether we can fine tune a multilingual model right we could also "
                            + "try data augmentation and pseudo labeling from unlabeled recordings")
        try expectEqual(EchoDedup.echoSuspects(me: [echo, mixed], them: them, lag: 0.15...0.15), [0])
    }
    return suite
}

func speakerClusteringSuite() -> TestSuite {
    let suite = TestSuite("SpeakerClustering")
    func cluster(centres: Int, perCentre: Int, noise: Float, seed: UInt64) -> (embeddings: [[Float]], truth: [Int]) {
        var rng = SeededGenerator(seed: seed)
        let centreVectors = (0..<centres).map { _ in SpeakerClustering.normalized((0..<256).map { _ in rng.gaussian() }) }
        var embeddings: [[Float]] = [], truth: [Int] = []
        for i in 0..<(centres * perCentre) {
            let c = (i * 7) % centres   // interleaved like turns in a call
            embeddings.append(centreVectors[c].map { $0 + noise * rng.gaussian() / 16 })
            truth.append(c)
        }
        return (embeddings, truth)
    }
    func samePartition(_ a: [Int], _ b: [Int]) -> Bool {
        var mapping: [Int: Int] = [:], reverse: [Int: Int] = [:]
        for (x, y) in zip(a, b) {
            if let m = mapping[x], m != y { return false }
            if let r = reverse[y], r != x { return false }
            mapping[x] = y
            reverse[y] = x
        }
        return true
    }
    suite.test("recovers three speakers from noisy embeddings") {
        let (embeddings, truth) = cluster(centres: 3, perCentre: 20, noise: 0.6, seed: 7)
        let labels = SpeakerClustering.agglomerative(embeddings, weights: embeddings.map { _ in 2.0 }, threshold: 0.55)
        try expectEqual(Set(labels).count, 3)
        try expect(samePartition(labels, truth))
    }
    suite.test("labels are numbered by first appearance") {
        let (embeddings, _) = cluster(centres: 3, perCentre: 5, noise: 0.3, seed: 11)
        let labels = SpeakerClustering.agglomerative(embeddings, weights: embeddings.map { _ in 1.0 })
        var seen: [Int] = []
        for label in labels where !seen.contains(label) { seen.append(label) }
        try expectEqual(seen, Array(0..<seen.count))
    }
    suite.test("maxClusters keeps merging below the threshold") {
        let (embeddings, _) = cluster(centres: 3, perCentre: 10, noise: 0.5, seed: 3)
        let labels = SpeakerClustering.agglomerative(embeddings, weights: embeddings.map { _ in 1.0 }, maxClusters: 2)
        try expectEqual(Set(labels).count, 2)
    }
    suite.test("clusters below the minimum weight are folded into the nearest big one") {
        var (embeddings, _) = cluster(centres: 2, perCentre: 10, noise: 0.4, seed: 5)
        var rng = SeededGenerator(seed: 99)
        embeddings.append(SpeakerClustering.normalized((0..<256).map { _ in rng.gaussian() }))   // a stray 1 s unit
        var weights = [Double](repeating: 3, count: 20)
        weights.append(1)
        try expectEqual(Set(SpeakerClustering.agglomerative(embeddings, weights: weights)).count, 3)
        try expectEqual(Set(SpeakerClustering.agglomerative(embeddings, weights: weights, minClusterWeight: 4)).count, 2)
    }
    suite.test("degenerate inputs") {
        try expectEqual(SpeakerClustering.agglomerative([], weights: []), [])
        try expectEqual(SpeakerClustering.agglomerative([[1, 0]], weights: [1]), [0])
    }
    suite.test("centroids are L2-normalized weighted means") {
        let centroids = SpeakerClustering.centroids([[1, 0], [0, 1], [1, 1]], weights: [1, 1, 2], labels: [0, 0, 1])
        let first = try expectNotNil(centroids[0])
        try expectClose(Double(first[0]), Double(first[1]), tolerance: 1e-6)
        try expectClose(Double(first[0] * first[0] + first[1] * first[1]), 1, tolerance: 1e-5)
    }
    return suite
}

func echoGateSuite() -> TestSuite {
    let suite = TestSuite("EchoGate")
    suite.test("finds a 120 ms loudspeaker lag and attenuates echo-only frames") {
        let call = try TestAudio.load("two_speakers_en.wav")
        let user = try TestAudio.load("bangla.wav")
        var rng = SeededGenerator(seed: 1)
        var mic = [Float](repeating: 0, count: call.count)
        for i in mic.indices { mic[i] = (i >= 1_920 ? 0.25 * call[i - 1_920] : 0) + Float.random(in: -0.002...0.002, using: &rng) }
        let userStart = 5 * 16_000
        for (i, value) in user.enumerated() where userStart + i < mic.count { mic[userStart + i] += 0.8 * value }

        let micEnvelope = EchoGate.logEnergyEnvelope(mic), callEnvelope = EchoGate.logEnergyEnvelope(call)
        let lag = try expectNotNil(EchoGate.estimateLag(mic: micEnvelope, call: callEnvelope))
        try expectEqual(lag.lag, 12, "120 ms")
        let mask = EchoGate.echoMask(micEnvelope: micEnvelope, callEnvelope: callEnvelope, lag: lag.lag)
        let userEnvelope = EchoGate.logEnergyEnvelope(TestAudio.timeline([(user, 5, 0.8)], duration: Double(call.count) / 16_000))
        var echoOnly = 0, echoCaught = 0, userFrames = 0, userFlagged = 0
        for frame in 0..<min(mask.count, userEnvelope.count) {
            if userEnvelope[frame] > -40 {
                userFrames += 1
                if mask[frame] { userFlagged += 1 }
            } else if frame >= lag.lag && callEnvelope[frame - lag.lag] > -40 {
                echoOnly += 1
                if mask[frame] { echoCaught += 1 }
            }
        }
        let caught = Double(echoCaught) / Double(max(1, echoOnly)), wrong = Double(userFlagged) / Double(max(1, userFrames))
        print("      echo-only frames caught \(percent(caught)), user frames flagged \(percent(wrong))")
        try expect(caught >= 0.85, "caught \(caught)")
        try expect(wrong <= 0.12, "wrongly flagged \(wrong)")

        var gated = mic
        let report = EchoGate.suppress(mic: &gated, call: call)
        try expectClose(report.lagSeconds ?? 0, 0.12, tolerance: 0.011)
        try expect(gated != mic)
    }
    suite.test("echo runs are bridged over short misses and scattered flags are ignored") {
        // 10 ms frames: echo 1.00–2.00 s with a 0.1 s miss, plus two isolated false positives.
        var mask = [Bool](repeating: false, count: 400)
        for i in 100..<200 where !(140..<150).contains(i) { mask[i] = true }
        mask[300] = true
        mask[320] = true
        let runs = EchoGate.echoRanges(mask: mask)
        try expectEqual(runs.count, 1, "\(runs)")
        try expectClose(runs[0].start, 1.0, tolerance: 1e-9)
        try expectClose(runs[0].end, 2.0, tolerance: 1e-9)
    }
    suite.test("does nothing without an echo") {
        let call = try TestAudio.load("two_speakers_en.wav")
        var mic = TestAudio.timeline([(try TestAudio.load("bangla.wav"), 3, 1)], duration: Double(call.count) / 16_000)
        let original = mic
        let report = EchoGate.suppress(mic: &mic, call: call)
        try expect(report.lagSeconds == nil, "lag \(String(describing: report.lagSeconds)) r=\(report.correlation)")
        try expect(mic == original)
    }
    return suite
}

func audioLoaderSuite() -> TestSuite {
    let suite = TestSuite("AudioLoader")
    suite.test("reads 16 kHz mono PCM16 exactly") {
        let samples = try TestAudio.load("a1.wav")
        let file = try AVAudioFile(forReading: TestAudio.url("a1.wav"))
        try expectEqual(samples.count, Int(file.length))
        try expectClose(try AudioLoader.duration(of: TestAudio.url("a1.wav")), 7.28525, tolerance: 1e-4)
    }
    suite.test("resamples 48 kHz stereo without duplicating audio and averages the channels") {
        let url = scratchDirectory("audio-stereo").appendingPathComponent("stereo48k.wav")
        let format = try expectNotNil(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false))
        let frames: AVAudioFrameCount = 96_000   // 2 s
        let buffer = try expectNotNil(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let channels = try expectNotNil(buffer.floatChannelData)
        for n in 0..<Int(frames) {
            channels[0][n] = 0
            channels[1][n] = 0.5 * sinf(2 * .pi * 440 * Float(n) / 48_000)   // right channel only
        }
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: buffer)
        }
        let samples = try AudioLoader.load(url)
        try expect(abs(samples.count - 32_000) <= 64, "got \(samples.count) samples for 2 s")
        let rms = (samples.reduce(0) { $0 + Double($1) * Double($1) } / Double(samples.count)).squareRoot()
        try expectClose(rms, 0.5 / 2.squareRoot() / 2, tolerance: 0.01, "true downmix halves a one-sided signal")
    }
    suite.test("reads AAC (m4a)") {
        let source = try TestAudio.load("a1.wav")
        let url = scratchDirectory("audio-m4a").appendingPathComponent("a1.m4a")
        let format = try expectNotNil(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false))
        let buffer = try expectNotNil(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(source.count)))
        buffer.frameLength = AVAudioFrameCount(source.count)
        let channel = try expectNotNil(buffer.floatChannelData)[0]
        for (i, value) in source.enumerated() { channel[i] = value }
        do {
            let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16_000,
                                           AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 48_000]
            let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: buffer)
        }
        let decoded = try AudioLoader.load(url)
        try expect(abs(Double(decoded.count - source.count)) / 16_000 < 0.1, "\(decoded.count) vs \(source.count)")
        try expectClose(AudioLoader.rmsDecibels(decoded), AudioLoader.rmsDecibels(source), tolerance: 1.5)
    }
    suite.test("unreadable files throw audioUnreadable") {
        let url = scratchDirectory("audio-garbage").appendingPathComponent("garbage.wav")
        try Data("not audio".utf8).write(to: url)
        do {
            _ = try AudioLoader.load(url)
            throw fail("expected an error")
        } catch TranscriptionError.audioUnreadable {
        }
    }
    suite.test("an empty WAV gives no samples") {
        let url = scratchDirectory("audio-empty").appendingPathComponent("empty.wav")
        try TestAudio.writeWAV([], to: url)
        try expectEqual(try AudioLoader.load(url).count, 0)
    }
    return suite
}

func commandSuite() -> TestSuite {
    let suite = TestSuite("TranscribeCommand")
    suite.test("a single file is the remote track") {
        let options = try TranscribeCommand.parse(["transcribe", "call.m4a", "--json", "--lang", "bn", "--speakers", "3"])
        try expectEqual(options.them?.lastPathComponent, "call.m4a")
        try expect(options.me == nil && options.json && options.maxSpeakers == 3)
        try expectEqual(options.languageMode, .bangla)
    }
    suite.test("--me/--them and model overrides") {
        let options = try TranscribeCommand.parse(["--me", "me.wav", "--them", "them.wav", "--no-diarize",
                                                   "--general", "large-v3", "--english", "large-v3-turbo",
                                                   "--bangla", "bengali-medium-q5_0", "--lang", "en"])
        try expectEqual(options.me?.lastPathComponent, "me.wav")
        try expectEqual(options.them?.lastPathComponent, "them.wav")
        try expect(!options.diarize)
        try expectEqual([options.generalModelID, options.englishModelID, options.banglaModelID],
                        ["large-v3", "large-v3-turbo", "bengali-medium-q5_0"])
        try expectEqual(options.languageMode, .english)
    }
    suite.test("usage errors") {
        try expectThrows { _ = try TranscribeCommand.parse([]) }
        try expectThrows { _ = try TranscribeCommand.parse(["a.wav", "b.wav"]) }
        try expectThrows { _ = try TranscribeCommand.parse(["a.wav", "--me", "b.wav"]) }
        try expectThrows { _ = try TranscribeCommand.parse(["a.wav", "--lang", "fr"]) }
        try expectThrows { _ = try TranscribeCommand.parse(["a.wav", "--speakers", "0"]) }
        try expectThrows { _ = try TranscribeCommand.parse(["a.wav", "--bogus"]) }
        try expect(try TranscribeCommand.parse(["--help"]).help)
    }
    suite.test("readable transcript lines") {
        let output = TranscriptionOutput(
            segments: [TranscriptSegment(id: 0, start: 5.4, end: 7, speakerID: "me", channel: .me, text: "Hello", language: "en"),
                       TranscriptSegment(id: 1, start: 3725, end: 3727, speakerID: "s1", channel: .them, text: "হ্যাঁ", language: "bn"),
                       TranscriptSegment(id: 2, start: 3730, end: 3731, speakerID: "me", channel: .me, text: "echo", language: "en",
                                         flags: [.echoSuspect])],
            speakers: [Speaker(id: "me", name: "Nahian", isMe: true), Speaker(id: "s1", name: "Speaker 1", isMe: false)],
            languages: ["en", "bn"])
        try expectEqual(TranscribeCommand.transcriptLines(output),
                        ["[00:00:05] Nahian (en): Hello", "[01:02:05] Speaker 1 (bn): হ্যাঁ"])
        try expectEqual(TranscribeCommand.transcriptLines(output, showEcho: true).count, 3)
    }
    return suite
}

func unitSuites() -> [TestSuite] {
    [chunkPlannerSuite(), speechSegmenterSuite(), languageRouterSuite(), textPostProcessorSuite(), tokenAssemblerSuite(),
     transcriptAssemblerSuite(), echoDedupSuite(), speakerClusteringSuite(), echoGateSuite(), audioLoaderSuite(),
     commandSuite()]
}
