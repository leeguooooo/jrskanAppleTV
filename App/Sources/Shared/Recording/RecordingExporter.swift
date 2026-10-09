import AVFoundation
import CoreImage
import UIKit

/// Makes the shareable MP4 for a finished recording: remux the segments
/// (TSRemuxer), then re-encode once with the watermark and the
/// `recording_banner` ad drawn into the picture, so they travel with the file
/// wherever it is shared. The watermark keeps gliding between random spots
/// like it does in the player, cycling through the configured texts.
enum RecordingExporter {
    struct Overlay {
        var watermark: AppConfig.Watermark?
        var banner: AppConfig.Slot?
    }

    enum Failure: LocalizedError {
        case export(String)

        var errorDescription: String? {
            switch self {
            case .export(let message): return "生成视频失败：\(message)"
            }
        }
    }

    /// `progress` runs on an arbitrary queue: remuxing is the first 30 %, encoding the rest.
    static func export(
        segments: [TSRemuxer.Segment],
        intermediate: URL,
        output: URL,
        overlay: Overlay,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        try await Task.detached(priority: .utility) {
            try TSRemuxer.remux(segments, to: intermediate) { progress($0 * 0.3) }
        }.value
        defer { try? FileManager.default.removeItem(at: intermediate) }

        let asset = AVURLAsset(url: intermediate)
        guard overlay.watermark != nil || overlay.banner != nil else {
            // Nothing to draw: the remuxed file is the result.
            try? FileManager.default.removeItem(at: output)
            try FileManager.default.moveItem(at: intermediate, to: output)
            progress(1)
            return
        }

        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw TSRemuxer.Failure.noVideo
        }
        let naturalSize = try await track.load(.naturalSize)
        let duration = try await asset.load(.duration).seconds
        let painter = OverlayPainter(overlay: overlay, size: naturalSize, duration: duration)
        let composition = AVMutableVideoComposition(asset: asset) { request in
            request.finish(with: painter.draw(on: request.sourceImage, at: request.compositionTime.seconds), context: nil)
        }
        composition.renderSize = naturalSize

