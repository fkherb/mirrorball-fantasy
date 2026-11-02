// Converts one transparent video (e.g. ProRes 4444) to HEVC with alpha in a .mov, using
// AVFoundation's AVAssetExportPresetHEVCHighestQualityWithAlpha.
// Usage: xcrun swift scripts/encode-style-animation.swift <input.mov> <output.mov>
import AVFoundation
import Foundation

let args = CommandLine.arguments
guard args.count == 3 else {
    FileHandle.standardError.write("usage: encode-style-animation.swift <input.mov> <output.mov>\n".data(using: .utf8)!)
    exit(2)
}
let source = URL(fileURLWithPath: args[1])
let destination = URL(fileURLWithPath: args[2])
let asset = AVURLAsset(url: source)
let preset = AVAssetExportPresetHEVCHighestQualityWithAlpha

guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
    FileHandle.standardError.write("This Mac can't export \(preset).\n".data(using: .utf8)!)
    exit(1)
}
try? FileManager.default.removeItem(at: destination)
session.outputURL = destination
session.outputFileType = .mov
session.shouldOptimizeForNetworkUse = true

let done = DispatchSemaphore(value: 0)
session.exportAsynchronously { done.signal() }
done.wait()

guard session.status == .completed else {
    FileHandle.standardError.write("Export failed: \(session.error?.localizedDescription ?? "unknown error")\n".data(using: .utf8)!)
    exit(1)
}
