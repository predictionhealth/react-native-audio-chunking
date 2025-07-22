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
            chunkCounter += 1
            createAndSendChunk()
            recordingStartTime = currentTime // Reset for next chunk
        }
    }
    
    private func createAndSendChunk() {
        // 1) Build a temp URL for an M4A file
        let fileName = "chunk_\(chunkCounter).m4a"
        let fileURL  = FileManager.default.temporaryDirectory
                            .appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: fileURL)

        // 2) Set up AAC / M4A export settings
        let exportSettings: [String: Any] = [
            AVFormatIDKey:           Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey:         sampleRate,
            AVNumberOfChannelsKey:   1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        do {
            // 3) Create an AVAudioFile for writing
            let outFile = try AVAudioFile(forWriting: fileURL,
                                        settings: exportSettings)

            // 4) Turn your Data(buffered PCM Int16) into a PCM buffer
            let frames    = AVAudioFrameCount(audioBuffer.count / MemoryLayout<Int16>.size)
            guard let fmt  = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                        sampleRate: sampleRate,
                                        channels: 1,
                                        interleaved: true),
                let pcmBuf = AVAudioPCMBuffer(pcmFormat: fmt,
                                                frameCapacity: frames) else {
            print("⚠️ Unable to create PCM buffer")
            return
            }
            pcmBuf.frameLength = frames

            // 5) Copy your raw bytes into the PCM buffer
            let dst = pcmBuf.int16ChannelData![0]
            audioBuffer.withUnsafeBytes { src in
            let samples = src.bindMemory(to: Int16.self)
            for i in 0..<Int(frames) {
                dst[i] = samples[i]
            }
            }

            // 6) Write the buffer into the .m4a file
            try outFile.write(from: pcmBuf)

            // 7) Read it back & Base64-encode
            let m4aData      = try Data(contentsOf: fileURL)
            let base64String = m4aData.base64EncodedString()

            // 8) Emit with “format” now set to “m4a”
            let payload: [String:Any] = [
            "audioData":    base64String,
            "format":       "m4a",
            "sampleRate":   Int(sampleRate),
            "channels":     1,
            "bitsPerSample":16,
            "chunkNumber":  chunkCounter
            ]
            sendEvent(withName: "onChunkReady", body: payload)
        }
        catch {
            print("❌ M4A export failed:", error)
        }

        // 9) Clear your PCM buffer for the next chunk
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