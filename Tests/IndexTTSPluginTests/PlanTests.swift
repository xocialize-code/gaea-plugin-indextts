import Foundation
import GaeaProtocol
@testable import IndexTTSPlugin
import MLXToolKit
import Testing

/// A mono 16-bit WAV of `seconds` of silence at `rate`, `channels` wide.
func clip(_ seconds: Double, rate: Int = 16000, channels: Int = 1) -> Data {
    var out = Data()
    let pcm = Data(count: Int(seconds * Double(rate)) * 2 * channels)
    func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }
    func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }
    out.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + pcm.count)); out.append(contentsOf: Array("WAVE".utf8))
    out.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(UInt16(channels)); u32(UInt32(rate))
    u32(UInt32(rate * 2 * channels)); u16(UInt16(2 * channels)); u16(16)
    out.append(contentsOf: Array("data".utf8)); u32(UInt32(pcm.count))
    out.append(pcm)
    return out
}

func plan(_ text: String = "Hello there.", ref: Data? = clip(3), language: String? = nil, emotion: JSONValue? = nil,
          vector: JSONValue? = nil, target: Double? = nil, speed: Double? = nil, asset: String? = nil) throws -> SpeakPlan {
    try speakPlan(text: text, reference: ref, language: language, emotion: emotion, vector: vector, targetDuration: target,
                  speed: speed, asset: asset, job: "j1", seed: 7)
}

@Suite("Requests")
struct PlanTests {
    @Test func pausesSplitTheTextAndBracketsStayWords() throws {
        #expect(try IndexTTSPlugin.plan("Hello there. [pause 1.5s] Second line [pause] end \\[aside]")
            == [.words("Hello there."), .pause(1.5), .words("Second line"), .pause(0.5), .words("end [aside]")])
        #expect(throws: GPPError.self) { try IndexTTSPlugin.plan("a [pause 11s] b") }
        #expect(throws: GPPError.self) { try IndexTTSPlugin.plan("[pause 1s]") }
    }

    @Test func languagesAreNamedOrDetectedByScript() throws {
        #expect(try plan(language: "es-MX").language == "es")
        #expect(try plan("你好，世界").language == "zh")
        #expect(try plan("こんにちは、世界").language == "ja")
        #expect(try plan("東京へようこそ").language == "ja")
        #expect(try plan("مرحبا بالعالم").language == "ar")
        #expect(try plan("Hola, mundo").language == "en")
        #expect(throws: GPPError.self) { try plan(language: "fr") }
    }

    @Test func aReferenceIsRequiredAndKeyedByItsAssetOrTheJob() throws {
        #expect(throws: GPPError.self) { try plan(ref: nil) }
        #expect(throws: GPPError.self) { try plan(ref: clip(0.5)) }
        let job = try plan()
        #expect(job.cacheKey == "job:j1" && job.jobScoped)
        let asset = try plan(asset: "ast_1")
        #expect(asset.cacheKey == "ast_1" && !asset.jobScoped)
        #expect(request(asset, piece: 0, words: "Hi").metaData["voiceCacheKey"] == .string("ast_1"))
        let stereo = try plan(ref: clip(30, channels: 2))
        #expect(Set(stereo.warnings.map(\.code)) == ["audio_downmixed", "voice_ref_trimmed"])
        #expect(stereo.effective["x-indextts.voice_ref_s"] == .double(20))
    }

    @Test func emotionsLabelsIntensityAndTheVector() throws {
        let happy = try plan(emotion: ["label": "happy", "intensity": 0.8])
        #expect(happy.emotion == .categorical("happy") && happy.intensity == 0.8)
        #expect(request(happy, piece: 0, words: "Hi").metaData["emoAlpha"] == .double(0.8))
        let neutral = try plan(emotion: ["label": "neutral"])
        #expect(neutral.emotion == nil && request(neutral, piece: 0, words: "Hi").metaData["emoAlpha"] == nil)
        #expect(throws: GPPError.self) { try plan(emotion: ["label": "excited"]) }
        #expect(throws: GPPError.self) { try plan(emotion: ["label": "happy", "intensity": 1.5]) }
        let vector = try plan(vector: [0, 1, 0, 0, 0, 0, 0, 0.5])
        #expect(vector.emotion == .vector([0, 1, 0, 0, 0, 0, 0, 0.5]) && vector.intensity == defaultIntensity)
        #expect(throws: GPPError.self) { try plan(vector: [0, 1, 0]) }
        #expect(throws: GPPError.self) { try plan(vector: [0, 1.5, 0, 0, 0, 0, 0, 0]) }
        #expect(throws: GPPError.self) { try plan(emotion: ["label": "sad"], vector: [0, 1, 0, 0, 0, 0, 0, 0]) }
    }

    @Test func theDurationIsSharedByThePiecesAndWinsOverSpeed() throws {
        let fit = try plan("One two three four. [pause 1s] Five six.", target: 5, speed: 1.5)
        let targets = try #require(fit.targets)
        #expect(abs(targets.reduce(0, +) - 4) < 1e-9 && targets[0] > targets[1])
        #expect(fit.speechRate == nil && fit.warnings.map(\.code) == ["param_adjusted"])
        #expect(request(fit, piece: 1, words: "Five six.").targetDuration == targets[1])
        #expect(throws: GPPError.self) { try plan("a [pause 5s] b", target: 5) }
        let paced = try plan(speed: 1.3)
        #expect(paced.speechRate == 1.3 && request(paced, piece: 0, words: "Hi").metaData["speechRate"] == .double(1.3))
        #expect(throws: GPPError.self) { try plan(speed: 3) }
        #expect(durationWarning(Data(count: sampleRate * 2 * 4), target: 4) == nil)
        #expect(durationWarning(Data(count: sampleRate * 2 * 3), target: 4)?.code == "duration_missed")
    }

    @Test func requestsCarryTheSeedAndLanguage() throws {
        let r = request(try plan(language: "en"), piece: 0, words: "Hi")
        #expect(r.metaData["seed"] == .int(7) && r.metaData["language"] == .string("en"))
        #expect(eviction(["a", "b"]).metaData["evictVoiceCacheKeys"] == .array([.string("a"), .string("b")]) && eviction(["a"]).text.isEmpty)
        #expect(lanes.map(\.id) == ["fp16", "int8", "int4"] && lanes.filter { $0.isDefault }.map(\.id) == ["fp16"])
    }
}
