import AVFoundation
import Foundation
import GaeaPluginKit
import GaeaProtocol
import ImageIO
import LongCatVideoAvatar
import MLXLongCatAvatar
import MLXToolKit

// gaea-plugin-longcat-avatar: Meituan's LongCat-Video-Avatar 1.6 (MIT) on MES Video 0.1's video.generate, on
// longcat-avatar-mlx-swift through MLXServeEngine.
//
// - An audio-driven talking avatar: `first_frame` is the person, `soundtrack` is clean speech, `prompt` describes
//   the scene. The clip shows the person speaking the soundtrack, at 25 fps, with the soundtrack as its audio. Both
//   inputs are required; a request without either is refused.
// - Length: the soundtrack's, unless `duration_s` says otherwise. Any whole number of frames from one second up: the
//   model works in segments (93 frames, then 80 more per continuation) and the clip is cut to length, so there is no
//   frame grid to snap to. A longer clip takes proportionally longer.
// - Size: the model makes a fixed table of sizes (upstream's 480p buckets, about 400,000 pixels each). Without `size`
//   or `aspect` the clip takes the bucket closest to the first frame's shape, and the frame is scaled to cover it and
//   centre-cropped. A `size` or `aspect` picks the closest bucket, warned as `size_snapped` when it isn't one.
// - Lanes: the DiT in bf16, 8-bit or 4-bit; everything else is bf16 in each.
// - Gaea marks every output AI-generated (Video §1.9).

public let modelID = "longcat-avatar-1.6", modelTitle = "LongCat-Video-Avatar 1.6"
/// The model's frame rate: the rate its motion and lip-sync were trained at.
public let nativeFPS = 25.0
/// The shortest clip: one second.
public let minFrames = LongCatAvatarPipeline.minimumClipFrames
/// The longest clip this plugin offers: one minute.
public let maxFrames = 1500
/// The size tier offered: upstream's 480p bucket table.
public let tier = AvatarResolution.p480

/// The lanes: one per DiT precision.
public enum Lane: String, CaseIterable, Sendable {
    case bf16, int8, int4

    public var quant: Quant {
        switch self {
        case .bf16: .bf16
        case .int8: .int8
        case .int4: .int4
        }
    }
}

/// A lane's package configuration. longcat-avatar-inproc builds the same one.
public func configuration(_ lane: Lane) -> LongCatAvatarConfiguration {
    LongCatAvatarConfiguration(quant: lane.quant, maximumFrames: maxFrames)
}

// MARK: - What a job asks

/// One job's request as the plan reads it: built from a GPP run by the worker, and from the command line by
/// longcat-avatar-inproc, so both send the package the same request.
public struct Ask: Sendable {
    public var prompt: String
    public var params: [String: JSONValue]
    public var inputs: [String: [URL]]
    public var seed: UInt64?

    public init(prompt: String, params: [String: JSONValue] = [:], inputs: [String: [URL]] = [:], seed: UInt64? = nil) {
        self.prompt = prompt; self.params = params; self.inputs = inputs; self.seed = seed
    }

    public init(_ job: Job) throws {
        guard job.operation == "video.generate" else {
            throw GPPError(.unsupportedOperation, "LongCat-Video-Avatar only generates (video.generate), not \(job.operation).")
        }
        guard let prompt = try job.text("prompt"), !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GPPError(.invalidRequest, "video.generate needs a prompt.", detail: ["param": "prompt"])
        }
        self.init(prompt: prompt, params: job.params, inputs: job.inputs, seed: job.seed)
    }

    func number(_ name: String) -> Double? { params[name]?.doubleValue }
    func input(_ name: String) -> URL? { inputs[name]?.first }
}

/// One engine call and what it will report.
public struct Call: Sendable {
    public var request: T2VRequest
    public var effective: [String: JSONValue]
    public var warnings: [Warning]
}

/// What the plan needs to know about the two media inputs. Read from the files by `MediaFacts.read`; given directly
/// by tests.
public struct MediaFacts: Sendable, Equatable {
    public var imageWidth: Int, imageHeight: Int
    public var soundtrackSeconds: Double

