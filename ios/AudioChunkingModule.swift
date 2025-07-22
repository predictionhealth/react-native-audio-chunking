import Foundation
import AVFoundation
import React

@objc(AudioChunkingModule)
class AudioChunkingModule: RCTEventEmitter {
    
    private let audioEngine = AVAudioEngine()
    private var inputNode: AVAudioInputNode?
    private var isRecording = false
    private var chunkDurationMs: Int = 10000 // 10 seconds default
    private var lastChunkTime: TimeInterval = 0
    private var audioBuffer = Data()
    private var sampleRate: Double = 22050
    private let processingQueue = DispatchQueue(label: "audio.processing", qos: .userInitiated)
    
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
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.record, mode: .default)
            try audioSession.setActive(true)
        } catch {
            self.sendDebugLog("Failed to setup audio session: \(error)")
        }
    }
    
    private func resetModuleState() {
        isRecording = false
        audioBuffer.removeAll()
        lastChunkTime = 0
        inputNode = nil
    }

    private func sendDebugLog(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            self?.sendEvent(withName: "onDebugLog", body: ["message": message])
        }
    }
    
    @objc
    func startChunkedRecording(_ chunkDuration: Int, resolver: @escaping RCTPromiseResolveBlock, rejecter: @escaping RCTPromiseRejectBlock) {
        if isRecording {
            rejecter("ALREADY_RECORDING", "Recording is already in progress", nil)
            return
        }
        
        // Defensive: Always stop and remove tap before starting
        stopAndCleanupEngine()
        
        // Reset state before starting new recording
        resetModuleState()
        
        self.chunkDurationMs = chunkDuration
        
        do {
            let node = audioEngine.inputNode
            let recordingFormat = node.outputFormat(forBus: 0)
            sampleRate = recordingFormat.sampleRate
            
            // Remove any existing tap (shouldn't be needed, but for safety)
            node.removeTap(onBus: 0)
            self.sendDebugLog("✅ [AudioChunkingModule] Removed tap before starting new recording")
            
            node.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
                self?.processingQueue.async {
                    self?.processAudioBuffer(buffer)
                }
            }
            self.sendDebugLog("✅ [AudioChunkingModule] Installed tap for new recording")
            
            audioEngine.prepare()
            try audioEngine.start()
            self.sendDebugLog("✅ [AudioChunkingModule] Started AVAudioEngine")
            
            self.inputNode = node
            isRecording = true
            lastChunkTime = CACurrentMediaTime()
            audioBuffer.removeAll()
            
            resolver("Recording started successfully")
        } catch {
            // Reset flags on error
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
        
        // Remove tap and stop engine
        stopAndCleanupEngine()
        
        // Wait for any pending processing to complete, then send final chunk
        processingQueue.async { [weak self] in
            guard let self = self else { return }
            
            // Send final chunk if there's remaining data
            if !self.audioBuffer.isEmpty {
                self.createAndSendChunk()
            }
            
            // Reset all state
            self.resetModuleState()
            
            DispatchQueue.main.async {
                resolver("Recording stopped successfully")
            }
        }
    }
    
    private func stopAndCleanupEngine() {
        if let node = inputNode {
            node.removeTap(onBus: 0)
            self.sendDebugLog("✅ [AudioChunkingModule] Removed tap from inputNode (stopAndCleanupEngine)")
        }
        audioEngine.inputNode.removeTap(onBus: 0)
        self.sendDebugLog("✅ [AudioChunkingModule] Removed tap from audioEngine.inputNode (stopAndCleanupEngine)")
        audioEngine.stop()
        self.sendDebugLog("✅ [AudioChunkingModule] Stopped AVAudioEngine (stopAndCleanupEngine)")
        inputNode = nil
    }
}