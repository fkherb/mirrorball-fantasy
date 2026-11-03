// Builds an HEVC-with-alpha .mov from a folder of transparent PNG frames (00001.png, …).
// Apple's decoders ignore the alpha in ffmpeg-made ProRes 4444, so frames are extracted
// with ffmpeg (which reads it) and written here with AVAssetWriter, alpha and all.
// Usage: xcrun swift scripts/encode-style-animation-frames.swift <framesDir> <fps> <output.mov>
import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import VideoToolbox

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

let args = CommandLine.arguments
guard args.count == 4, let fps = Int32(args[2]) else { fail("usage: <framesDir> <fps> <output.mov>") }
let dir = URL(fileURLWithPath: args[1], isDirectory: true)
let output = URL(fileURLWithPath: args[3])

let frames = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
    .filter { $0.pathExtension.lowercased() == "png" }
    .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
guard let firstURL = frames.first else { fail("No PNG frames in \(dir.path)") }

func image(_ url: URL) -> CGImage {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { fail("Can't read \(url.path)") }
    return image
}

let first = image(firstURL)
let width = first.width, height = first.height

try? FileManager.default.removeItem(at: output)
let writer: AVAssetWriter
do { writer = try AVAssetWriter(outputURL: output, fileType: .mov) } catch { fail("\(error)") }

let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.hevcWithAlpha,
    AVVideoWidthKey: width,
    AVVideoHeightKey: height,
    AVVideoCompressionPropertiesKey: [
        AVVideoQualityKey: 0.7,
        kVTCompressionPropertyKey_TargetQualityForAlpha as String: 0.7,
    ],
])
input.expectsMediaDataInRealTime = false
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    kCVPixelBufferWidthKey as String: width,
    kCVPixelBufferHeightKey as String: height,
])
guard writer.canAdd(input) else { fail("Can't add an HEVC-with-alpha track on this Mac.") }
writer.add(input)
guard writer.startWriting() else { fail("Can't start writing: \(writer.error?.localizedDescription ?? "?")") }
writer.startSession(atSourceTime: .zero)

let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
for (index, url) in frames.enumerated() {
    while !input.isReadyForMoreMediaData { usleep(2_000) }
    guard let pool = adaptor.pixelBufferPool else { fail("No pixel buffer pool: \(writer.error?.localizedDescription ?? "?")") }
    var buffer: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
    guard let buffer else { fail("Can't make a pixel buffer") }
    CVPixelBufferLockBaseAddress(buffer, [])
    let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
                            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: colorSpace,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    context.clear(CGRect(x: 0, y: 0, width: width, height: height))
    context.draw(index == 0 ? first : image(url), in: CGRect(x: 0, y: 0, width: width, height: height))
    CVPixelBufferUnlockBaseAddress(buffer, [])
    guard adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: fps)) else {
        fail("Append failed at frame \(index): \(writer.error?.localizedDescription ?? "?")")
    }
}

input.markAsFinished()
let done = DispatchSemaphore(value: 0)
writer.finishWriting { done.signal() }
done.wait()
guard writer.status == .completed else { fail("Writing failed: \(writer.error?.localizedDescription ?? "?")") }
print("\(output.lastPathComponent): \(frames.count) frames at \(fps) fps")