    public init(imageWidth: Int, imageHeight: Int, soundtrackSeconds: Double) {
        self.imageWidth = imageWidth; self.imageHeight = imageHeight; self.soundtrackSeconds = soundtrackSeconds
    }

    public static func read(firstFrame: URL, soundtrack: URL) throws -> MediaFacts {
        guard let source = CGImageSourceCreateWithURL(firstFrame as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              var width = properties[kCGImagePropertyPixelWidth] as? Int,
              var height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0
        else { throw refusal("input_invalid", "\(firstFrame.lastPathComponent) isn't an image.", param: "first_frame") }
        // EXIF orientations 5…8 turn the picture a quarter: the package decodes it upright.
        if let orientation = properties[kCGImagePropertyOrientation] as? Int, (5...8).contains(orientation) {
            swap(&width, &height)
        }
        guard let file = try? AVAudioFile(forReading: soundtrack), file.length > 0 else {
            throw refusal("input_invalid", "\(soundtrack.lastPathComponent) isn't audio the plugin can read.", param: "soundtrack")
        }
        return MediaFacts(imageWidth: width, imageHeight: height,
                          soundtrackSeconds: Double(file.length) / file.processingFormat.sampleRate)
    }
}

/// A refusal of what the request asks, with the MES code Gaea answers with (GPP-1 §3.5).
func refusal(_ code: String, _ message: String, param: String) -> GPPError {
    GPPError(.invalidRequest, message, detail: ["mes_code": .string(code), "param": .string(param)])
}

func seconds(_ frames: Int) -> Double { Double(frames) / nativeFPS }

/// The size a job asks for: `size`, or `aspect` (at any `resolution`: the model has one size tier), or nil.
func requestedSize(_ ask: Ask) -> (width: Int, height: Int)? {
    if let size = ask.params["size"]?.objectValue, let w = size["width"]?.doubleValue, let h = size["height"]?.doubleValue,
       w > 0, h > 0 {
        return (Int(w), Int(h))
    }
    guard let aspect = ask.params["aspect"]?.stringValue else { return nil }
    let parts = aspect.split(separator: ":").compactMap { Double($0) }
    guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { return nil }
    // Only the shape matters: the bucket fixes the pixel count.
    return (Int((parts[0] * 1000).rounded()), Int((parts[1] * 1000).rounded()))
}

/// `video.generate` (Video §3.1): a clip of the person in `first_frame` speaking `soundtrack`, at 25 fps, the
/// soundtrack's length unless `duration_s` says otherwise, in the size bucket closest to the first frame (or to the
/// size asked for), each adjustment warned, and a seed chosen when none was asked for.
public func generateCall(_ ask: Ask, media: MediaFacts, firstFrame: Data, soundtrack: Data) throws -> Call {
    var warnings: [Warning] = []

    // Gaea refuses these from the offer's `supports`; the plugin refuses them too, legibly.
    for input in ["last_frame", "keyframes", "references", "control"] where !(ask.inputs[input] ?? []).isEmpty {
        throw refusal("unsupported_parameter", "LongCat-Video-Avatar takes a first frame and a soundtrack; it takes no \(input).",
                      param: input)
    }

    // The size: the bucket closest to what was asked for, or to the first frame.
    let asked = requestedSize(ask)
    let shape = asked ?? (media.imageWidth, media.imageHeight)
    let (height, width) = tier.size(imageWidth: shape.width, imageHeight: shape.height)
    if let asked, ask.params["size"] != nil, (asked.width, asked.height) != (width, height) {
        warnings.append(Warning(code: "size_snapped", message: "\(asked.width)×\(asked.height) is \(width)×\(height), the closest "
                                + "of the model's sizes.", param: "size"))
    }

    // The rate: the model's motion and lip-sync are 25 fps.
    if let fps = ask.number("fps"), abs(fps - nativeFPS) > 0.001 {
        warnings.append(Warning(code: "fps_adjusted", message: String(format: "LongCat-Video-Avatar's motion is %g fps; the clip "
                                                                       + "is made at %g fps, not %g.", nativeFPS, nativeFPS, fps),
                                param: "fps"))
    }

    // The frames: duration × 25, or the soundtrack's length, within one second and the plugin's limit.
    var frames: Int
    if let duration = ask.number("duration_s") {
        frames = Int((duration * nativeFPS).rounded())
        guard frames >= minFrames else {
            throw refusal("out_of_limits", String(format: "%g s is %d frames; the shortest clip is %d (%g s).",
                                                  duration, frames, minFrames, seconds(minFrames)), param: "duration_s")
        }
        guard frames <= maxFrames else {
            throw refusal("out_of_limits", String(format: "%g s is %d frames; the longest clip is %d (%g s).",
                                                  duration, frames, maxFrames, seconds(maxFrames)), param: "duration_s")
        }
    } else {
        frames = Int(media.soundtrackSeconds * nativeFPS)
        guard frames >= minFrames else {
            throw refusal("out_of_limits", String(format: "The soundtrack is %.2f s; the shortest clip is %g s. Give a "
                                                  + "longer soundtrack, or a duration_s (the rest is silence).",
                                                  media.soundtrackSeconds, seconds(minFrames)), param: "soundtrack")
        }
        frames = min(frames, maxFrames)
    }
    if abs(media.soundtrackSeconds - seconds(frames)) > 0.5 / nativeFPS {
        warnings.append(Warning(code: "soundtrack_fitted", message: String(
            format: "The %.2f s soundtrack is %@ to the %.2f s clip.", media.soundtrackSeconds,
            media.soundtrackSeconds > seconds(frames) ? "cut" : "padded with silence", seconds(frames)), param: "soundtrack"))
    }

    if let negative = ask.params["negative_prompt"]?.stringValue, !negative.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        warnings.append(Warning(code: "negative_prompt_ignored", message: "LongCat-Video-Avatar is distilled without "
                                + "classifier-free guidance, so it takes no negative prompt.", param: "negative_prompt"))
    }

