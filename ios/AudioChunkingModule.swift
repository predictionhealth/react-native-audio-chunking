// AudioChunkingModule.swift
import Foundation
import AVFoundation
import React  // Import React Native bridge

@objc(AudioChunkingModule)
class AudioChunkingModule: RCTEventEmitter, AVAudioRecorderDelegate {
    private var recorder: AVAudioRecorder?
    private var isRecording = false
    private var chunkIndex = 0
    private let chunkDuration: TimeInterval = 10.0

    @objc
    override static func requiresMainQueueSetup() -> Bool {
        return false
    }

    @objc
    func startChunkedRecording() {
        guard !isRecording else { return }
        isRecording = true
        chunkIndex = 0
        AVAudioSession.sharedInstance().requestRecordPermission { granted in
            guard granted else {
                print("Microphone permission denied")
                return
            }
            do {
                try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .default)
                try AVAudioSession.sharedInstance().setActive(true)
                self.recordNextChunk()
            } catch {
                print("Failed to set up audio session: \(error)")
            }
        }
    }

    private func recordNextChunk() {
        let filename = "chunk_\(chunkIndex).m4a"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        do {
            recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder?.delegate = self
            recorder?.record(forDuration: chunkDuration)
        } catch {
            print("Failed to start recorder: \(error)")
        }
    }

    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        if flag {
            let urlString = recorder.url.absoluteString
            sendEvent(withName: "onChunkReady", body: ["uri": urlString, "index": chunkIndex])
            chunkIndex += 1
            if isRecording {
                recordNextChunk()
            }
        } else {
            print("Recording chunk failed")
        }
    }

    @objc
    func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        recorder?.stop()
        do {
            try AVAudioSession.sharedInstance().setActive(false)
        } catch {
            print("Failed to deactivate audio session: \(error)")
        }
    }

    // MARK: - RCTEventEmitter
    @objc
    override func supportedEvents() -> [String]! {
        return ["onChunkReady"]
    }

    @objc
    override func constantsToExport() -> [AnyHashable: Any]! {
        return [:]
    }
}