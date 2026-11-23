import AVFoundation
import Foundation
import ScreenCaptureKit

// Writes CMSampleBuffers of audio to an AAC .m4a file.
final class AudioFileWriter {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private var started = false
    private let queue = DispatchQueue(label: "audiorec.writer")

    init(url: URL, channels: Int) throws {
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: 64000 * channels,
        ])
        input.expectsMediaDataInRealTime = true
        writer.add(input)
    }

    func append(_ buffer: CMSampleBuffer) {
        queue.async {
            guard CMSampleBufferDataIsReady(buffer) else { return }
            if !self.started {
                guard self.writer.startWriting() else { return }
                self.writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(buffer))
                self.started = true
            }
            if self.input.isReadyForMoreMediaData { self.input.append(buffer) }
        }
    }

    func finish() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            queue.async {
                guard self.started else { c.resume(); return }
                self.input.markAsFinished()
                self.writer.finishWriting { c.resume() }
            }
        }
    }
}

final class Recorder: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    let system: AudioFileWriter
    let mic: AudioFileWriter?
    private let queue = DispatchQueue(label: "audiorec.capture")

    init(system: AudioFileWriter, mic: AudioFileWriter?) {
        self.system = system
        self.mic = mic
    }

    func start(micDeviceID: String?) async throws {
        let content = try await SCShareableContent.current
        guard let display = content.displays.first else {
            throw NSError(domain: "audiorec", code: 1, userInfo: [NSLocalizedDescriptionKey: "No display found"])
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let cfg = SCStreamConfiguration()
        cfg.capturesAudio = true
        cfg.excludesCurrentProcessAudio = true
        cfg.sampleRate = 48000
        cfg.channelCount = 2
        if mic != nil {
            cfg.captureMicrophone = true
            if let id = micDeviceID { cfg.microphoneCaptureDeviceID = id }
        }
        // Audio only: shrink video to the minimum.
        cfg.width = 2
        cfg.height = 2
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        if mic != nil { try s.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue) }
        try await s.startCapture()
        stream = s
    }

    func stop() async {
        try? await stream?.stopCapture()
        await system.finish()
        await mic?.finish()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        switch type {
        case .audio: system.append(sb)
        case .microphone: mic?.append(sb)
        default: break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        FileHandle.standardError.write(Data("Stream stopped: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
}

// Mixes system.m4a and mic.m4a into a single mixed.m4a track.
func mixTracks(in dir: URL) async throws {
    let comp = AVMutableComposition()
    for name in ["system.m4a", "mic.m4a"] {
        let asset = AVURLAsset(url: dir.appendingPathComponent(name))
        guard let src = try await asset.loadTracks(withMediaType: .audio).first,
              let track = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { continue }
        let dur = try await asset.load(.duration)
        try track.insertTimeRange(CMTimeRange(start: .zero, duration: dur), of: src, at: .zero)
    }
    guard let export = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetAppleM4A) else {
        throw NSError(domain: "audiorec", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not create export session"])
    }
    let out = dir.appendingPathComponent("mixed.m4a")
    try? FileManager.default.removeItem(at: out)
    try await export.export(to: out, as: .m4a)
}

// MARK: - CLI

func usage() -> Never {
    print("""
    Usage: audiorec [options]

      -o, --output <dir>   Output directory (default: ~/audio-record-mac-recordings/recording-<timestamp>)
      --no-mic             Record system audio only
      --mix                Also write mixed.m4a (system + mic combined)
      --mic-device <id>    Microphone device uniqueID (default: system default)
      --duration <secs>    Stop automatically after N seconds
      --list-mics          List microphones and exit
      -h, --help

    Writes system.m4a and mic.m4a. Stop with Ctrl-C.
    Requires macOS 15+, with Screen Recording and Microphone permission
    granted to your terminal app.
    """)
    exit(0)
}

var outDir: String?
var useMic = true
var micDevice: String?
var duration: Double?
var mix = false

var args = CommandLine.arguments.dropFirst()
while let a = args.popFirst() {
    switch a {
    case "-o", "--output": outDir = args.popFirst()
    case "--no-mic": useMic = false
    case "--mix": mix = true
    case "--mic-device": micDevice = args.popFirst()
    case "--duration": duration = args.popFirst().flatMap(Double.init)
    case "--list-mics":
        let d = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified)
        for dev in d.devices { print("\(dev.uniqueID)\t\(dev.localizedName)") }
        exit(0)
    default: usage()
    }
}

if useMic {
    let ok = await AVCaptureDevice.requestAccess(for: .audio)
    if !ok {
        FileHandle.standardError.write(Data("Microphone permission denied (System Settings > Privacy & Security > Microphone).\n".utf8))
        exit(1)
    }
}

let stamp: String = {
    let f = DateFormatter()
    f.dateFormat = "yyyyMMdd-HHmmss"
    return f.string(from: Date())
}()
let defaultBase = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("audio-record-mac-recordings")
let dir = outDir.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
    ?? defaultBase.appendingPathComponent("recording-\(stamp)")
try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

let recorder = Recorder(
    system: try AudioFileWriter(url: dir.appendingPathComponent("system.m4a"), channels: 2),
    mic: useMic ? try AudioFileWriter(url: dir.appendingPathComponent("mic.m4a"), channels: 1) : nil
)

do {
    try await recorder.start(micDeviceID: micDevice)
} catch {
    FileHandle.standardError.write(Data("Failed to start: \(error.localizedDescription)\nGrant Screen Recording permission to your terminal in System Settings > Privacy & Security.\n".utf8))
    exit(1)
}
print("Recording to \(dir.path) — press Ctrl-C to stop.")

signal(SIGINT, SIG_IGN)
let sigSrc = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
    var resumed = false
    let finish = {
        if !resumed { resumed = true; c.resume() }
    }
    sigSrc.setEventHandler(handler: finish)
    sigSrc.resume()
    if let d = duration {
        DispatchQueue.main.asyncAfter(deadline: .now() + d, execute: finish)
    }
}

await recorder.stop()
if mix && useMic {
    do {
        try await mixTracks(in: dir)
        print("Wrote mixed.m4a")
    } catch {
        FileHandle.standardError.write(Data("Mix failed: \(error.localizedDescription)\n".utf8))
    }
}
print("Saved.")
