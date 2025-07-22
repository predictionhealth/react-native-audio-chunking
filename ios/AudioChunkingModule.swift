import Foundation
import AVFoundation
import React

@objc(AudioChunkingModule)
class AudioChunkingModule: RCTEventEmitter {
    
    private var audioEngine: AVAudioEngine?
    private var inputNode: AVAudioInputNode?
    private var isRecording = false
    private var chunkDurationMs: Int = 10000 // 10 seconds default
    private var recordingStartTime: TimeInterval = 0
    private var audioBuffer = Data()
    private var sampleRate: Double = 22050
    private var chunkCounter = 0
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
        recordingStartTime = 0
        chunkCounter = 0
    }
    
    @objc
    func startChunkedRecording(_ resolver: @escaping RCTPromiseResolveBlock, rejecter: @escaping RCTPromiseRejectBlock) {
        if isRecording {
            rejecter("ALREADY_RECORDING", "Recording is already in progress", nil)
            return
        }
        
        // Reset state before starting new recording
        resetModuleState()
        
        self.chunkDurationMs = 10000 // Static 10 seconds
        
        do {
            audioEngine = AVAudioEngine()
            inputNode = audioEngine?.inputNode
            
            guard let inputNode = inputNode else {
                rejecter("INIT_FAILED", "Failed to get input node", nil)
                return
            }
            
            let recordingFormat = inputNode.outputFormat(forBus: 0)
            sampleRate = recordingFormat.sampleRate
            
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
                self?.processingQueue.async {
                    self?.processAudioBuffer(buffer)
                }
            }
            
            audioEngine?.prepare()
            try audioEngine?.start()
            
            isRecording = true
            recordingStartTime = CACurrentMediaTime()
            audioBuffer.removeAll()
            chunkCounter = 0
            
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
        let elapsedTime = (currentTime - recordingStartTime) * 1000 // Convert to milliseconds
        
        if elapsedTime >= Double(chunkDurationMs) {
            let expectedChunkNumber = Int(elapsedTime / Double(chunkDurationMs))
            
            // Only create chunk if we haven't created this chunk number yet
            if expectedChunkNumber > chunkCounter {
                chunkCounter = expectedChunkNumber
                createAndSendChunk()
                recordingStartTime = currentTime // Reset for next chunk
            }
        }
    }
    
    private func createAndSendChunk() {
        let base64Audio = audioBuffer.base64EncodedString()
        
        let chunkData: [String: Any] = [
            "audioData": base64Audio,
            "format": "pcm",
            "sampleRate": Int(sampleRate),
            "channels": 1,
            "bitsPerSample": 16,
            "chunkNumber": chunkCounter
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
        
        // Stop recording immediately
        isRecording = false
        
        // Remove tap and stop engine
        inputNode?.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        inputNode = nil
        
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
}