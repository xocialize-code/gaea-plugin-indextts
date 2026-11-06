import Foundation
import GaeaPluginKit
import GaeaProtocol
import MLX
import MLXIndexTTS2TTS
import MLXToolKit

// gaea-plugin-indextts: bilibili's IndexTTS 2.5 (bilibili Model Use Licence weights, allowlisted by the fleet,
// AB-D-0060; the MLX port, mlx-indextts2-swift, is Apache-2.0) on MES Audio 0.1 (Gaea G5 order 1, AB-T-0452). One model,
// `indextts-2.5`, on audio.speak, cloning from voice_ref in five languages:
//
// - No preset voices and no default voice: a reference clip is the voice (`voice_ref`); its transcript isn't used.
// - Emotion decoupled from the speaker: an MES label (the eight the package's presets name, `neutral` sending none),
//   with `intensity` as the package's emoAlpha (0.6 when absent), or `x-indextts.emotion_vector`, the eight weights
//   (0–1.2) in the order happy, angry, sad, afraid, disgusted, melancholic, surprised, calm (Audio §2, extensions).
// - `target_duration_s` pins the take's length (the length regulator), the pauses kept and the rest shared by the
//   pieces' characters; `speed` is the package's speechRate. With both, the duration wins.
// - `[pause Ns]` is silence between pieces, the one cue the offer lists.
//
// Three lanes, the GPT backbone's quant: fp16 (as shipped, the default), int8 and int4. The GPT samples from MLX's
// random state, so the worker seeds it, and passes the seed to the package, before every piece: the same request
// gives the same WAV, here and in indextts-inproc.
//
// The reference's conditioning is what the package can cache, under a key the worker gives it (AB-A-0251): MES Base
// §13 rule 6, a reference that is an asset is keyed by its asset id, kept while the asset lives, and evicted when Gaea
// says it's gone (`onAssetRemoved`); any other reference is keyed by the job and evicted when the job ends (rules 1–4).

public let modelID = "indextts-2.5"
public let maxTextChars = 2000

/// The MES emotion labels the package's presets take (Audio §2.1); `neutral` sends none.
public let emotions = ["neutral", "happy", "angry", "sad", "afraid", "disgusted", "melancholic", "surprised", "calm"]
/// The package's eight preset axes, in its order: the order of `x-indextts.emotion_vector`.
public let emotionAxes = ["happy", "angry", "sad", "afraid", "disgusted", "melancholic", "surprised", "calm"]
public let defaultIntensity = 0.6
public let vectorParam = "x-indextts.emotion_vector"

public func configuration(_ quant: Quant) -> IndexTTS2Configuration { IndexTTS2Configuration(quant: quant) }

public let lanes: [LaneDefinition] = [("fp16", Quant.fp16), ("int8", .int8), ("int4", .int4)].map { id, quant in
    LaneDefinition(id: id, default: id == "fp16", configuration: configuration(quant))
}

// MARK: - speak

/// What a speak job asks of the package, validated.
public struct SpeakPlan: Sendable {
    public var pieces: [Piece]
    public var reference: Data
    public var language: String
    public var emotion: TTSEmotion?
    public var intensity: Double
    /// Each word piece's length, when the request asked for the take's (`target_duration_s`).
    public var targets: [Double]?
    public var speechRate: Double?
    public var seed: UInt64
    /// The package's cache key: the asset id, else one for this job alone.
    public var cacheKey: String
    /// Whether the key is the job's own, to evict when it ends.
    public var jobScoped: Bool
    public var warnings: [Warning]
    public var effective: [String: JSONValue]
}

