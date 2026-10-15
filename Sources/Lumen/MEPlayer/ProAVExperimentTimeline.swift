// Temporary diagnostics for the isolated AirPlay experiment branch. Never merge this file.
import CryptoKit
import CoreMedia
import Foundation
import Libavcodec
import Libavformat

struct ProAVExperimentMuxSample: @unchecked Sendable {
    let sourceStream: Int32
    let outputStream: Int32
    let codec: AVCodecID
    let sourcePTS: Int64
    let sourceDTS: Int64
    let sourceTimebase: Timebase
    let muxPTS: Int64
    let muxDTS: Int64
    let muxTimebase: Timebase
    let sourceStart: Double
    let digest: String

    static func digest(_ packet: UnsafeMutablePointer<AVPacket>) -> String? {
        guard let bytes = packet.pointee.data, packet.pointee.size > 0 else { return nil }
        return SHA256.hash(data: Data(bytes: bytes, count: Int(packet.pointee.size))).map { String(format: "%02x", $0) }.joined()
    }
}

struct ProAVExperimentMapping: Sendable {
    let sourceOffset: Double
    var fields: [String: String]
    let hasMuxedFLAC: Bool

    static func audioTiming(directory: URL) throws -> [String: String] {
        var context: UnsafeMutablePointer<AVFormatContext>?
        defer { avformat_close_input(&context) }
        var options: OpaquePointer?
        av_dict_set(&options, "protocol_whitelist", "concat,file", 0)
        defer { av_dict_free(&options) }
        let first = directory.appendingPathComponent(ProAVRemuxSession.audioInitSegmentName).path
        let second = directory.appendingPathComponent("audio0.m4s").path
        guard !first.contains("|"), !second.contains("|"),
              avformat_open_input(&context, "concat:\(first)|\(second)", av_find_input_format("mov"), &options) >= 0,
              let context else { throw NSError(domain: "LumenExperimentMapping", code: 10) }
        for index in 0 ..< Int(context.pointee.nb_streams) {
            guard let codec = context.pointee.streams[index]?.pointee.codecpar,
                  codec.pointee.codec_type == AVMEDIA_TYPE_AUDIO else { continue }
            let tag = codec.pointee.codec_tag
            var packet = av_packet_alloc()
            defer { av_packet_free(&packet) }
            guard let packet else { break }
            for _ in 0 ..< 64 {
                guard av_read_frame(context, packet) >= 0 else { break }
                defer { av_packet_unref(packet) }
                if Int(packet.pointee.stream_index) == index, let stream = context.pointee.streams[index] {
                    return [
                        "audioSampleEntry": String(bytes: (0 ..< 4).map { UInt8(truncatingIfNeeded: tag >> ($0 * 8)) }, encoding: .ascii) ?? "unknown",
                        "audioFragmentPTS": "\(packet.pointee.pts)", "audioFragmentDTS": "\(packet.pointee.dts)",
                        "audioFragmentTimebase": "\(stream.pointee.time_base.num)/\(stream.pointee.time_base.den)",
                        "audioFragmentStream": "\(index)", "audioFragmentTrackID": "\(stream.pointee.id)",
                    ]
                }
            }
        }
        throw NSError(domain: "LumenExperimentMapping", code: 11)
    }

