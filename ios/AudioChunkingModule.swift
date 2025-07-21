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

        // Clean up any previous session
        stopAndCleanupEngine()
        resetModuleState()

        // Set chunk duration and mark recording
        chunkDurationMs = chunkDuration
        isRecording = true

        // Create a fresh engine
        let engine = AVAudioEngine()
        audioEngine = engine

        // Install tap on main mixer to avoid stacking taps on inputNode
        let mixer = engine.mainMixerNode
        let format = mixer.outputFormat(forBus: 0)
        mixer.removeTap(onBus: 0) // defensive
        mixer.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.processingQueue.async {
                self?.appendBufferData(buffer)
            }
        }
        print("✅ [AudioChunkingModule] Installed tap on main mixer")

        do {
            engine.prepare()
            try engine.start()
            print("✅ [AudioChunkingModule] Started AVAudioEngine")
        } catch {
            stopAndCleanupEngine()
            isRecording = false
            rejecter("START_FAILED", "Failed to start recording: \(error.localizedDescription)", error)
            return
        }

        // Start a repeating timer for chunk intervals
        let timer = DispatchSource.makeTimerSource(queue: processingQueue)
        timer.schedule(deadline: .now() + .milliseconds(chunkDurationMs), repeating: .milliseconds(chunkDurationMs))
        timer.setEventHandler { [weak self] in
            guard let self = self, self.isRecording else { return }
            self.createAndSendChunk()
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
            let int16Sample = Int16(sample * Float(Int16.max))
            withUnsafeBytes(of: int16Sample.littleEndian) { bytes in
                data.append(contentsOf: bytes)
            }
        }
        audioBuffer.append(data)
    }

    private func createAndSendChunk() {
        guard !audioBuffer.isEmpty else { return }
        let base64 = audioBuffer.base64EncodedString()
        let chunk: [String: Any] = [
            "audioData": base64,
            "format": "pcm",
            "sampleRate": Int(sampleRate),
            "channels": 1,
            "bitsPerSample": 16
        ]
        DispatchQueue.main.async {
            self.sendEvent(withName: "onChunkReady", body: chunk)
        }
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
            print("✅ [AudioChunkingModule] Canceled chunk timer")
        }

        // Stop engine and remove tap
        stopAndCleanupEngine()

        // Flush remaining data
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
            engine.mainMixerNode.removeTap(onBus: 0)
            engine.stop()
            engine.reset()
            print("✅ [AudioChunkingModule] Stopped and reset AVAudioEngine")
        }
        audioEngine = nil
    }
}
