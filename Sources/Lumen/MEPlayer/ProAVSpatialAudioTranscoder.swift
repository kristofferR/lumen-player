import CoreMedia
import Foundation
import Libavcodec
import Libavformat
#if canImport(SpatialAudioBridge)
import SpatialAudioBridge
#endif

/// Converts a TrueHD Atmos or DTS:X track to APAC, which the remux serves as a separate audio
/// rendition instead of the FLAC transcode. A track without Atmos or DTS:X fails the session as
/// decoding starts, and the player then plays it through the FLAC transcode.
///
/// The read thread hands packets over and blocks while the conversion is behind, so the remux runs at
/// its pace. Fragments are placed on the muxer's timeline once `begin(origin:videoStart:)` says where
/// the video landed; packets that arrive before then are held.
final class ProAVSpatialAudioTranscoder: @unchecked Sendable {
    private enum Input {
        case timeline(origin: CMTime, videoStart: CMTime)
        case packet(Data, time: CMTime?)
    }

    let streamIndex: Int
    let signaling: ProAVAudioSignaling
    private let timebase: Timebase
    private let queue: AsyncStream<Input>.Continuation
    private let capacity = DispatchSemaphore(value: 64)
    private let completion = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var cancelled = false
    private(set) var hasTimeline = false

    /// Returns nil below tvOS, iOS and macOS 26 and for any track other than 48 kHz TrueHD or DTS-HD
    /// Master Audio, which keep the FLAC path.
    init?(stream: UnsafeMutablePointer<AVStream>, session: ProAVRemuxSession) {
        #if canImport(SpatialAudioBridge)
        guard #available(macOS 26, iOS 26, tvOS 26, *),
              let codecpar = stream.pointee.codecpar,
              let codec = Self.codec(codecpar: codecpar.pointee)
        else {
            return nil
        }
        // The offline profile would hold the first fragment back for about 20 s of audio.
        let configuration = APACConfiguration(liveEncoding: true)
        guard let priming = try? configuration.encoderPrimingDuration() else {
            return nil
        }
        streamIndex = Int(stream.pointee.index)
        timebase = Timebase(stream.pointee.time_base)
        signaling = ProAVAudioSignaling(codecsAttribute: configuration.layout.apacCodecString, channels: "\(configuration.layout.channelCount)", mediaPlaylistName: ProAVRemuxSession.audioPlaylistName)
        let (inputs, queue) = AsyncStream.makeStream(of: Input.self)
        self.queue = queue
        Task.detached { [self] in
            await convert(inputs, codec: codec, configuration: configuration, priming: priming, session: session)
        }
        #else
        return nil
        #endif
    }

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    /// Places the audio on the muxer's timeline, which starts at `origin`, the first video decode
    /// time, and starts it with the first video frame at `videoStart`.
    func begin(origin: CMTime, videoStart: CMTime) {
        hasTimeline = true
        capacity.wait()
        queue.yield(.timeline(origin: origin, videoStart: videoStart))
    }

    func append(packet: UnsafeMutablePointer<AVPacket>) {
        guard let data = packet.pointee.data, packet.pointee.size > 0 else { return }
        let timestamp = packet.pointee.pts == Int64.min ? packet.pointee.dts : packet.pointee.pts
        let time = timestamp == Int64.min ? nil : timebase.cmtime(for: timestamp)
        capacity.wait()
        queue.yield(.packet(Data(bytes: data, count: Int(packet.pointee.size)), time: time))
    }

    /// Converts the rest and waits until the last fragment reached the session.
    func finish() {
        queue.finish()
        completion.wait()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
        queue.finish()
    }

    #if canImport(SpatialAudioBridge)
    @available(macOS 26, iOS 26, tvOS 26, *)
    static func codec(codecpar: AVCodecParameters) -> SpatialAudioCodec? {
        guard codecpar.sample_rate == 48000 else {
            return nil
        }
        // FFmpeg reports some DTS:X presentations as plain DTS-HD MA, so every lossless track is
        // offered and the library tells them apart once it decodes.
        switch codecpar.codec_id {
        case AV_CODEC_ID_TRUEHD:
            return .trueHDAtmos
        case AV_CODEC_ID_DTS where [AV_PROFILE_DTS_HD_MA, AV_PROFILE_DTS_HD_MA_X, AV_PROFILE_DTS_HD_MA_X_IMAX].contains(codecpar.profile):
            return .dtsX
        default:
            return nil
        }
    }

    @available(macOS 26, iOS 26, tvOS 26, *)
    private func convert(_ inputs: AsyncStream<Input>, codec: SpatialAudioCodec, configuration: APACConfiguration, priming: CMTime, session: ProAVRemuxSession) async {
        var transcoder: SpatialAudioTranscoder?
        var timeline: (origin: CMTime, start: CMTime)?
        var held = [(data: Data, time: CMTime?)]()
        var failed = false
        // Any library error ends the session at once, so the player restarts on the FLAC path.
        func fail(_ error: Error) {
            failed = true
            guard !isCancelled else { return }
            session.failSpatialAudio(NSError(description: "ProAV spatial audio failed: \(error)"))
        }
        func append(_ data: Data, time: CMTime?) async throws {
            guard let timeline else {
                held.append((data, time))
                return
            }
            if transcoder == nil {
                // Decoding starts at a TrueHD major sync or a DTS core sync; earlier audio is discarded
                // and a later start is padded with silence, so the audio begins with the video.
                guard let time, Self.isSyncPoint(data, codec: codec) else { return }
                var settings = configuration
                settings.startTime = timeline.start
                settings.inputStartTime = time - timeline.origin
                transcoder = try SpatialAudioTranscoder(codec: codec, destination: .segments { segment in
                    switch segment.kind {
                    case .initialization:
                        session.writeAudioInitSegment(segment.data)
                    case .media:
                        session.appendAudioSegment(segment.data, duration: segment.duration?.seconds ?? 0)
                    }
                }, configuration: settings)
            }
            try await transcoder?.append(data, time: time.map { $0 - timeline.origin })
        }
        // A failed or cancelled conversion keeps draining, so the read thread never waits on it.
        for await input in inputs {
            defer { capacity.signal() }
            guard !failed, !isCancelled else { continue }
            do {
                switch input {
                case let .timeline(origin, videoStart):
                    // Fragments keep the encoder priming before the start, which cannot go below zero.
                    timeline = (origin, CMTimeMaximum(videoStart - origin, priming))
                    let waiting = held
                    held = []
                    for packet in waiting {
                        try await append(packet.data, time: packet.time)
                    }
                case let .packet(data, time):
                    try await append(data, time: time)
                }
            } catch {
                fail(error)
            }
        }
        if isCancelled {
            await transcoder?.cancel()
        } else if !failed {
            do {
                guard let transcoder else {
                    throw SpatialAudioError.source("The track has no sync point to start from")
                }
                _ = try await transcoder.finish()
            } catch {
                fail(error)
            }
        }
        completion.signal()
    }

    @available(macOS 26, iOS 26, tvOS 26, *)
    private static func isSyncPoint(_ data: Data, codec: SpatialAudioCodec) -> Bool {
        let bytes = [UInt8](data.prefix(8))
        switch codec {
        case .trueHDAtmos:
            return bytes.count == 8 && bytes[4 ... 7] == [0xF8, 0x72, 0x6F, 0xBA]
        case .dtsX:
            return bytes.starts(with: [0x7F, 0xFE, 0x80, 0x01])
        }
    }
    #endif
}
