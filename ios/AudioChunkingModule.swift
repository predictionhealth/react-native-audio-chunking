import Foundation
import AVFoundation
import React

@objc(AudioChunkingModule)
class AudioChunkingModule: RCTEventEmitter {
    private var audioEngine: AVAudioEngine?
    private var inputNode: AVAudioInputNode?
    private var isRecording = false
    private var chunkDurationMs: Int = 120000 // default 120 seconds
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
        isRecording = false
        audioBuffer.removeAll()
        sampleRate = 22050
    }

    @objc
    func startChunkedRecording(_ chunkDuration: Int, resolver: @escaping RCTPromiseResolveBlock, rejecter: @escaping RCTPromiseRejectBlock) {
        if isRecording {
            rejecter("ALREADY_RECORDING", "Recording is already in progress", nil)
            return
        }

        // Stop any existing session and clear state
        stopAndCleanupEngine()
        resetModuleState()

        chunkDurationMs = chunkDuration

        // Initialize a new audio engine
        let engine = AVAudioEngine()
        audioEngine = engine
        let node = engine.inputNode
        let recordingFormat = node.outputFormat(forBus: 0)
        sampleRate = recordingFormat.sampleRate

        node.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            self?.processingQueue.async {
                self?.appendBufferData(buffer)
            }
        }
        print("✅ [AudioChunkingModule] Installed tap for new recording")

        engine.prepare()
        do {
            try engine.start()
            print("✅ [AudioChunkingModule] Started AVAudioEngine")
        } catch {
            resetModuleState()
            rejecter("START_FAILED", "Failed to start recording: \(error.localizedDescription)", error)
            return
        }

        // Schedule periodic chunk creation
        let timer = DispatchSource.makeTimerSource(queue: processingQueue)
        timer.schedule(deadline: .now() + .milliseconds(chunkDurationMs), repeating: .milliseconds(chunkDurationMs))
        timer.setEventHandler { [weak self] in
            self?.createAndSendChunk()
        }
        timer.resume()
        chunkTimer = timer

        inputNode = node
        isRecording = true

        resolver("Recording started successfully")
    }

    private func appendBufferData(_ buffer: AVAudioPCMBuffer) {
        guard isRecording else { return }
        let frameLength = Int(buffer.frameLength)
        guard let channelData = buffer.floatChannelData?[0] else { return }
        var audioData = Data()
        for i in 0..<frameLength {
            let sample = channelData[i]
            let int16Sample = Int16(sample * Float(Int16.max))
            withUnsafeBytes(of: int16Sample.littleEndian) { bytes in
                audioData.append(contentsOf: bytes)
            }
        }
        audioBuffer.append(audioData)
    }

    private func createAndSendChunk() {
        guard !audioBuffer.isEmpty else { return }
        let base64Audio = audioBuffer.base64EncodedString()
        let chunkData: [String: Any] = [
            "audioData": base64Audio,
            "format": "pcm",
            "sampleRate": Int(sampleRate),
            "channels": 1,
            "bitsPerSample": 16
        ]
        sendEvent(withName: "onChunkReady", body: chunkData)
        audioBuffer.removeAll()
    }

    @objc
    func stopRecording(_ resolver: @escaping RCTPromiseResolveBlock, rejecter: @escaping RCTPromiseRejectBlock) {
        if !isRecording {
            rejecter("NOT_RECORDING", "No recording in progress", nil)
            return
        }

        isRecording = false

        // Cancel the timer
        chunkTimer?.cancel()
        chunkTimer = nil

        // Stop and reset the engine
        stopAndCleanupEngine()

        // Flush any remaining audio data
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
            engine.reset()
            print("✅ [AudioChunkingModule] Stopped and reset AVAudioEngine")
        }
        inputNode = nil
        audioEngine = nil
    }
}
