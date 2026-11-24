import Foundation
import GaeaProtocol
import MLXLongCatAvatar
import MLXToolKit
import Testing

@testable import GaeaPluginKit
@testable import LongCatAvatarPlugin

@Suite struct LongCatAvatarPluginTests {
    static let landscape = MediaFacts(imageWidth: 1920, imageHeight: 1080, soundtrackSeconds: 5.0)

    func ask(_ params: [String: JSONValue] = [:], inputs: [String: [URL]] = [:], seed: UInt64? = 7) -> Ask {
        Ask(prompt: "a presenter in a studio", params: params, inputs: inputs, seed: seed)
    }

    func plan(_ params: [String: JSONValue] = [:], media: MediaFacts = landscape, inputs: [String: [URL]] = [:]) throws -> Call {
        try generateCall(ask(params, inputs: inputs), media: media, firstFrame: Data([1]), soundtrack: Data([2]))
    }

    func refusal(_ code: String, param: String, _ body: () throws -> Call) {
        do {
            _ = try body()
            Issue.record("expected a \(code) refusal")
        } catch let error as GPPError {
            #expect(error.detail?["mes_code"]?.stringValue == code)
            #expect(error.detail?["param"]?.stringValue == param)
        } catch {
            Issue.record("\(error)")
        }
    }

    @Test func aBareRequestFollowsTheSoundtrackAndTheFirstFrame() throws {
        let call = try plan()
        #expect(call.request.numFrames == 125 && call.request.fps == 25)
        #expect(call.request.width == 832 && call.request.height == 480 && call.request.seed == 7)
        #expect(call.request.prompt == "a presenter in a studio")
        #expect(call.request.initImage?.data == Data([1]) && call.request.initAudio?.data == Data([2]))
        #expect(call.request.negativePrompt == nil && call.request.steps == nil && call.request.guidanceScale == nil)
        #expect(call.request.includeAudio == nil)
        #expect(call.warnings.isEmpty)
        #expect(call.effective["frames"] == 125 && call.effective["fps"]?.doubleValue == 25 && call.effective["seed"] == 7)
        #expect(call.effective["duration_s"]?.doubleValue == 5)
        #expect(call.effective["size"] == ["width": 832, "height": 480])
    }

    @Test func theSizeIsTheBucketClosestToTheFirstFrame() throws {
        func size(_ w: Int, _ h: Int) throws -> [Int] {
            let call = try plan(media: MediaFacts(imageWidth: w, imageHeight: h, soundtrackSeconds: 2))
            return [call.request.width!, call.request.height!]
        }
        #expect(try size(1920, 1080) == [832, 480])
        #expect(try size(1080, 1920) == [480, 832])
        #expect(try size(1024, 1024) == [640, 608])
        #expect(try size(2223, 1431) == [768, 512])
        #expect(try size(4000, 500) == [1216, 320])
        // Every bucket is a size the package accepts.
        for (w, h) in [(1920, 1080), (1080, 1920), (1024, 1024), (4000, 500), (500, 4000)] {
            let s = try size(w, h)
            #expect(tier.contains(width: s[0], height: s[1]))
        }
    }

    @Test func anAskedSizeOrAspectPicksItsBucket() throws {
        // A bucket asked for by name: taken as is, no warning.
        let exact = try plan(["size": ["width": 480, "height": 832]])
        #expect(exact.request.width == 480 && exact.request.height == 832 && exact.warnings.isEmpty)
        // Not a bucket: the closest shape, warned.
        let snapped = try plan(["size": ["width": 1280, "height": 720]])
        #expect(snapped.request.width == 832 && snapped.request.height == 480)
        #expect(snapped.warnings.map(\.code) == ["size_snapped"])
        // An aspect names a shape, not a size: no warning.
        let portrait = try plan(["aspect": "9:16", "resolution": 720])
        #expect(portrait.request.width == 480 && portrait.request.height == 832 && portrait.warnings.isEmpty)
        let square = try plan(["aspect": "1:1"])
        #expect(square.request.width == 640 && square.request.height == 608)
    }

    @Test func durationOverridesTheSoundtrackAndFitsIt() throws {
        let shorter = try plan(["duration_s": 2])
        #expect(shorter.request.numFrames == 50)
        #expect(shorter.warnings.map(\.code) == ["soundtrack_fitted"])
        #expect(shorter.warnings[0].message.contains("cut"))
        let longer = try plan(["duration_s": 8])
        #expect(longer.request.numFrames == 200)
        #expect(longer.warnings[0].message.contains("padded with silence"))
        // The same length: nothing to fit.
        #expect(try plan(["duration_s": 5]).warnings.isEmpty)
        // No frame grid: any whole number of frames.
        #expect(try plan(["duration_s": 3.76]).request.numFrames == 94)
        #expect(try plan(["duration_s": 1]).request.numFrames == 25)
    }

