import Foundation
import AVFoundation
import React

@objc(AudioChunkingModule)
class AudioChunkingModule: RCTEventEmitter {
    
    private var audioEngine: AVAudioEngine?
    private var inputNode: AVAudioInputNode?
    private var isRecording = false
    private var chunkDurationMs: Int = 120000 // 120 seconds default
    private var recordingStartTime: TimeInterval = 0
    private var audioBuffer = Data()
    private var sampleRate: Double = 22050
    
    override init() {
        super.init()
        setupAudioSession()
    }
    
    override func supportedEvents() -> [String]! {
        return ["onChunkReady"]
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
    
    @objc
    func startChunkedRecording(_ chunkDuration: Int, resolver: @escaping RCTPromiseResolveBlock, rejecter: @escaping RCTPromiseRejectBlock) {
        if isRecording {
            rejecter("ALREADY_RECORDING", "Recording is already in progress", nil)
            return
        }
        
        self.chunkDurationMs = chunkDuration
        
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
                self?.processAudioBuffer(buffer)
            }
            
            audioEngine?.prepare()
            try audioEngine?.start()
            
            isRecording = true
            recordingStartTime = CACurrentMediaTime()
            audioBuffer.removeAll()
            
            resolver("Recording started successfully")
        } catch {
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
            createAndSendChunk()
            recordingStartTime = currentTime // Reset for next chunk
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
        
        inputNode?.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        inputNode = nil
        
        // Send final chunk if there's remaining data
        if !audioBuffer.isEmpty {
            createAndSendChunk()
        }
        
        resolver("Recording stopped successfully")
    }
}