    /// Runtime only: correlate the actual compressed video sample, not packet ordering. A muxer
    /// rewrite, duplicate sample, unknown PTS or inconsistent PTS/DTS shift rejects the experiment.
    static func read(directory: URL, sample: ProAVExperimentMuxSample) throws -> Self {
        func rejected(_ code: Int) -> NSError { NSError(domain: "LumenExperimentMapping", code: code) }
        let initURL = directory.appendingPathComponent(ProAVRemuxSession.initSegmentName)
        let segmentURL = directory.appendingPathComponent("segment0.m4s")
        guard !initURL.path.contains("|"), !segmentURL.path.contains("|"),
              sample.sourcePTS != Int64.min, sample.muxPTS != Int64.min,
              sample.sourceStart.isFinite else { throw rejected(1) }
        var context = avformat_alloc_context()
        guard context != nil else { throw rejected(2) }
        defer { avformat_close_input(&context) }
        // Only existing local files; never open the source URL or an HLS network address here.
        var options: OpaquePointer?
        av_dict_set(&options, "protocol_whitelist", "concat,file", 0)
        defer { av_dict_free(&options) }
        let url = "concat:\(initURL.path)|\(segmentURL.path)"
        guard avformat_open_input(&context, url, av_find_input_format("mov"), &options) >= 0,
              let context else { throw rejected(3) }
        let packet = av_packet_alloc()
        guard let packet else { throw rejected(4) }
        defer {
            var released: UnsafeMutablePointer<AVPacket>? = packet
            av_packet_free(&released)
        }
        var matches = [(pts: Int64, dts: Int64, timebase: Timebase, stream: Int32, track: Int32)]()
        var firstAudio = [String: String]()
        var reachedEnd = false
        for _ in 0 ..< 4096 {
            let result = av_read_frame(context, packet)
            if result < 0 {
                reachedEnd = result == AVError.eof.code
                break
            }
            defer { av_packet_unref(packet) }
            let index = Int(packet.pointee.stream_index)
            guard index >= 0, index < Int(context.pointee.nb_streams),
                  let stream = context.pointee.streams[index], let codec = stream.pointee.codecpar else { continue }
            if codec.pointee.codec_type == AVMEDIA_TYPE_AUDIO, firstAudio.isEmpty {
                firstAudio = ["audioFragmentPTS": "\(packet.pointee.pts)", "audioFragmentDTS": "\(packet.pointee.dts)", "audioFragmentTimebase": "\(stream.pointee.time_base.num)/\(stream.pointee.time_base.den)", "audioFragmentStream": "\(index)", "audioFragmentTrackID": "\(stream.pointee.id)"]
            }
            guard codec.pointee.codec_type == AVMEDIA_TYPE_VIDEO,
                  codec.pointee.codec_id == sample.codec,
                  ProAVExperimentMuxSample.digest(packet) == sample.digest else { continue }
            matches.append((packet.pointee.pts, packet.pointee.dts, Timebase(stream.pointee.time_base), packet.pointee.stream_index, stream.pointee.id))
        }
        guard reachedEnd, matches.count == 1, let match = matches.first,
              match.pts != Int64.min else { throw rejected(5) }
        let sourcePTS = sample.sourceTimebase.cmtime(for: sample.sourcePTS).seconds
        let muxPTS = sample.muxTimebase.cmtime(for: sample.muxPTS).seconds
        let fragmentPTS = match.timebase.cmtime(for: match.pts).seconds
        let shift = muxPTS - fragmentPTS
        let offset = sourcePTS - sample.sourceStart - fragmentPTS
        guard shift.isFinite, offset.isFinite else { throw rejected(6) }
        // Require both timestamp domains to agree when decode times exist. Missing decode times
        // remain explicit; unique payload + presentation time still establishes correspondence.
        if sample.muxDTS != Int64.min, match.dts != Int64.min {
            let decodeShift = sample.muxTimebase.cmtime(for: sample.muxDTS).seconds - match.timebase.cmtime(for: match.dts).seconds
            guard abs(decodeShift - shift) < 0.001 else { throw rejected(7) }
        }
        if sample.sourceDTS != Int64.min, sample.muxDTS != Int64.min {
            let sourceDecode = sample.sourceTimebase.cmtime(for: sample.sourceDTS).seconds
            let muxDecode = sample.muxTimebase.cmtime(for: sample.muxDTS).seconds
            guard abs((sourcePTS - muxPTS) - (sourceDecode - muxDecode)) < 0.001 else { throw rejected(8) }
        }
        func base(_ value: Timebase) -> String { "\(value.num)/\(value.den)" }
        let hasFLAC = (0 ..< Int(context.pointee.nb_streams)).contains { index in
            context.pointee.streams[index]?.pointee.codecpar?.pointee.codec_id == AV_CODEC_ID_FLAC
        }
        var fields = [
            "sourceStream": "\(sample.sourceStream)", "muxStream": "\(sample.outputStream)",
            "codecID": "\(sample.codec.rawValue)", "sampleSHA256": sample.digest,
            "sourcePTS": "\(sample.sourcePTS)", "sourceDTS": "\(sample.sourceDTS)", "sourceTimebase": base(sample.sourceTimebase),
            "muxInputPTS": "\(sample.muxPTS)", "muxInputDTS": "\(sample.muxDTS)", "muxTimebase": base(sample.muxTimebase),
            "fragmentPTS": "\(match.pts)", "fragmentDTS": "\(match.dts)", "fragmentTimebase": base(match.timebase),
            "fragmentStream": "\(match.stream)", "fragmentTrackID": "\(match.track)",
            "sourceStart": "\(sample.sourceStart)", "measuredSourceOffset": "\(offset)", "muxShift": "\(shift)",
        ]
        fields.merge(firstAudio) { _, value in value }
        return Self(sourceOffset: offset, fields: fields, hasMuxedFLAC: hasFLAC)
    }
}
