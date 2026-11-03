// Decodes a few frames of a video with AVFoundation and reports how much of each frame is
// transparent, to tell whether an HEVC-with-alpha file really kept its alpha.
// Usage: xcrun swift scripts/check-style-animation-alpha.swift <file.mov> [more files…]
import AVFoundation
import Foundation

func check(_ path: String) async throws {
    let asset = AVURLAsset(url: URL(fileURLWithPath: path))
    guard let track = try await asset.loadTracks(withMediaType: .video).first else { print("\(path): no video track"); return }
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    ])
    reader.add(output)
    reader.startReading()
    var frame = 0, results: [String] = []
    while let sample = output.copyNextSampleBuffer(), results.count < 3 {
        defer { frame += 1 }
        guard frame % 60 == 30, let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        let row = CVPixelBufferGetBytesPerRow(buffer)
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        var clear = 0
        for y in 0..<h { for x in 0..<w where base[y * row + x * 4 + 3] < 8 { clear += 1 } }
        CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
        results.append("frame \(frame): \(clear * 100 / (w * h))% transparent, corner alpha \(base[3])")
    }
    reader.cancelReading()
    print("\(URL(fileURLWithPath: path).lastPathComponent): " + results.joined(separator: "; "))
}

let files = Array(CommandLine.arguments.dropFirst())
for file in files { try await check(file) }
