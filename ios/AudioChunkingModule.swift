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
    private var sessionId: String?
    private let processingQueue = DispatchQueue(label: "audio.processing", qos: .userInitiated)
    private let startQueue = DispatchQueue(label: "audio.start", qos: .userInitiated)
    private var chunkTimer: DispatchSourceTimer?

    override init() {
        super.init()
        setupAudioSession()
    }

    override func supportedEvents() -> [String]! {
        return ["onChunkReady", "onDebugLog"]
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
            sendDebugLog("Audio session set up successfully")
        } catch {
            sendDebugLog("Failed to setup audio session: \(error)")
        }
    }

    private func resetModuleState() {
        audioBuffer.removeAll()
        sampleRate = 22050
        sessionId = nil
        sendDebugLog("Reset module state")
    }

    private func sendDebugLog(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            self?.sendEvent(withName: "onDebugLog", body: ["message": message])
        }
    }

    @objc
    func startChunkedRecording(_ chunkDuration: Int, sessionId: String?, resolver: @escaping RCTPromiseResolveBlock, rejecter: @escaping RCTPromiseRejectBlock) {
        startQueue.async { [weak self] in
            guard let self = self else {
                self?.sendDebugLog("Module deallocated during start")
                rejecter("MODULE_DEALLOCATED", "Module unavailable", nil)
                return
            }
            guard !self.isRecording else {
                self.sendDebugLog("Rejected start attempt: Recording already in progress")
                rejecter("ALREADY_RECORDING", "Recording already in progress", nil)
                return
            }

            // Cleanup any previous session
            self.stopAndCleanupEngine()
            self.resetModuleState()

            // Configure
            self.chunkDurationMs = chunkDuration
            self.sessionId = sessionId
            self.isRecording = true
            self.sendDebugLog("Starting recording with chunk duration: \(chunkDuration)ms, sessionId: \(sessionId ?? "none")")

            // Initialize new engine and tap
            let engine = AVAudioEngine()
            self.audioEngine = engine
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            self.sampleRate = format.sampleRate
            self.sendDebugLog("Audio engine initialized with sample rate: \(self.sampleRate)")

            // Ensure no existing tap is present
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                guard let self = self, self.isRecording else {
                    self?.sendDebugLog("Dropped buffer - not recording")
                    return
                }
                self.processingQueue.async {
                    self.appendBufferData(buffer)
                }
            }
            self.sendDebugLog("Installed tap on inputNode")

            do {
                engine.prepare()
                try engine.start()
                self.sendDebugLog("Started AVAudioEngine")
            } catch {
                self.stopAndCleanupEngine()
                self.isRecording = false
                self.resetModuleState()
                rejecter("START_FAILED", "Failed to start engine: \(error.localizedDescription)", error)
                return
            }

            // Ensure no existing timer is active
            if self.chunkTimer != nil {
                self.chunkTimer?.cancel()
                self.chunkTimer = nil
                self.sendDebugLog("Canceled stale chunk timer")
            }

            // Schedule repeating chunk timer
            let timer = DispatchSource.makeTimerSource(queue: self.processingQueue)
            timer.schedule(deadline: .now() + .milliseconds(chunkDuration), repeating: .milliseconds(chunkDuration))
            timer.setEventHandler { [weak self] in
                guard let self = self, self.isRecording else {
                    self?.sendDebugLog("Timer fired but not recording, skipping chunk creation")
                    return
                }
                self.createAndSendChunk()
            }
            timer.resume()
            self.chunkTimer = timer
            self.sendDebugLog("Started new chunk timer")

            resolver("Recording started successfully")
        }
    }

    private func appendBufferData(_ buffer: AVAudioPCMBuffer) {
        guard isRecording else {
            sendDebugLog("Skipped appending buffer - not recording")
            return
        }
        let frameLen = Int(buffer.frameLength)
        guard let channel = buffer.floatChannelData?[0] else {
            sendDebugLog("No channel data in buffer")
            return
        }
        var data = Data()
        for i in 0..<frameLen {
            let sample = channel[i]
            let int16 = Int16(sample * Float(Int16.max))
            withUnsafeBytes(of: int16.littleEndian) { bytes in
                data.append(bytes.baseAddress!, count: MemoryLayout<Int16>.size)
            }
        }
        audioBuffer.append(data)
        sendDebugLog("Appended buffer data, total size: \(audioBuffer.count) bytes")
    }

    private func createAndSendChunk() {
        guard isRecording else {
            sendDebugLog("Skipped chunk creation - not recording")
            return
        }
        guard !audioBuffer.isEmpty else {
            sendDebugLog("Skipped chunk creation - buffer empty")
            return
        }
        let b64 = audioBuffer.base64EncodedString()
        let chunk: [String: Any] = [
            "audioData": b64,
            "format": "pcm",
            "sampleRate": Int(sampleRate),
            "channels": 1,
            "bitsPerSample": 16,
            "sessionId": sessionId ?? ""
        ]
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.isRecording else {
                self?.sendDebugLog("Skipped sending onChunkReady - not recording")
                return
            }
            self.sendDebugLog("Sending onChunkReady event with sessionId: \(self.sessionId ?? "none")")
            self.sendEvent(withName: "onChunkReady", body: chunk)
        }
        audioBuffer.removeAll()
    }

    @objc
    func stopRecording(_ resolver: @escaping RCTPromiseResolveBlock, rejecter: @escaping RCTPromiseRejectBlock) {
        guard isRecording else {
            sendDebugLog("No recording in progress")
            rejecter("NOT_RECORDING", "No recording in progress", nil)
            return
        }

        isRecording = false
        sendDebugLog("Stopping recording")

        // Engine + timer cleanup
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
        // Cancel timer to prevent duplicate events
        if let timer = chunkTimer {
            timer.cancel()
            chunkTimer = nil
            sendDebugLog("Canceled chunk timer")
        }
        // Stop and reset engine
        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            engine.reset()
            sendDebugLog("Stopped and reset AVAudioEngine")
        }
        audioEngine = nil
    }
}