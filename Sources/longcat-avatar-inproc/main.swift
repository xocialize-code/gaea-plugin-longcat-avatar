import Foundation
import GaeaProtocol
import LongCatAvatarPlugin
import MLXLongCatAvatar
import MLXServeCore
import MLXToolKit

// The in-process reference for the plugin: LongCat-Video-Avatar loaded by MLXServeEngine in this process, with the
// lane configuration the worker uses and the request it would build (LongCatAvatarPlugin.call, from the same MES
// params and inputs). The clip is written to --out, and one JSON line of timings is printed. Not part of the plugin
// bundle.
//
//   longcat-avatar-inproc --first-frame <image> --soundtrack <audio> [--prompt <text | @file>] [--duration <seconds>]
//                         [--lane bf16|int8|int4] [--seed 7] [--models-root <dir>] [--out <mp4>] [--runs 1]

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
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}
func text(_ value: String) -> String {
    guard value.hasPrefix("@") else { return value }
    guard let s = try? String(contentsOfFile: String(value.dropFirst()), encoding: .utf8) else { fail("can't read \(value)") }
    return s.trimmingCharacters(in: .whitespacesAndNewlines)
}

let started = ContinuousClock.now
guard let firstFrame = option("--first-frame"), let soundtrack = option("--soundtrack") else {
    fail("usage: longcat-avatar-inproc --first-frame <image> --soundtrack <audio> [--prompt …] [--duration s] [--lane bf16]")
}
let prompt = text(option("--prompt") ?? "A person speaks to the camera in a softly lit room")
let duration = option("--duration").flatMap(Double.init)
guard let lane = Lane(rawValue: option("--lane") ?? "bf16") else { fail("--lane is bf16, int8 or int4") }
let seed = UInt64(option("--seed") ?? "") ?? 7
let outPath = option("--out")
let runs = Int(option("--runs") ?? "") ?? 1
let modelsRoot = URL(fileURLWithPath: option("--models-root")
                     ?? NSHomeDirectory() + "/Library/Application Support/MLXEngine/Models", isDirectory: true)

var params: [String: JSONValue] = [:]
if let duration { params["duration_s"] = .double(duration) }
// The worker's request, built by the same function.
let planned = try LongCatAvatarPlugin.call(Ask(prompt: prompt, params: params,
                        inputs: ["first_frame": [URL(fileURLWithPath: firstFrame)],
                                 "soundtrack": [URL(fileURLWithPath: soundtrack)]],
                        seed: seed))
var result: [String: Any] = ["model": modelID, "lane": lane.rawValue, "seed": seed,
                             "frames": planned.request.numFrames ?? -1,
                             "size": "\(planned.request.width ?? 0)x\(planned.request.height ?? 0)",
                             "warnings": planned.warnings.map(\.code)]

// The budget Gaea sends a worker on a large Mac (wiresWeights off, the automatic pool cap).
let engine = MLXServeEngine(workerBudget: WorkerBudget(ceilingBytes: 96_000_000_000, wiresWeights: false))
await engine.useModelStore(ModelStore(root: modelsRoot))
let id = PackageID(modelID)
_ = try await engine.register(LongCatAvatarPackage.registration, configuration: configuration(lane), id: id)

var clock = ContinuousClock.now
_ = try await engine.prepare(.textToVideo, package: id)
result["prepare_s"] = seconds(since: clock)

for run in 1...max(1, runs) {
    clock = ContinuousClock.now
    let response = try await engine.run(planned.request, package: id)
    result["run\(run)_s"] = seconds(since: clock)
    guard let video = (response as? T2VResponse)?.video else { fail("no video") }
    if run == 1, let outPath { try video.data.write(to: URL(fileURLWithPath: outPath)) }
}
result["total_s"] = seconds(since: started)

let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
print(String(decoding: data, as: UTF8.self))
