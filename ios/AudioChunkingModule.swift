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

        // Clean up previous session
        stopAndCleanupEngine()
        resetModuleState()

        // Configure chunk duration and state
        chunkDurationMs = chunkDuration
        isRecording = true

        // Initialize a new audio engine
        let engine = AVAudioEngine()
        audioEngine = engine
        let input = engine.inputNode
        let recordingFormat = input.outputFormat(forBus: 0)
        sampleRate = recordingFormat.sampleRate

        // Install tap directly on the input node
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
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

        // Start repeating timer for chunk intervals
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
        let frameLength = Int(buffer.frameLength)
        guard let channelData = buffer.floatChannelData?[0] else { return }
        var data = Data()
        for i in 0..<frameLength {
            let sample = channelData[i]
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

        // Cancel timer
        if let timer = chunkTimer {
            timer.cancel()
            chunkTimer = nil
            print("✅ Canceled timer")
        }

        // Stop engine and remove tap
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
        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            engine.reset()
            print("✅ Stopped and reset engine")
        }
        audioEngine = nil
    }
}
