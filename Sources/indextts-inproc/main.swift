import Foundation
import GaeaProtocol
import IndexTTSPlugin
import MLXIndexTTS2TTS
import MLXServeCore
import MLXToolKit

// The in-process reference for the plugin: IndexTTS 2.5 loaded by MLXServeEngine in this process, with the lane
// configuration, the requests and the seeding the worker uses (IndexTTSPlugin). The WAV is written to --out, and one JSON
// line of timings is printed. Not part of the plugin bundle.
//
//   indextts-inproc --ref <wav> [--text <text> | --text-file <path>] [--language en] [--emotion <label>]
//                   [--intensity 0.6] [--vector 0,1,0,0,0,0,0,0] [--target-duration 4.0] [--speed 1.2] [--seed 42]
//                   [--lane fp16 | int8 | int4] [--models-root <dir>] [--out <wav>]

var args = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    defer { args.removeSubrange(i...(i + 1)) }
    return args[i + 1]
}
func seconds(since start: ContinuousClock.Instant) -> Double {
    let d = ContinuousClock.now - start
    return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
}

let laneID = option("--lane") ?? "fp16"
let seed = UInt64(option("--seed") ?? "") ?? 42
let modelsRoot = URL(fileURLWithPath: option("--models-root")
                     ?? NSHomeDirectory() + "/Library/Application Support/MLXEngine/Models", isDirectory: true)
guard let lane = lanes.first(where: { $0.id == laneID }) else { fatalError("no lane \(laneID)") }
guard let ref = option("--ref") else { fatalError("indextts-inproc needs --ref <wav>") }
let text = try option("--text-file").map { try String(contentsOfFile: $0, encoding: .utf8) }
    ?? option("--text") ?? "Gaea speaks. This sentence came from a signed plugin, over its own protocol."

var emotionFields: [String: JSONValue] = [:]
if let label = option("--emotion") { emotionFields["label"] = .string(label) }
if let intensity = option("--intensity").flatMap(Double.init) { emotionFields["intensity"] = .double(intensity) }
let emotion: JSONValue? = emotionFields.isEmpty ? nil : .object(emotionFields)
let vector: JSONValue? = option("--vector").map { .array($0.split(separator: ",").compactMap { Double($0) }.map { .double($0) }) }

// The budget Gaea sends a worker on a large Mac.
let engine = MLXServeEngine(workerBudget: WorkerBudget(ceilingBytes: 64_000_000_000, wiresWeights: true))
await engine.useModelStore(ModelStore(root: modelsRoot))
let id = PackageID(modelID)
_ = try await engine.register(IndexTTS2Package.registration, configuration: lane.configuration, id: id)
var clock = ContinuousClock.now
_ = try await engine.prepare(.tts, package: id)
var result: [String: Any] = ["model": modelID, "lane": laneID, "seed": seed, "prepare_s": seconds(since: clock)]
let run: (TTSRequest) async throws -> any CapabilityResponse = { try await engine.run($0, package: id) }

clock = ContinuousClock.now
// A job of its own, keyed by the job as the worker keys a reference that isn't an asset.
let plan = try speakPlan(text: text, reference: try Data(contentsOf: URL(fileURLWithPath: ref)), language: option("--language"),
                         emotion: emotion, vector: vector, targetDuration: option("--target-duration").flatMap(Double.init),
                         speed: option("--speed").flatMap(Double.init), asset: nil, job: "inproc", seed: seed)
let pcm = try await speak(plan.pieces) { i, words in try await draw(request(plan, piece: i, words: words), seed: plan.seed, run: run) }
_ = try? await run(eviction([plan.cacheKey]))
if let out = option("--out") { try wav16(pcm).write(to: URL(fileURLWithPath: out)) }
result["language"] = plan.language
result["audio_s"] = Double(pcm.count / 2) / Double(sampleRate)
result["warnings"] = (plan.warnings + [durationWarning(pcm, target: plan.effective["target_duration_s"]?.doubleValue)].compactMap { $0 }).map(\.code)
result["run_s"] = seconds(since: clock)
var usage = rusage()
getrusage(RUSAGE_SELF, &usage)
result["max_rss_gb"] = Double(usage.ru_maxrss) / 1e9
print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
