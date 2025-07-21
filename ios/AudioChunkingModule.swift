import Foundation
import AVFoundation
import React

@objc(AudioChunkingModule)
class AudioChunkingModule: RCTEventEmitter {
    private var audioEngine: AVAudioEngine?
    private var isRecording = false
    private var chunkDurationMs: Int = 120000 // default to 120 seconds
    private var audioBuffer = Data()
    private var sampleRate: Double = 22050
    private let processingQueue = DispatchQueue(label: "audio.processing", qos: .userInitiated)
    private var chunkTimer: DispatchSourceTimer?

    override init() {
        super.init()
        setupAudioSession()
    }

    override func supportedEvents() -> [String]! {
        return ["onChunkReady"]
    }

    @objc
    override static func requiresMainQueueSetup() -> Bool {
        return false
    }

    private func setupAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .default)
            try session.setActive(true)
        } catch {
            print("Failed to setup audio session: \(error)")
        }
    }

    private func resetModuleState() {
        audioBuffer.removeAll()
        sampleRate = 22050
    }

    @objc
    func startChunkedRecording(_ chunkDuration: Int, resolver: @escaping RCTPromiseResolveBlock, rejecter: @escaping RCTPromiseRejectBlock) {
        guard !isRecording else {
            rejecter("ALREADY_RECORDING", "Recording already in progress", nil)
            return
        }

        // Cleanup any previous session: timer + engine
        stopAndCleanupEngine()
        resetModuleState()

        // Configure
        chunkDurationMs = chunkDuration
        isRecording = true

        // Initialize new engine and tap
        let engine = AVAudioEngine()
        audioEngine = engine
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        sampleRate = format.sampleRate

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.processingQueue.async {
                self?.appendBufferData(buffer)
            }
        }
        print("✅ Installed tap on inputNode")

        do {
            engine.prepare()
            try engine.start()
            print("✅ Started AVAudioEngine")
        } catch {
            stopAndCleanupEngine()
            isRecording = false
            resetModuleState()
            rejecter("START_FAILED", "Failed to start engine: \(error.localizedDescription)", error)
            return
        }

        // Schedule repeating chunk timer
        let timer = DispatchSource.makeTimerSource(queue: processingQueue)
        timer.schedule(deadline: .now() + .milliseconds(chunkDurationMs), repeating: .milliseconds(chunkDurationMs))
        timer.setEventHandler { [weak self] in
            self?.createAndSendChunk()
        }
        timer.resume()
        chunkTimer = timer

        resolver("Recording started successfully")
    }

    private func appendBufferData(_ buffer: AVAudioPCMBuffer) {
        let frameLen = Int(buffer.frameLength)
        guard let channel = buffer.floatChannelData?[0] else { return }
        var data = Data()
        for i in 0..<frameLen {
            let sample = channel[i]
            let int16 = Int16(sample * Float(Int16.max))
            withUnsafeBytes(of: int16.littleEndian) { data.append(contentsOf: $0) }
        }
        audioBuffer.append(data)
    }

    private func createAndSendChunk() {
        guard !audioBuffer.isEmpty else { return }
        let b64 = audioBuffer.base64EncodedString()
        let chunk: [String: Any] = [
            "audioData": b64,
            "format": "pcm",
            "sampleRate": Int(sampleRate),
            "channels": 1,
            "bitsPerSample": 16
        ]
        DispatchQueue.main.async { self.sendEvent(withName: "onChunkReady", body: chunk) }
        audioBuffer.removeAll()
    }

    @objc
    func stopRecording(_ resolver: @escaping RCTPromiseResolveBlock, rejecter: @escaping RCTPromiseRejectBlock) {
        guard isRecording else {
            rejecter("NOT_RECORDING", "No recording in progress", nil)
            return
        }

        isRecording = false

        // Engine + timer cleanup will handle both
        stopAndCleanupEngine()

        // Flush any remaining data
        processingQueue.async { [weak self] in
            guard let self = self else { return }
            if !self.audioBuffer.isEmpty {
                self.createAndSendChunk()
            }
            self.resetModuleState()
            DispatchQueue.main.async { resolver("Recording stopped successfully") }
        }
    }

    private func stopAndCleanupEngine() {
        // Cancel any existing timer to prevent duplicate events
        if let timer = chunkTimer {
            timer.cancel()
            chunkTimer = nil
            print("✅ Canceled previous chunk timer")
        }
        // Stop and reset engine (removes taps)
        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            engine.reset()
            print("✅ Stopped and reset AVAudioEngine")
        }
        audioEngine = nil
    }
}
