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
    private var recordingSessionId: UUID = UUID() // Unique ID for each recording session

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

        // Generate a new session ID for this recording
        let sessionId = UUID()
        recordingSessionId = sessionId
        print("🎤 Starting new recording session: \(sessionId)")

        // Cleanup any previous session
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

        // Ensure no existing tap is present
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self = self, self.isRecording, self.recordingSessionId == sessionId else {
                print("🚫 Dropped buffer for session \(sessionId) - not recording or mismatched session")
                return
            }
            self.processingQueue.async {
                self.appendBufferData(buffer)
            }
        }
        print("✅ Installed tap on inputNode for session: \(sessionId)")

        do {
            engine.prepare()
            try engine.start()
            print("✅ Started AVAudioEngine for session: \(sessionId)")
        } catch {
            stopAndCleanupEngine()
            isRecording = false
            resetModuleState()
            rejecter("START_FAILED", "Failed to start engine: \(error.localizedDescription)", error)
            return
        }

        // Ensure no existing timer is active
        if chunkTimer != nil {
            chunkTimer?.cancel()
            chunkTimer = nil
            print("✅ Canceled stale chunk timer before starting new one for session: \(sessionId)")
        }

        // Schedule repeating chunk timer
        let timer = DispatchSource.makeTimerSource(queue: processingQueue)
        timer.schedule(deadline: .now() + .milliseconds(chunkDurationMs), repeating: .milliseconds(chunkDurationMs))
        timer.setEventHandler { [weak self] in
            guard let self = self, self.isRecording, self.recordingSessionId == sessionId else {
                print("🚫 Timer fired for session \(sessionId) but recording stopped or session mismatched")
                return
            }
            self.createAndSendChunk()
        }
        timer.resume()
        chunkTimer = timer
        print("✅ Started new chunk timer for session: \(sessionId)")

        resolver("Recording started successfully for session: \(sessionId)")
    }

    private func appendBufferData(_ buffer: AVAudioPCMBuffer) {
        guard isRecording else {
            print("🚫 Skipped appending buffer - not recording")
            return
        }
        let frameLen = Int(buffer.frameLength)
        guard let channel = buffer.floatChannelData?[0] else { return }
        var data = Data()
        for i in 0..<frameLen {
            let sample = channel[i]
            let int16 = Int16(sample * Float(Int16.max))
            withUnsafeBytes(of: int16.littleEndian) { data.append(contentsOf: $0) }
        }
        audioBuffer.append(data)
        print("📦 Appended buffer data, total size: \(audioBuffer.count) bytes")
    }

    private func createAndSendChunk() {
        guard !audioBuffer.isEmpty, isRecording else {
            print("🚫 Skipped chunk creation - buffer empty or not recording")
            return
        }
        let b64 = audioBuffer.base64EncodedString()
        let chunk: [String: Any] = [
            "audioData": b64,
            "format": "pcm",
            "sampleRate": Int(sampleRate),
            "channels": 1,
            "bitsPerSample": 16,
            "sessionId": recordingSessionId.uuidString // Include session ID for debugging
        ]
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.isRecording else {
                print("🚫 Skipped sending onChunkReady - not recording")
                return
            }
            print("📤 Sending onChunkReady event for session: \(self.recordingSessionId)")
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

        let sessionId = recordingSessionId
        print("🛑 Stopping recording for session: \(sessionId)")
        isRecording = false

        // Engine + timer cleanup
        stopAndCleanupEngine()

        // Flush any remaining data
        processingQueue.async { [weak self] in
            guard let self = self else { return }
            if !self.audioBuffer.isEmpty {
                self.createAndSendChunk()
            }
            self.resetModuleState()
            DispatchQueue.main.async { resolver("Recording stopped successfully for session: \(sessionId)") }
        }
    }

    private func stopAndCleanupEngine() {
        let sessionId = recordingSessionId
        // Cancel timer to prevent duplicate events
        if let timer = chunkTimer {
            timer.cancel()
            chunkTimer = nil
            print("✅ Canceled chunk timer for session: \(sessionId)")
        }
        // Stop and reset engine
        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            engine.reset()
            print("✅ Stopped and reset AVAudioEngine for session: \(sessionId)")
        }
        audioEngine = nil
        // Reset session ID
        recordingSessionId = UUID()
    }
}