        let audioTrack = try await asset.loadTracks(withMediaType: .audio).first
        let sourceRate = try await track.load(.estimatedDataRate)
        try await Task.detached(priority: .utility) {
            try transcode(asset: asset, video: track, audio: audioTrack, composition: composition,
                          size: naturalSize, bitRate: Self.bitRate(source: sourceRate, size: naturalSize),
                          duration: duration, output: output) { progress(0.3 + $0 * 0.7) }
        }.value
        progress(1)
    }

    /// About the source's own bit rate: the overlays add almost nothing, and
    /// the preset exporters ran at ~10 Mbit/s, which made a two-hour match
    /// close to 20 GB.
    static func bitRate(source: Float, size: CGSize) -> Int {
        let floor = size.height >= 1000 ? 3_000_000 : 1_500_000
        let fallback = size.height >= 1000 ? 5_000_000 : 3_000_000
        guard source > 0 else { return fallback }
        return min(8_000_000, max(floor, Int(source * 1.1)))
    }

    /// Re-encodes the video through the overlay composition at `bitRate`;
    /// audio is copied untouched.
    private static func transcode(
        asset: AVAsset, video: AVAssetTrack, audio: AVAssetTrack?, composition: AVVideoComposition,
        size: CGSize, bitRate: Int, duration: Double, output: URL, progress: @escaping (Double) -> Void
    ) throws {
        try? FileManager.default.removeItem(at: output)
        let reader = try AVAssetReader(asset: asset)
        let videoOut = AVAssetReaderVideoCompositionOutput(videoTracks: [video], videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ])
        videoOut.videoComposition = composition
        reader.add(videoOut)
        var audioOut: AVAssetReaderTrackOutput?
        if let audio {
            let out = AVAssetReaderTrackOutput(track: audio, outputSettings: nil)
            reader.add(out)
            audioOut = out
        }

        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitRate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoMaxKeyFrameIntervalDurationKey: 2
            ]
        ])
        videoIn.expectsMediaDataInRealTime = false
        writer.add(videoIn)
        var audioIn: AVAssetWriterInput?
        if let audio, let hint = audio.formatDescriptions.first {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil,
                                           sourceFormatHint: (hint as! CMFormatDescription))
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            audioIn = input
        }

        guard reader.startReading(), writer.startWriting() else {
            throw Failure.export(reader.error?.localizedDescription ?? writer.error?.localizedDescription ?? "无法开始")
        }
        writer.startSession(atSourceTime: .zero)

        let group = DispatchGroup()
        func pump(_ input: AVAssetWriterInput, from out: AVAssetReaderOutput, label: String, reportsProgress: Bool) {
            group.enter()
            let queue = DispatchQueue(label: "recording-export.\(label)")
            var finished = false
            input.requestMediaDataWhenReady(on: queue) {
                guard !finished else { return }
                while input.isReadyForMoreMediaData {
                    guard reader.status == .reading, let buffer = out.copyNextSampleBuffer() else {
                        finished = true
                        input.markAsFinished()
                        group.leave()
                        return
                    }
                    if reportsProgress, duration > 0 {
                        progress(min(1, CMSampleBufferGetPresentationTimeStamp(buffer).seconds / duration))
                    }
                    if !input.append(buffer) {
                        finished = true
                        reader.cancelReading()
                        input.markAsFinished()
                        group.leave()
                        return
                    }
                }
            }
        }
        pump(videoIn, from: videoOut, label: "video", reportsProgress: true)
        if let audioIn, let audioOut { pump(audioIn, from: audioOut, label: "audio", reportsProgress: false) }
        group.wait()

        if reader.status == .failed || writer.status == .failed {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: output)
            throw Failure.export(writer.error?.localizedDescription ?? reader.error?.localizedDescription ?? "转码失败")
        }
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: output)
            throw Failure.export(writer.error?.localizedDescription ?? "无法完成写入")
        }
    }

    // MARK: - Drawing

    /// Draws the overlays onto each frame with Core Image. Texts are rendered
    /// to images once; per frame only their position and turn are computed.
    /// (Core Animation through AVVideoCompositionCoreAnimationTool crashed
    /// creating IOSurfaces in the simulator, and this is simpler to reason about.)
    final class OverlayPainter: @unchecked Sendable {
        private let size: CGSize
        private let banner: (image: CIImage, origin: CGPoint)?
        private let texts: [CIImage]
        private let points: [CGPoint]
        private let leg: Double
        private let motion: AppConfig.Watermark.Motion

        init(overlay: Overlay, size: CGSize, duration: Double) {
            self.size = size
            let frame = CGRect(origin: .zero, size: size)
            if let slot = overlay.banner, let image = Self.bannerImage(slot, height: size.height) {
                banner = (image, CGPoint(x: frame.width * 0.03, y: frame.height * 0.05))
            } else {
                banner = nil
            }
            let watermark = overlay.watermark
            leg = watermark?.interval ?? 8
            motion = watermark?.motion ?? .drift
            let fontSize = max(16, size.height * 0.04)
            texts = (watermark?.texts ?? []).compactMap {
                Self.textImage($0, fontSize: fontSize, opacity: watermark?.opacity ?? 0.55)
            }
            let largest = texts.reduce(CGSize.zero) { CGSize(width: max($0.width, $1.extent.width), height: max($0.height, $1.extent.height)) }
            let area = CGRect(x: frame.width * 0.04, y: frame.height * 0.06,
                              width: max(0, frame.width * 0.92 - largest.width),
                              height: max(0, frame.height * 0.88 - largest.height))
            let legs = max(1, Int(ceil(duration / leg))) + 1
            points = (0...legs).map { _ in
                CGPoint(x: area.minX + CGFloat.random(in: 0...1) * area.width,
                        y: area.minY + CGFloat.random(in: 0...1) * area.height)
            }
        }

        func draw(on frame: CIImage, at time: Double) -> CIImage {
            var image = frame
            if let banner {
                image = banner.image.transformed(by: CGAffineTransform(translationX: banner.origin.x, y: banner.origin.y))
                    .composited(over: image)
            }
            if !texts.isEmpty {
                let index = min(points.count - 2, max(0, Int(time / leg)))
                let text = texts[index % texts.count]
                let origin: CGPoint
                switch motion {
                case .fixed:
                    origin = CGPoint(x: size.width * 0.97 - text.extent.width, y: size.height * 0.05)
                case .hop:
                    origin = points[index]
                case .drift:
                    let t = CGFloat(min(1, max(0, time / leg - Double(index))))
                    let a = points[index], b = points[index + 1]
                    origin = CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
                }
                image = text.transformed(by: CGAffineTransform(translationX: origin.x, y: origin.y)).composited(over: image)
            }
            return image.cropped(to: frame.extent)
        }

        static func textImage(_ text: String, fontSize: CGFloat, opacity: Double) -> CIImage? {
            let font = UIFont.systemFont(ofSize: fontSize, weight: .semibold)
            let shadow = NSShadow()
            shadow.shadowColor = UIColor.black.withAlphaComponent(0.6)
            shadow.shadowOffset = CGSize(width: 0, height: 1)
            shadow.shadowBlurRadius = 2
            let attributed = NSAttributedString(string: text, attributes: [
                .font: font, .foregroundColor: UIColor.white.withAlphaComponent(opacity), .shadow: shadow
            ])
            let size = attributed.size()
            return render(CGSize(width: ceil(size.width) + 6, height: ceil(size.height) + 6)) { _ in
                attributed.draw(at: CGPoint(x: 3, y: 3))
            }
        }

        /// A dark rounded strip: 推广 tag, title, detail.
        static func bannerImage(_ slot: AppConfig.Slot, height: CGFloat) -> CIImage? {
            let fontSize = max(14, height * 0.03)
            let small = UIFont.systemFont(ofSize: fontSize * 0.8)
            let text = NSMutableAttributedString(string: "推广  ", attributes: [
                .font: small, .foregroundColor: UIColor.white.withAlphaComponent(0.7)
            ])
            text.append(NSAttributedString(string: slot.title, attributes: [
                .font: UIFont.systemFont(ofSize: fontSize, weight: .semibold), .foregroundColor: UIColor.white
            ]))
            if !slot.detail.isEmpty {
                text.append(NSAttributedString(string: "  \(slot.detail)", attributes: [
                    .font: small, .foregroundColor: UIColor.white.withAlphaComponent(0.85)
                ]))
            }
            let padding = fontSize * 0.6
            let textSize = text.size()
            let size = CGSize(width: ceil(textSize.width + padding * 2), height: ceil(textSize.height + padding * 1.2))
            return render(size) { _ in
                UIColor.black.withAlphaComponent(0.55).setFill()
                UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: fontSize * 0.5).fill()
                text.draw(at: CGPoint(x: padding, y: padding * 0.6))
            }
        }

        private static func render(_ size: CGSize, _ draw: (UIGraphicsImageRendererContext) -> Void) -> CIImage? {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = false
            let image = UIGraphicsImageRenderer(size: size, format: format).image(actions: draw)
            return image.cgImage.map { CIImage(cgImage: $0) }
        }
    }
}