    @Test func lengthLimits() throws {
        refusal("out_of_limits", param: "duration_s") { try plan(["duration_s": 0.5]) }
        refusal("out_of_limits", param: "duration_s") { try plan(["duration_s": 61]) }
        #expect(try plan(["duration_s": 60]).request.numFrames == 1500)
        // A soundtrack under a second can't set the length on its own.
        let short = MediaFacts(imageWidth: 100, imageHeight: 100, soundtrackSeconds: 0.4)
        refusal("out_of_limits", param: "soundtrack") { try plan(media: short) }
        #expect(try plan(["duration_s": 1], media: short).request.numFrames == 25)
        // A soundtrack over the limit is cut to it, with the warning.
        let long = try plan(media: MediaFacts(imageWidth: 100, imageHeight: 100, soundtrackSeconds: 90))
        #expect(long.request.numFrames == 1500 && long.warnings.map(\.code) == ["soundtrack_fitted"])
    }

    @Test func whatTheModelDoesNotTakeIsWarnedOrRefused() throws {
        #expect(try plan(["fps": 30]).warnings.map(\.code) == ["fps_adjusted"])
        #expect(try plan(["fps": 30]).request.fps == 25)
        #expect(try plan(["fps": 25]).warnings.isEmpty)
        #expect(try plan(["negative_prompt": "blurry"]).warnings.map(\.code) == ["negative_prompt_ignored"])
        #expect(try plan(["negative_prompt": "blurry"]).request.negativePrompt == nil)
        let file = URL(fileURLWithPath: "/tmp/x.png")
        for input in ["last_frame", "keyframes", "references", "control"] {
            refusal("unsupported_parameter", param: input) { try plan(inputs: [input: [file]]) }
        }
    }

    @Test func audioFalseAsksForASilentClip() throws {
        #expect(try plan(["audio": false]).request.includeAudio == false)
        #expect(try plan(["audio": true]).request.includeAudio == true)
    }

    @Test func aSeedIsChosenWhenNoneIsGiven() throws {
        let call = try generateCall(ask(seed: nil), media: Self.landscape, firstFrame: Data([1]), soundtrack: Data([2]))
        #expect(call.request.seed != nil)
        #expect(call.effective["seed"]?.doubleValue == Double(call.request.seed!))
    }

    @Test func bothInputsAreRequired() {
        let image = URL(fileURLWithPath: "/tmp/absent.png"), audio = URL(fileURLWithPath: "/tmp/absent.wav")
        for (inputs, param) in [([String: [URL]](), "first_frame"), (["first_frame": [image]], "soundtrack"),
                                (["soundtrack": [audio]], "first_frame")] {
            do {
                _ = try call(ask(inputs: inputs))
                Issue.record("expected a refusal")
            } catch let error as GPPError {
                #expect(error.detail?["param"]?.stringValue == param)
            } catch { Issue.record("\(error)") }
        }
    }

    @Test func everyRequestThePlanBuildsPassesThePackagesOwnCheck() throws {
        for params: [String: JSONValue] in [[:], ["duration_s": 2], ["size": ["width": 480, "height": 832]], ["aspect": "1:1"],
                                             ["audio": false], ["fps": 24], ["negative_prompt": "x"]] {
            let call = try plan(params)
            _ = try LongCatAvatarPackage.checked(call.request)
            #expect(tier.contains(width: call.request.width!, height: call.request.height!))
            #expect((minFrames...maxFrames).contains(call.request.numFrames!))
        }
    }

    @Test func theLanesAreTheThreePrecisions() {
        #expect(Lane.allCases.map(\.rawValue) == ["bf16", "int8", "int4"])
        #expect(configuration(.bf16).repo == "mlx-community/LongCat-Video-Avatar-1.6-bf16")
        #expect(configuration(.int8).repo == "mlx-community/LongCat-Video-Avatar-1.6-q8")
        #expect(configuration(.int4).repo == "mlx-community/LongCat-Video-Avatar-1.6-q4")
        #expect(Lane.allCases.allSatisfy { configuration($0).maximumFrames == maxFrames })
        #expect(Lane.allCases.filter { lane($0).isDefault }.map(\.rawValue) == ["bf16"])
    }

    @Test func theManifestOffersTheModelWithItsLimits() throws {
        let manifest = try longCatAvatarPlugin.manifest()
        #expect(manifest.id == "com.xocialize.gaea.longcat-avatar")
        #expect(manifest.offers.count == 1 && manifest.offers[0].operation == "video.generate")
        let model = manifest.offers[0].model
        #expect(model["id"] == "longcat-avatar-1.6")
        #expect(model["supports"]?["first_frame"] == true && model["supports"]?["soundtrack"] == true)
        #expect(model["supports"]?["audio"] == true && model["supports"]?["negative_prompt"] == false)
        #expect(model["limits"]?["max_frames"] == 1500 && model["limits"]?["max_duration_s"]?.doubleValue == 60)
        #expect(model["license"]?["spdx"] == "MIT" && model["license"]?["commercial_use"] == true)
    }
}
