import CWhisper
import Foundation

/// Kan's transcription module: whisper.cpp (Metal) recognition for Bangla and English, Silero VAD,
/// per-chunk {bn, en} language routing, FluidAudio speaker diarization, echo handling, model
/// management and transcript assembly.
///
/// Entry points:
///  - `TranscriptionPipeline` — `Transcribing`, used by the processing queue.
///  - `ModelStore` — `ModelManaging`: catalog, resumable downloads, "auto" model resolution.
///  - `TranscribeCommand` — `kan transcribe …`.
///
/// The pure building blocks (`ChunkPlanner`, `LanguageRouter`, `TextPostProcessor`,
/// `TokenAssembler`, `TranscriptAssembler`, `EchoDedup`, `SpeakerClustering`, `SpeechSegmenter`,
/// `EchoGate`, `AudioLoader`) are public so they can be tested and reused.
public enum KanTranscribeModule {
    public static var whisperVersion: String { String(cString: whisper_version()) }
}
