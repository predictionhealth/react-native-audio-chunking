import Foundation
import AVFoundation
import React

@objc(AudioChunkingModule)
class AudioChunkingModule: RCTEventEmitter {
    private var audioEngine: AVAudioEngine?
    private var inputNode: AVAudioInputNode?
    private var isRecording = false
    private var chunkDurationMs: Int = 120000 // 120 seconds default
    private var lastChunkTime: TimeInterval = 0
    private var audioBuffer = Data()
    private var sampleRate: Double = 22050
    private let processingQueue = DispatchQueue(label: "audio.processing", qos: .userInitiated)

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
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.record, mode: .default)
            try audioSession.setActive(true)
        } catch {
            print("Failed to setup audio session: \(error)")
        }
    }

    private func resetModuleState() {
        isRecording = false
        audioBuffer.removeAll()
        lastChunkTime = 0
        inputNode = nil
    }

    @objc
    func startChunkedRecording(_ chunkDuration: Int, resolver: @escaping RCTPromiseResolveBlock, rejecter: @escaping RCTPromiseRejectBlock) {
        if isRecording {
            rejecter("ALREADY_RECORDING", "Recording is already in progress", nil)
            return
        }

        // Tear down any previous session
        stopAndCleanupEngine()
        resetModuleState()

        self.chunkDurationMs = chunkDuration

        // Create a fresh engine for this session
        let engine = AVAudioEngine()
        audioEngine = engine

        do {
            let node = engine.inputNode
            let recordingFormat = node.outputFormat(forBus: 0)
            sampleRate = recordingFormat.sampleRate

            node.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
                self?.processingQueue.async {
                    self?.processAudioBuffer(buffer)
                }
            }
            print("✅ [AudioChunkingModule] Installed tap for new recording")

            engine.prepare()
            try engine.start()
            print("✅ [AudioChunkingModule] Started AVAudioEngine")

            self.inputNode = node
            isRecording = true
            lastChunkTime = CACurrentMediaTime()
            audioBuffer.removeAll()

            resolver("Recording started successfully")
        } catch {
            resetModuleState()
            rejecter("START_FAILED", "Failed to start recording: \(error.localizedDescription)", error)
        }
    }

    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard isRecording else { return }

        // Convert buffer to Data
        let frameLength = Int(buffer.frameLength)
        let channelData = buffer.floatChannelData?[0]

        var audioData = Data()
        for i in 0..<frameLength {
            let sample = channelData?[i] ?? 0.0
            let int16Sample = Int16(sample * Float(Int16.max))
            withUnsafeBytes(of: int16Sample.littleEndian) { bytes in
                audioData.append(contentsOf: bytes)
            }
        }

        audioBuffer.append(audioData)

        // Check if it's time to create a chunk
        let currentTime = CACurrentMediaTime()
        let elapsedSinceLastChunk = (currentTime - lastChunkTime) * 1000 // ms

        if elapsedSinceLastChunk >= Double(chunkDurationMs) {
            createAndSendChunk()
            lastChunkTime = currentTime
        }
    }

    private func createAndSendChunk() {
        let base64Audio = audioBuffer.base64EncodedString()

        let chunkData: [String: Any] = [
            "audioData": base64Audio,
            "format": "pcm",
            "sampleRate": Int(sampleRate),
            "channels": 1,
            "bitsPerSample": 16
        ]

        sendEvent(withName: "onChunkReady", body: chunkData)
        // Clear buffer for next chunk
        audioBuffer.removeAll()
    }

    @objc
    func stopRecording(_ resolver: @escaping RCTPromiseResolveBlock, rejecter: @escaping RCTPromiseRejectBlock) {
        if !isRecording {
            rejecter("NOT_RECORDING", "No recording in progress", nil)
            return
        }

        isRecording = false

        // Stop & reset the engine immediately
        stopAndCleanupEngine()

        // Flush any remaining data and resolve
        processingQueue.async { [weak self] in
            guard let self = self else { return }

            if !self.audioBuffer.isEmpty {
                self.createAndSendChunk()
            }

            self.resetModuleState()

            DispatchQueue.main.async {
                resolver("Recording stopped successfully")
            }
        }
    }

    private func stopAndCleanupEngine() {
        if let engine = audioEngine {
            inputNode?.removeTap(onBus: 0)
            engine.stop()
            engine.reset()      // <- fully clears out any taps/internal state
            print("✅ [AudioChunkingModule] Stopped and reset AVAudioEngine")
        }
        inputNode = nil
        audioEngine = nil
    }
}
