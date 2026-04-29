import AVFoundation
import ArgumentParser
import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit

private final class ScreenRecorderOutput: NSObject, SCStreamOutput, SCStreamDelegate {
    private let writer: AVAssetWriter
    private let writerInput: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let readyFileURL: URL?
    private var didSignalStarted = false
    private var didStartSession = false
    private(set) var writtenFrameCount = 0

    init(outputURL: URL, width: Int, height: Int, readyFileURL: URL?) throws {
        self.readyFileURL = readyFileURL
        try? FileManager.default.removeItem(at: outputURL)
        if let readyFileURL { try? FileManager.default.removeItem(at: readyFileURL) }

        writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        writerInput = AVAssetWriterInput(
            mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height])
        writerInput.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: writerInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])

        guard writer.canAdd(writerInput) else { throw ValidationError("Unable to add video writer input") }
        writer.add(writerInput)
        guard writer.startWriting() else { throw writer.error ?? ValidationError("Unable to start video writer") }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        FileHandle.standardError.write(Data("screen recorder stream stopped: \(error)\n".utf8))
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .screen, CMSampleBufferIsValid(sampleBuffer) else { return }
        guard let imageBuffer = sampleBuffer.imageBuffer else { return }
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if !didStartSession {
            writer.startSession(atSourceTime: presentationTime)
            didStartSession = true
        }
        guard writerInput.isReadyForMoreMediaData else { return }
        guard adaptor.append(imageBuffer, withPresentationTime: presentationTime) else { return }

        writtenFrameCount += 1
        if !didSignalStarted {
            didSignalStarted = true
            if let readyFileURL { try? Data("ready\n".utf8).write(to: readyFileURL, options: .atomic) }
        }
    }

    var hasStarted: Bool { didSignalStarted }

    func finishWriting() async throws {
        writerInput.markAsFinished()
        let writer = self.writer
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writer.finishWriting { if let error = writer.error { continuation.resume(throwing: error) } else { continuation.resume() } }
        }
    }
}

private enum ScreenRecorderSignal {
    static func stopSignalStream() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let sources = installStopHandlers {
                continuation.yield(())
                continuation.finish()
            }
            continuation.onTermination = { _ in for source in sources { source.cancel() } }
        }
    }

    private static func installStopHandlers(_ onStop: @escaping @Sendable () -> Void) -> [DispatchSourceSignal] {
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)

        let queue = DispatchQueue(label: "muxye2e.screen-recorder.signal")
        let sources = [SIGINT, SIGTERM].map { signalNumber -> DispatchSourceSignal in
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: queue)
            source.setEventHandler(handler: onStop)
            source.resume()
            return source
        }
        return sources
    }
}

struct RecordScreenCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "record-screen")

    @Option(name: .long) var output: String
    @Option(name: .long) var readyFile: String?
    @Option(name: .long) var fps: Int = 15
    @Option(name: .long) var timeoutSeconds: Int = 10

    /// Records the current main display with ScreenCaptureKit until the
    /// process receives SIGINT or SIGTERM. This is the native screen capture
    /// path used by the manual real-system E2E script.
    func run() throws {
        let outputPath = output
        let readyFilePath = readyFile
        let framesPerSecond = fps
        let startupTimeoutSeconds = timeoutSeconds
        let semaphore = DispatchSemaphore(value: 0)
        final class ResultBox: @unchecked Sendable { var result: Result<Void, Error>? }
        let resultBox = ResultBox()

        Task.detached {
            let taskResult: Result<Void, Error>
            do {
                try await Self.runRecorder(output: outputPath, readyFile: readyFilePath, fps: framesPerSecond, timeoutSeconds: startupTimeoutSeconds)
                taskResult = .success(())
            } catch { taskResult = .failure(error) }
            resultBox.result = taskResult
            semaphore.signal()
        }

        semaphore.wait()
        guard let completion = resultBox.result else { throw ValidationError("Screen recorder exited without a result") }
        try completion.get()
    }

    private static func runRecorder(output: String, readyFile: String?, fps: Int, timeoutSeconds: Int) async throws {
        let shareableContent = try await SCShareableContent.current
        let mainDisplayID = CGMainDisplayID()
        guard let display = shareableContent.displays.first(where: { $0.displayID == mainDisplayID }) ?? shareableContent.displays.first else {
            throw ValidationError("No shareable displays are available")
        }

        let outputURL = URL(fileURLWithPath: output)
        let readyFileURL = readyFile.map { URL(fileURLWithPath: $0) }
        let recorder = try ScreenRecorderOutput(
            outputURL: outputURL, width: Int(display.width), height: Int(display.height), readyFileURL: readyFileURL)

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = Int(display.width)
        configuration.height = Int(display.height)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, fps)))
        configuration.queueDepth = 6
        configuration.capturesAudio = false
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = true

        let stream = SCStream(filter: filter, configuration: configuration, delegate: recorder)
        try stream.addStreamOutput(recorder, type: .screen, sampleHandlerQueue: DispatchQueue(label: "muxye2e.screen-recorder.frames"))

        try await stream.startCapture()
        let started = try await Self.waitForRecorderStart(recorder, timeoutSeconds: timeoutSeconds)
        guard started else {
            try await stream.stopCapture()
            throw ValidationError("Timed out waiting for screen recorder frames")
        }

        FileHandle.standardOutput.write(
            Data(
                """
                recording-ready output=\(outputURL.path) displayID=\(display.displayID) width=\(display.width) height=\(display.height)

                """.utf8))

        for await _ in ScreenRecorderSignal.stopSignalStream().prefix(1) { break }

        try await stream.stopCapture()
        try await recorder.finishWriting()
    }

    private static func waitForRecorderStart(_ recorder: ScreenRecorderOutput, timeoutSeconds: Int) async throws -> Bool {
        let timeoutNanoseconds = UInt64(max(1, timeoutSeconds)) * 1_000_000_000
        let start = DispatchTime.now().uptimeNanoseconds
        while DispatchTime.now().uptimeNanoseconds - start < timeoutNanoseconds {
            if recorder.hasStarted { return true }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        return recorder.hasStarted
    }
}
