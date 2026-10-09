import AVFoundation
import CoreMedia
import Foundation

/// Turns a recording's MPEG-TS segments into one MP4 without re-encoding.
///
/// AVFoundation cannot read MPEG-TS, so the segments are demuxed here: PAT
/// and PMT find the H.264 and AAC streams, PES packets give each access unit
/// with its timestamps, H.264 is rewritten from Annex-B start codes to
/// length-prefixed NAL units and ADTS headers are stripped from AAC frames.
/// AVAssetWriter then writes the samples as they are (passthrough).
///
/// A discontinuity (missed segments, a reconnect, a channel switch) restarts
/// the timestamps; each new stretch is shifted to begin where the last one
/// ended, so the file plays straight through the gap.
enum TSRemuxer {
    struct Segment {
        let url: URL
        let discontinuity: Bool
    }

    enum Failure: LocalizedError {
        case unreadable(String)
        case unsupportedVideo(Int)
        case noVideo
        case writer(String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let name): return "录像分片 \(name) 读取失败。"
            case .unsupportedVideo(let type): return "这条线路的视频编码（0x\(String(type, radix: 16))）暂不支持导出。"
            case .noVideo: return "录像里没有可用的画面。"
            case .writer(let message): return "生成视频失败：\(message)"
            }
        }
    }

    static func remux(_ segments: [Segment], to output: URL, progress: (Double) -> Void = { _ in }) throws {
        try? FileManager.default.removeItem(at: output)
        let writer = try Writer(output: output)
        var timeline = Timeline()
        for (index, segment) in segments.enumerated() {
            guard let data = try? Data(contentsOf: segment.url) else {
                throw Failure.unreadable(segment.url.lastPathComponent)
            }
            var demuxer = Demuxer()
            try demuxer.parse(data)
            timeline.place(&demuxer.samples, discontinuity: segment.discontinuity)
            try writer.append(demuxer.samples)
            progress(Double(index + 1) / Double(segments.count))
        }
        try writer.finish()
    }

    // MARK: - Samples

    struct Sample {
        enum Kind { case video, audio }
        let kind: Kind
        var dts: Int64
        var pts: Int64
        /// 90 kHz ticks; video durations are filled in once the next frame is known.
        var duration: Int64
        let data: Data
        let isSync: Bool
        let format: CMFormatDescription
    }

    /// Shifts each segment's 90 kHz timestamps onto one continuous timeline
    /// starting at zero, unwrapping the 33-bit PTS counter.
    struct Timeline {
        private var offset: Int64?
        private var lastSource: Int64?
        private var end: Int64 = 0

        mutating func place(_ samples: inout [Sample], discontinuity: Bool) {
            guard let first = samples.map(\.dts).min() else { return }
            if offset == nil || discontinuity {
                offset = end - first
            } else if let lastSource, first < lastSource - (1 << 32) {
                offset! += 1 << 33
            }
            let shift = offset!
            for index in samples.indices {
                samples[index].dts += shift
                samples[index].pts += shift
            }
            samples.removeAll { $0.dts < 0 }
            lastSource = samples.map(\.dts).max().map { $0 - shift } ?? lastSource
            for sample in samples {
                end = max(end, sample.pts + sample.duration, sample.dts + sample.duration)
            }
            if let lastVideo = samples.last(where: { $0.kind == .video }) {
                // A frame's duration is unknown until the next one; budget one frame.
                end = max(end, lastVideo.dts + 3_600)
            }
        }
    }

    // MARK: - Demuxing

    struct Demuxer {
        var samples: [Sample] = []
        private var pmtPID: Int?
        private var videoPID: Int?
        private var audioPID: Int?
        private var buffers: [Int: Data] = [:]
        private var videoFormat: CMFormatDescription?
        private var sps: Data?
        private var pps: Data?

        mutating func parse(_ data: Data) throws {
            let bytes = [UInt8](data)
            var offset = 0
            while offset + 188 <= bytes.count {
                guard bytes[offset] == 0x47 else {
                    // Lost sync: find the next sync byte.
                    offset += 1
                    continue
                }
                try packet(bytes, at: offset)
                offset += 188
            }
            for pid in buffers.keys.sorted() { try flush(pid) }
            samples.sort { $0.dts < $1.dts }
            // Video durations from the frame that follows.
            var lastVideo: Int?
            for index in samples.indices where samples[index].kind == .video {
                if let previous = lastVideo {
                    samples[previous].duration = max(1, samples[index].dts - samples[previous].dts)
                }
                lastVideo = index
            }
            if let lastVideo {
                let durations = samples.filter { $0.kind == .video }.map(\.duration).filter { $0 > 0 }
                samples[lastVideo].duration = durations.last ?? 3_600
            }
        }

        private mutating func packet(_ b: [UInt8], at o: Int) throws {
            let start = b[o + 1] & 0x40 != 0
            let pid = Int(b[o + 1] & 0x1F) << 8 | Int(b[o + 2])
            let control = (b[o + 3] >> 4) & 0x3
            var p = o + 4
            if control == 2 || control == 3 { p += 1 + Int(b[p]) }
            guard control == 1 || control == 3, p < o + 188 else { return }
            let payload = b[p..<(o + 188)]

            if pid == 0 {
                if start { parsePAT(Array(payload)) }
            } else if pid == pmtPID {
                if start { try parsePMT(Array(payload)) }
            } else if pid == videoPID || pid == audioPID {
                if start {
                    try flush(pid)
                    buffers[pid] = Data(payload)
                } else {
                    buffers[pid]?.append(contentsOf: payload)
                }
            }
        }

        private mutating func parsePAT(_ p: [UInt8]) {
            let s = 1 + Int(p[0])
            guard p.count > s + 8 else { return }
            let length = Int(p[s + 1] & 0x0F) << 8 | Int(p[s + 2])
            var i = s + 8
            while i + 4 <= min(p.count, s + 3 + length - 4) {
                let program = Int(p[i]) << 8 | Int(p[i + 1])
                if program != 0 {
                    pmtPID = Int(p[i + 2] & 0x1F) << 8 | Int(p[i + 3])
                    return
                }
                i += 4
            }
        }

        private mutating func parsePMT(_ p: [UInt8]) throws {
            let s = 1 + Int(p[0])
            guard p.count > s + 12 else { return }
            let length = Int(p[s + 1] & 0x0F) << 8 | Int(p[s + 2])
            let infoLength = Int(p[s + 10] & 0x0F) << 8 | Int(p[s + 11])
            var i = s + 12 + infoLength
            let end = min(p.count, s + 3 + length - 4)
            var unsupported: Int?
            while i + 5 <= end {
                let type = Int(p[i])
                let pid = Int(p[i + 1] & 0x1F) << 8 | Int(p[i + 2])
                let esLength = Int(p[i + 3] & 0x0F) << 8 | Int(p[i + 4])
                switch type {
                case 0x1B where videoPID == nil: videoPID = pid
                case 0x0F where audioPID == nil: audioPID = pid
                case 0x24, 0x10, 0x02: unsupported = type
                default: break
                }
                i += 5 + esLength
            }
            if videoPID == nil, let unsupported { throw Failure.unsupportedVideo(unsupported) }
        }

        private mutating func flush(_ pid: Int) throws {
            guard let pes = buffers.removeValue(forKey: pid) else { return }
            let b = [UInt8](pes)
            guard b.count > 9, b[0] == 0, b[1] == 0, b[2] == 1 else { return }
            let flags = b[7]
            let headerEnd = 9 + Int(b[8])
            guard flags & 0x80 != 0, b.count > headerEnd else { return }
            let pts = Self.timestamp(b, 9)
            let dts = flags & 0x40 != 0 ? Self.timestamp(b, 14) : pts
            let payload = Array(b[headerEnd...])
            if pid == videoPID {
                video(payload, pts: pts, dts: dts)
            } else {
                audio(payload, pts: pts)
            }
        }

        static func timestamp(_ b: [UInt8], _ i: Int) -> Int64 {
            (Int64(b[i] >> 1) & 0x07) << 30 | Int64(b[i + 1]) << 22 | Int64(b[i + 2] >> 1) << 15
                | Int64(b[i + 3]) << 7 | Int64(b[i + 4] >> 1)
        }

        // MARK: H.264

        private mutating func video(_ payload: [UInt8], pts: Int64, dts: Int64) {
            var body = Data()
            var sync = false
            for nal in Self.nalUnits(payload) {
                guard let header = nal.first else { continue }
                switch header & 0x1F {
                case 7: if sps != Data(nal) { sps = Data(nal); videoFormat = nil }
                case 8: if pps != Data(nal) { pps = Data(nal); videoFormat = nil }
                case 9, 12: break // access unit delimiter, filler
                default:
                    if header & 0x1F == 5 { sync = true }
                    var length = UInt32(nal.count).bigEndian
                    body.append(Data(bytes: &length, count: 4))
                    body.append(contentsOf: nal)
                }
            }
            if videoFormat == nil, let sps, let pps { videoFormat = Self.h264Format(sps: sps, pps: pps) }
            guard !body.isEmpty, let videoFormat else { return }
            samples.append(Sample(kind: .video, dts: dts, pts: pts, duration: 0, data: body, isSync: sync, format: videoFormat))
        }

        static func nalUnits(_ b: [UInt8]) -> [ArraySlice<UInt8>] {
            var starts: [(code: Int, body: Int)] = []
            var i = 0
            while i + 3 <= b.count {
                if b[i] == 0, b[i + 1] == 0, b[i + 2] == 1 {
                    let code = i > 0 && b[i - 1] == 0 ? i - 1 : i
                    starts.append((code, i + 3))
                    i += 3
                } else {
                    i += 1
                }
            }
            return starts.enumerated().map { index, start in
                let end = index + 1 < starts.count ? starts[index + 1].code : b.count
                return b[start.body..<max(start.body, end)]
            }.filter { !$0.isEmpty }
        }

        static func h264Format(sps: Data, pps: Data) -> CMFormatDescription? {
            var format: CMFormatDescription?
            let status = sps.withUnsafeBytes { s in
                pps.withUnsafeBytes { p in
                    let pointers = [s.bindMemory(to: UInt8.self).baseAddress!, p.bindMemory(to: UInt8.self).baseAddress!]
                    let sizes = [sps.count, pps.count]
                    return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                        allocator: nil, parameterSetCount: 2, parameterSetPointers: pointers,
                        parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &format)
                }
            }
            return status == noErr ? format : nil
        }

        // MARK: AAC

        private var audioFormats: [UInt32: CMFormatDescription] = [:]

        private mutating func audio(_ b: [UInt8], pts: Int64) {
            var i = 0
            var time = pts
            while i + 7 <= b.count {
                guard b[i] == 0xFF, b[i + 1] & 0xF0 == 0xF0 else { i += 1; continue }
                let protectionAbsent = b[i + 1] & 0x01 == 1
                let objectType = UInt32(b[i + 2] >> 6) + 1
                let rateIndex = UInt32(b[i + 2] >> 2) & 0x0F
                let channels = UInt32(b[i + 2] & 0x01) << 2 | UInt32(b[i + 3] >> 6)
                let frameLength = Int(b[i + 3] & 0x03) << 11 | Int(b[i + 4]) << 3 | Int(b[i + 5] >> 5)
                let header = protectionAbsent ? 7 : 9
                guard frameLength > header, i + frameLength <= b.count,
                      let rate = Self.sampleRates[safe: Int(rateIndex)] else { break }
                let key = objectType << 16 | rateIndex << 8 | channels
                if audioFormats[key] == nil {
                    audioFormats[key] = Self.aacFormat(objectType: objectType, rateIndex: rateIndex,
                                                       rate: rate, channels: channels)
                }
                if let format = audioFormats[key] {
                    let duration = Int64(1024 * 90_000 / rate)
                    samples.append(Sample(kind: .audio, dts: time, pts: time, duration: duration,
                                          data: Data(b[(i + header)..<(i + frameLength)]), isSync: true, format: format))
                    time += duration
                }
                i += frameLength
            }
        }

        static let sampleRates = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]

        static func aacFormat(objectType: UInt32, rateIndex: UInt32, rate: Int, channels: UInt32) -> CMFormatDescription? {
            var description = AudioStreamBasicDescription(
                mSampleRate: Float64(rate), mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 0,
                mBytesPerPacket: 0, mFramesPerPacket: 1024, mBytesPerFrame: 0,
                mChannelsPerFrame: max(1, channels), mBitsPerChannel: 0, mReserved: 0)
            // AudioSpecificConfig (object type, frequency index, channels) wrapped
            // in the ES descriptor CoreMedia expects as an AAC magic cookie.
            let config = objectType << 11 | rateIndex << 7 | channels << 3
            let cookie: [UInt8] = [
                0x03, 25, 0, 0, 0,                          // ES_Descriptor
                0x04, 17, 0x40, 0x15, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, // DecoderConfig: AAC, audio stream
                0x05, 2, UInt8(config >> 8), UInt8(config & 0xFF), // DecoderSpecificInfo
                0x06, 1, 2                                  // SLConfig
            ]
            var format: CMFormatDescription?
            let status = cookie.withUnsafeBytes { bytes in
                CMAudioFormatDescriptionCreate(
                    allocator: nil, asbd: &description, layoutSize: 0, layout: nil,
                    magicCookieSize: cookie.count, magicCookie: bytes.baseAddress, extensions: nil,
                    formatDescriptionOut: &format)
            }
            return status == noErr ? format : nil
        }
    }

    // MARK: - Writing

    final class Writer {
        private let writer: AVAssetWriter
        private var video: AVAssetWriterInput?
        private var audio: AVAssetWriterInput?
        private var started = false
        private var lastVideoDTS: Int64 = -1

        init(output: URL) throws {
            do {
                writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
            } catch {
                throw Failure.writer(error.localizedDescription)
            }
        }

        func append(_ samples: [Sample]) throws {
            if !started {
                // Inputs need a format hint before writing starts; wait for a
                // segment that has video.
                guard let videoSample = samples.first(where: { $0.kind == .video }) else { return }
                let video = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: videoSample.format)
                video.expectsMediaDataInRealTime = false
                writer.add(video)
                self.video = video
                if let audioSample = samples.first(where: { $0.kind == .audio }) {
                    let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: audioSample.format)
                    audio.expectsMediaDataInRealTime = false
                    writer.add(audio)
                    self.audio = audio
                }
                guard writer.startWriting() else {
                    throw Failure.writer(writer.error?.localizedDescription ?? "无法开始写入")
                }
                writer.startSession(atSourceTime: .zero)
                started = true
            }

            for sample in samples {
                switch sample.kind {
                case .video:
                    // Out-of-order decode times would make the writer fail the whole file.
                    guard sample.dts > lastVideoDTS, video != nil else { continue }
                    lastVideoDTS = sample.dts
                    pendingVideo.append(sample)
                case .audio:
                    if audio != nil { pendingAudio.append(sample) }
                }
            }
            try pump(final: false)
        }

        // The writer interleaves the tracks itself and stops taking one track
        // while it waits for the other to catch up, so feed whichever input is
        // ready. Leftovers wait for the next segment; at the end each track is
        // marked finished as soon as it drains, which releases the other.
        private var pendingVideo: [Sample] = []
        private var pendingAudio: [Sample] = []
        private var videoIndex = 0
        private var audioIndex = 0

        private func pump(final: Bool) throws {
            var idle = 0
            while true {
                var progressed = false
                if let video, videoIndex < pendingVideo.count, video.isReadyForMoreMediaData {
                    try append(pendingVideo[videoIndex], to: video)
                    videoIndex += 1
                    progressed = true
                }
                if let audio, audioIndex < pendingAudio.count, audio.isReadyForMoreMediaData {
                    try append(pendingAudio[audioIndex], to: audio)
                    audioIndex += 1
                    progressed = true
                }
                let videoDrained = videoIndex >= pendingVideo.count
                let audioDrained = audioIndex >= pendingAudio.count
                if final {
                    if videoDrained, let video, !videoFinished { video.markAsFinished(); videoFinished = true }
                    if audioDrained, let audio, !audioFinished { audio.markAsFinished(); audioFinished = true }
                    if videoDrained && audioDrained { break }
                } else if videoDrained || audioDrained, !progressed {
                    break
                }
                if writer.status == .failed {
                    throw Failure.writer(writer.error?.localizedDescription ?? "写入失败")
                }
                if progressed {
                    idle = 0
                } else {
                    usleep(2_000)
                    idle += 1
                    if idle > 5_000 { throw Failure.writer("写入超时") }
                }
            }
            pendingVideo.removeFirst(videoIndex)
            pendingAudio.removeFirst(audioIndex)
            videoIndex = 0
            audioIndex = 0
        }

        private var videoFinished = false
        private var audioFinished = false

        private func append(_ sample: Sample, to input: AVAssetWriterInput) throws {
            guard let buffer = Self.sampleBuffer(sample) else { return }
            if !input.append(buffer) {
                throw Failure.writer(writer.error?.localizedDescription ?? "写入失败")
            }
        }

        func finish() throws {
            guard started else {
                writer.cancelWriting()
                throw Failure.noVideo
            }
            try pump(final: true)
            let done = DispatchSemaphore(value: 0)
            writer.finishWriting { done.signal() }
            done.wait()
            if writer.status != .completed {
                throw Failure.writer(writer.error?.localizedDescription ?? "无法完成写入")
            }
        }

        static func sampleBuffer(_ sample: Sample) -> CMSampleBuffer? {
            var block: CMBlockBuffer?
            guard CMBlockBufferCreateWithMemoryBlock(
                allocator: nil, memoryBlock: nil, blockLength: sample.data.count, blockAllocator: nil,
                customBlockSource: nil, offsetToData: 0, dataLength: sample.data.count, flags: 0,
                blockBufferOut: &block) == noErr, let block else { return nil }
            let copied = sample.data.withUnsafeBytes {
                CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0,
                                              dataLength: sample.data.count)
            }
            guard copied == noErr else { return nil }
            var timing = CMSampleTimingInfo(
                duration: CMTime(value: sample.duration, timescale: 90_000),
                presentationTimeStamp: CMTime(value: sample.pts, timescale: 90_000),
                decodeTimeStamp: sample.kind == .video ? CMTime(value: sample.dts, timescale: 90_000) : .invalid)
            var size = sample.data.count
            var buffer: CMSampleBuffer?
            guard CMSampleBufferCreateReady(
                allocator: nil, dataBuffer: block, formatDescription: sample.format, sampleCount: 1,
                sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
                sampleSizeArray: &size, sampleBufferOut: &buffer) == noErr, let buffer else { return nil }
            if !sample.isSync,
               let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: true),
               CFArrayGetCount(attachments) > 0 {
                let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
                CFDictionarySetValue(dictionary,
                                     Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                                     Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            }
            return buffer
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