public func speakPlan(text: String?, reference wav: Data?, language tag: String?, emotion: JSONValue?, vector: JSONValue?,
                      targetDuration: Double?, speed: Double?, asset: String?, job: String, seed: UInt64) throws -> SpeakPlan {
    guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw GPPError(.invalidRequest, "audio.speak needs text.", detail: ["param": "text"])
    }
    guard text.count <= maxTextChars else {
        throw GPPError(.invalidRequest, "IndexTTS 2.5 speaks at most \(maxTextChars) characters at a time.",
                       detail: ["param": "text", "mes_code": "out_of_limits"])
    }
    guard let wav else {
        throw GPPError(.invalidRequest, "IndexTTS 2.5 speaks only in a cloned voice: send voice_ref.", detail: ["param": "voice_ref"])
    }
    let (clip, seconds, refWarnings) = try reference(wav)
    let pieces = try plan(text)
    let lang = try language(tag) ?? detectedLanguage(text)
    var warnings = refWarnings
    var effective: [String: JSONValue] = ["language": .string(lang), "seed": .int(Int64(seed)),
                                          "x-indextts.voice_ref_s": .double((seconds * 100).rounded() / 100)]

    // Emotion: a label, or the extension's vector, never both.
    var typed: TTSEmotion?
    var intensity = defaultIntensity
    if let given = emotion?["intensity"]?.doubleValue {
        guard (0...1).contains(given) else {
            throw GPPError(.invalidRequest, "emotion.intensity is 0–1.", detail: ["param": "emotion"])
        }
        intensity = given
    }
    if let vector {
        guard emotion?["label"] == nil else {
            throw GPPError(.invalidRequest, "Send an emotion label or \(vectorParam), not both.", detail: ["param": .string(vectorParam)])
        }
        guard case .array(let values) = vector, values.count == emotionAxes.count,
              let weights = Optional(values.compactMap(\.doubleValue)), weights.count == emotionAxes.count,
              weights.allSatisfy({ (0...1.2).contains($0) }) else {
            throw GPPError(.invalidRequest, "\(vectorParam) is eight weights of 0–1.2, in the order \(emotionAxes.joined(separator: ", ")).",
                           detail: ["param": .string(vectorParam)])
        }
        typed = .vector(weights.map(Float.init))
        effective[vectorParam] = vector
        effective["x-indextts.emo_alpha"] = .double(intensity)
    } else if let label = emotion?["label"]?.stringValue {
        guard emotions.contains(label) else {
            throw GPPError(.invalidRequest, "IndexTTS 2.5 can't act \(label).", detail: ["param": "emotion", "mes_code": "unsupported_parameter"])
        }
        if label != "neutral" {
            typed = .categorical(label)
            effective["x-indextts.emo_alpha"] = .double(intensity)
        }
        effective["emotion"] = emotion
    }

    // Length: the take's, else the pace.
    var targets: [Double]?
    var rate: Double?
    if let targetDuration {
        guard targetDuration > 0, targetDuration <= 600 else {
            throw GPPError(.invalidRequest, "target_duration_s is above 0 and at most 600.",
                           detail: ["param": "target_duration_s", "mes_code": "out_of_limits"])
        }
        guard let shares = pieceTargets(pieces, target: targetDuration) else {
            throw GPPError(.invalidRequest, String(format: "%g s leaves too little time for the words once the pauses are kept.", targetDuration),
                           detail: ["param": "target_duration_s", "mes_code": "out_of_limits"])
        }
        targets = shares
        effective["target_duration_s"] = .double(targetDuration)
        if let speed, speed != 1 {
            warnings.append(Warning(code: "param_adjusted", message: "speed was set by target_duration_s.", param: "speed"))
        }
    } else if let speed, speed != 1 {
        guard (0.5...2).contains(speed) else {
            throw GPPError(.invalidRequest, "speed is 0.5–2.", detail: ["param": "speed", "mes_code": "out_of_limits"])
        }
        rate = speed
        effective["speed"] = .double(speed)
    }
    return SpeakPlan(pieces: pieces, reference: clip, language: lang, emotion: typed, intensity: intensity, targets: targets,
                     speechRate: rate, seed: seed, cacheKey: asset ?? "job:\(job)", jobScoped: asset == nil, warnings: warnings,
                     effective: effective)
}

/// The engine request for word piece `i` of a speak plan.
public func request(_ plan: SpeakPlan, piece i: Int, words: String) -> TTSRequest {
    var meta: MetaData = ["seed": .int(Int(plan.seed)), "language": .string(plan.language), "voiceCacheKey": .string(plan.cacheKey)]
    if plan.emotion != nil { meta["emoAlpha"] = .double(plan.intensity) }
    if let rate = plan.speechRate { meta["speechRate"] = .double(rate) }
    return TTSRequest(text: words, voice: VoiceSelector(.referenceAudio(Audio(format: .wav, data: plan.reference, sampleRate: nil, channels: 1))),
                      emotion: plan.emotion, targetDuration: plan.targets?[i], metaData: meta)
}

/// The package's eviction call for cache keys (AB-A-0251, as mlx-qwen3-tts-swift 0.7.0's): empty text, no synthesis.
public func eviction(_ keys: [String]) -> TTSRequest {
    TTSRequest(text: "", metaData: ["evictVoiceCacheKeys": .array(keys.map { .string($0) })])
}

/// Seeds MLX's random state, then draws `request` through `run` and returns the WAV.
public func draw(_ request: TTSRequest, seed: UInt64, run: (TTSRequest) async throws -> any CapabilityResponse) async throws -> Data {
    MLXRandom.seed(seed)
    guard let response = try await run(request) as? TTSResponse else {
        throw GPPError(.modelError, "IndexTTS 2.5 returned no audio.")
    }
    return response.audio.data
}

/// A take that missed `target_duration_s` by more than a tenth of a second and 3 %: `duration_missed` (Audio §3.2).
public func durationWarning(_ pcm: Data, target: Double?) -> Warning? {
    guard let target else { return nil }
    let seconds = Double(pcm.count / 2) / Double(sampleRate)
    guard abs(seconds - target) > max(0.1, 0.03 * target) else { return nil }
    return Warning(code: "duration_missed", message: String(format: "The take is %.2f s, not %g s.", seconds, target),
                   param: "target_duration_s")
}