    let seed = ask.seed ?? UInt64.random(in: 0 ..< (1 << 32))
    let request = T2VRequest(
        prompt: ask.prompt,
        initImage: Image(format: .png, data: firstFrame),
        initAudio: Audio(format: .wav, data: soundtrack),
        includeAudio: ask.params["audio"]?.boolValue,
        numFrames: frames, fps: nativeFPS, width: width, height: height, seed: seed)
    let effective: [String: JSONValue] = [
        "seed": .int(Int64(seed)), "frames": .int(Int64(frames)), "fps": .double(nativeFPS),
        "duration_s": .double(seconds(frames)), "size": ["width": .int(Int64(width)), "height": .int(Int64(height))],
    ]
    return Call(request: request, effective: effective, warnings: warnings)
}

/// An image input as PNG bytes, upright (it may arrive as JPEG, HEIC or WebP, with an EXIF orientation).
func png(_ url: URL) throws -> Data {
    let data: Data
    do { data = try Data(contentsOf: url) } catch {
        throw refusal("input_invalid", "\(url.lastPathComponent) can't be read.", param: "first_frame")
    }
    guard let image = try? ImageInput.decode(data) else {
        throw refusal("input_invalid", "\(url.lastPathComponent) isn't an image.", param: "first_frame")
    }
    let out = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil) else {
        throw GPPError(.internal, "Can't write PNG.")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw GPPError(.internal, "Can't write PNG.") }
    return out as Data
}

