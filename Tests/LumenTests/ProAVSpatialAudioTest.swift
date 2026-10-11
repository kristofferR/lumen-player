import FFmpegKit
import Libavcodec
@testable import Lumen
#if canImport(SpatialAudioBridge)
import SpatialAudioBridge
#endif
import XCTest

class ProAVSpatialAudioTest: XCTestCase {
    private let apac = ProAVAudioSignaling(codecsAttribute: "apac.31.03", channels: "12", mediaPlaylistName: ProAVRemuxSession.audioPlaylistName)

    func testMasterPointsAtTheAPACRendition() {
        let video = ProAVVideoSignaling(codecTag: "dvh1", codecsAttribute: "dvh1.08.06", videoRange: "PQ", supplementalCodecs: nil, preferredDynamicRange: .dolbyVision)
        let master = ProAVPlaylist.master(mediaPlaylistName: "media.m3u8", video: video, audio: apac, bandwidth: 24_000_000, resolution: CGSize(width: 3840, height: 2160), frameRate: 23.976)
        XCTAssertTrue(master.contains("#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"main\",NAME=\"Original\",DEFAULT=YES,AUTOSELECT=YES,CHANNELS=\"12\",URI=\"audio.m3u8\"\n"))
        XCTAssertTrue(master.contains("CODECS=\"dvh1.08.06,apac.31.03\""))
        XCTAssertTrue(master.contains("AUDIO=\"main\""))
    }

    func testOnlyLosslessTrueHDAndDTSAreOffered() throws {
        #if canImport(SpatialAudioBridge)
        guard #available(macOS 26, iOS 26, tvOS 26, *) else {
            throw XCTSkip("SpatialAudioBridge requires macOS, iOS or tvOS 26")
        }
        func codec(_ codecID: AVCodecID, profile: Int32, sampleRate: Int32 = 48000) -> SpatialAudioCodec? {
            var codecpar = AVCodecParameters()
            codecpar.codec_id = codecID
            codecpar.profile = profile
            codecpar.sample_rate = sampleRate
            return ProAVSpatialAudioTranscoder.codec(codecpar: codecpar)
        }
        XCTAssertEqual(codec(AV_CODEC_ID_TRUEHD, profile: AV_PROFILE_TRUEHD_ATMOS), .trueHDAtmos)
        XCTAssertEqual(codec(AV_CODEC_ID_TRUEHD, profile: AV_PROFILE_UNKNOWN), .trueHDAtmos)
        for profile in [AV_PROFILE_DTS_HD_MA, AV_PROFILE_DTS_HD_MA_X, AV_PROFILE_DTS_HD_MA_X_IMAX] {
            XCTAssertEqual(codec(AV_CODEC_ID_DTS, profile: profile), .dtsX)
        }
        for profile in [AV_PROFILE_DTS, AV_PROFILE_DTS_HD_HRA, AV_PROFILE_DTS_EXPRESS, AV_PROFILE_UNKNOWN] {
            XCTAssertNil(codec(AV_CODEC_ID_DTS, profile: profile))
        }
        XCTAssertNil(codec(AV_CODEC_ID_TRUEHD, profile: AV_PROFILE_TRUEHD_ATMOS, sampleRate: 96000))
        XCTAssertNil(codec(AV_CODEC_ID_EAC3, profile: AV_PROFILE_EAC3_DDP_ATMOS))
        #else
        throw XCTSkip("SpatialAudioBridge is unavailable on this platform")
        #endif
    }

    func testReadyWaitsForTheAPACRendition() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = ProAVRemuxSession(configuration: .init(directory: directory))
        var readyCount = 0
        session.onReady = { _ in readyCount += 1 }
        let video = ProAVVideoSignaling(codecTag: "avc1", codecsAttribute: "avc1.640028", videoRange: "SDR", supplementalCodecs: nil, preferredDynamicRange: .sdr)
        XCTAssertTrue(session.begin(signaling: video, audioSignaling: apac, bandwidth: 12_000_000, resolution: CGSize(width: 1920, height: 1080), frameRate: 23.976))
        XCTAssertTrue(session.playsSpatialAudio)
        for start in [0.0, 2, 4] {
            session.closeSegment(nextStartTime: start)
        }
        XCTAssertEqual(readyCount, 0)
        session.writeAudioInitSegment(Data([0]))
        session.appendAudioSegment(Data([1]), duration: 3.2)
        XCTAssertEqual(readyCount, 1)
        session.finish(reachedEnd: true)
        let playlist = try String(contentsOf: directory.appendingPathComponent(ProAVRemuxSession.audioPlaylistName), encoding: .utf8)
        XCTAssertTrue(playlist.contains("#EXT-X-MAP:URI=\"audio-init.mp4\"\n#EXTINF:3.20000,\naudio0.m4s\n#EXT-X-ENDLIST\n"))
        // HLS requires the audio and video playlists of a variant to share one target duration.
        let media = try String(contentsOf: directory.appendingPathComponent(ProAVRemuxSession.mediaPlaylistName), encoding: .utf8)
        XCTAssertTrue(playlist.contains("#EXT-X-TARGETDURATION:4\n"))
        XCTAssertTrue(media.contains("#EXT-X-TARGETDURATION:4\n"))
    }

    func testEndingWithoutAPACFragmentsFallsBackToFLAC() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = ProAVRemuxSession(configuration: .init(directory: directory))
        let video = ProAVVideoSignaling(codecTag: "avc1", codecsAttribute: "avc1.640028", videoRange: "SDR", supplementalCodecs: nil, preferredDynamicRange: .sdr)
        XCTAssertTrue(session.begin(signaling: video, audioSignaling: apac, bandwidth: 12_000_000, resolution: CGSize(width: 1920, height: 1080), frameRate: 23.976))
        session.closeSegment(nextStartTime: 0)
        session.closeSegment(nextStartTime: 2)
        session.finish(reachedEnd: true)
        XCTAssertTrue(session.isFailed)
        XCTAssertTrue(session.spatialAudioFailed)
    }

    func testOnlySpatialAudioFailuresFallBackToFLAC() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let failed = ProAVRemuxSession(configuration: .init(directory: directory))
        failed.fail(NSError(description: "segment write failed"))
        failed.failSpatialAudio(NSError(description: "unsupported metadata"))
        XCTAssertTrue(failed.isFailed)
        XCTAssertFalse(failed.spatialAudioFailed)
        let rejected = ProAVRemuxSession(configuration: .init(directory: directory))
        rejected.failSpatialAudio(NSError(description: "unsupported metadata"))
        XCTAssertTrue(rejected.isFailed)
        XCTAssertTrue(rejected.spatialAudioFailed)
    }
}