let speakOperation = EngineOperation("audio.speak") { job, session in
    let plan = try speakPlan(text: try job.text("text"), reference: try job.input("voice_ref").map { try Data(contentsOf: $0) },
                             language: job.param("language")?.stringValue, emotion: job.param("emotion"), vector: job.param(vectorParam),
                             targetDuration: job.param("target_duration_s")?.doubleValue, speed: job.param("speed")?.doubleValue,
                             asset: job.asset("voice_ref"), job: job.job, seed: seed(job))
    let send: (TTSRequest) async throws -> any CapabilityResponse = { try await session.run($0 as! any WireRequest) }
    let pcm: Data
    do {
        pcm = try await speak(plan.pieces) { i, words in try await draw(request(plan, piece: i, words: words), seed: plan.seed, run: send) }
    } catch {
        if plan.jobScoped { _ = try? await send(eviction([plan.cacheKey])) }
        throw error
    }
    // A reference that isn't an asset lives no longer than its job (MES Base §13 rules 1–4).
    if plan.jobScoped { _ = try? await send(eviction([plan.cacheKey])) }
    var warnings = plan.warnings
    if let missed = durationWarning(pcm, target: plan.effective["target_duration_s"]?.doubleValue) { warnings.append(missed) }
    let url = session.outputDir.appending(path: "audio-0.wav")
    try wav16(pcm).write(to: url)
    return RunResult(outputs: [.file("audio", url, mediaType: "audio/wav")], effective: plan.effective, warnings: warnings)
}

// MARK: - The plugin

let license: JSONValue = ["spdx": "LicenseRef-bilibili-Model-Use", "commercial_use": true,
                          "terms_url": "https://huggingface.co/IndexTeam/IndexTTS-2.5"]

let model = ModelDefinition.engine(IndexTTS2Package.self, id: modelID, title: "IndexTTS 2.5", lanes: lanes,
                                   operations: [speakOperation])

/// The offer's extension (Base §6.2), declared so Gaea admits and forwards it: the eight emotion weights.
let params: JSONValue = [
    "type": "object", "additionalProperties": false,
    "properties": [
        "x-indextts.emotion_vector": [
            "type": "array", "minItems": 8, "maxItems": 8, "items": ["type": "number", "minimum": 0, "maximum": 1.2],
            "description": "Instead of an emotion label: eight weights, 0–1.2, for happy, angry, sad, afraid, disgusted, melancholic, surprised and calm, blended. emotion.intensity scales them (0.6 when absent).",
            "x-mes-ui": ["label": "Emotion mix", "advanced": true],
        ],
    ],
]

let offer = PluginManifest.Offer(
    operation: "audio.speak", profile: "audio",
    model: [
        "id": .string(modelID), "title": "IndexTTS 2.5",
        "license": license, "memory_class": "medium", "speed_class": "standard", "quality_tiers": ["standard", "best"],
        "notes": "Speaks in the voice of a reference clip (1 to 20 s) in Chinese, English, Japanese, Spanish and Arabic, with the emotion set apart from the voice: a label and its intensity, or x-indextts.emotion_vector, eight weights (happy, angry, sad, afraid, disgusted, melancholic, surprised, calm). target_duration_s fits a dub cue; [pause 1s] adds silence. Name the language for Spanish: unnamed Latin text is read as English. Numbers aren't spelled out in Chinese and English: write them as words.",
        "supports": [
            "voice_ref": true, "voice_ref_text": "unused", "languages": .array(languageTags.map { .string($0) }),
            "emotions": .array(emotions.map { .string($0) }), "emotion_intensity": true,
            "speed": true, "target_duration": true, "cues": ["pause"],
            "sample_rate": .int(Int64(sampleRate)), "channels": 1,
        ],
        "limits": ["max_text_chars": .int(Int64(maxTextChars)), "max_voice_ref_s": .double(maxVoiceRefSeconds),
                   "max_duration_s": 600],
    ],
    params: params)

/// Gaea says an asset is gone: the model forgets the reference it cached under it, if it's loaded.
let forgetAsset: @Sendable (String, ResidentEngine) async -> Void = { asset, resident in
    _ = try? await resident.run(eviction([asset]), model: modelID)
}

public let indexTTSPlugin = GaeaPluginDefinition(
    id: "com.xocialize.gaea.indextts", version: "0.1.1", minGaea: "1.0.0", team: "CFZS6RXUCP",
    repo: "https://github.com/xocialize-code/gaea-plugin-indextts", title: "IndexTTS 2.5",
    summary: "IndexTTS 2.5 (bilibili): speech in a voice cloned from a clip, in five languages, with the emotion set apart from the voice and the length fitted to a cue (MES audio.speak).",
    license: "Apache-2.0", executable: "gaea-indextts-worker",
    models: [model], offers: [offer], onAssetRemoved: forgetAsset)