/// The call for a job: reads the two inputs and plans with what they are.
public func call(_ ask: Ask) throws -> Call {
    guard let firstFrame = ask.input("first_frame") else {
        throw GPPError(.invalidRequest, "LongCat-Video-Avatar needs a first_frame: the person who speaks.",
                       detail: ["param": "first_frame"])
    }
    guard let soundtrack = ask.input("soundtrack") else {
        throw GPPError(.invalidRequest, "LongCat-Video-Avatar needs a soundtrack: the speech that drives the clip.",
                       detail: ["param": "soundtrack"])
    }
    let media = try MediaFacts.read(firstFrame: firstFrame, soundtrack: soundtrack)
    let audio: Data
    do { audio = try Data(contentsOf: soundtrack) } catch {
        throw refusal("input_invalid", "\(soundtrack.lastPathComponent) can't be read.", param: "soundtrack")
    }
    return try generateCall(ask, media: media, firstFrame: try png(firstFrame), soundtrack: audio)
}

let generate = EngineOperation("video.generate") { job, session in
    let call = try call(try Ask(job))
    let response = try await session.run(call.request)
    guard let video = (response as? T2VResponse)?.video else { throw GPPError(.modelError, "LongCat-Video-Avatar returned no video.") }
    let url = session.outputDir.appending(path: "video-0.mp4")
    try video.data.write(to: url)
    return RunResult(outputs: [.file("video", url, mediaType: "video/mp4")], effective: call.effective, warnings: call.warnings)
}

// MARK: - The plugin

public func lane(_ lane: Lane) -> LaneDefinition {
    LaneDefinition(id: lane.rawValue, default: lane == .bf16, configuration: configuration(lane))
}

public let license: JSONValue = [
    "spdx": "MIT", "commercial_use": true,
    "terms_url": "https://huggingface.co/meituan-longcat/LongCat-Video-Avatar-1.6",
]

/// The smallest and largest sides in the 480p bucket table.
let sides: (minWidth: Int, maxWidth: Int, minHeight: Int, maxHeight: Int) = (320, 1280, 320, 1280)

public let offer = PluginManifest.Offer(
    operation: "video.generate", profile: "video",
    model: [
        "id": .string(modelID), "title": .string(modelTitle), "license": license,
        "memory_class": "xlarge", "speed_class": "slow", "quality_tiers": ["standard", "best"],
        "notes": .string("Audio-driven talking avatar: the person in the first frame speaks the soundtrack. Both are "
                         + "required. \(Int(nativeFPS)) fps, one second to \(Int(seconds(maxFrames))) s, in the size closest to the "
                         + "first frame's shape (832×480 for 16:9, 480×832 for 9:16, 640×608 near square). Give clean "
                         + "speech: no vocal separation is done."),
        "supports": [
            "first_frame": true, "last_frame": false, "keyframes": false, "soundtrack": true, "references": false,
            "audio": true, "sample_rate": 48000, "channels": 1, "negative_prompt": false, "seed": true,
            "deterministic": false, "frame_rates": [.double(nativeFPS)],
        ],
        "limits": [
            "min_width": .int(Int64(sides.minWidth)), "max_width": .int(Int64(sides.maxWidth)),
            "min_height": .int(Int64(sides.minHeight)), "max_height": .int(Int64(sides.maxHeight)),
            "max_frames": .int(Int64(maxFrames)), "max_duration_s": .double(seconds(maxFrames)),
            "max_soundtrack_s": .double(seconds(maxFrames)), "max_fps": .double(nativeFPS),
        ],
    ])

func model() -> ModelDefinition {
    .engine(LongCatAvatarPackage.self, id: modelID, title: modelTitle, lanes: Lane.allCases.map(lane), operations: [generate])
}

public let longCatAvatarPlugin = GaeaPluginDefinition(
    id: "com.xocialize.gaea.longcat-avatar", version: "0.1.1", minGaea: "1.9.0", team: "CFZS6RXUCP",
    repo: "https://github.com/xocialize-code/gaea-plugin-longcat-avatar", title: "LongCat-Video-Avatar",
    summary: "LongCat-Video-Avatar 1.6 (Meituan, MIT): an audio-driven talking avatar. A first frame and a speech "
        + "soundtrack make a lip-synced clip of any length up to a minute, at 25 fps.",
    license: "Apache-2.0", executable: "gaea-longcat-avatar-worker",
    models: [model()], offers: [offer])
