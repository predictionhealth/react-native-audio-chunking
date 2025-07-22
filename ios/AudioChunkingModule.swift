```swift
// AudioChunkingModule.swift

import Foundation
import AVFoundation
import React

@objc(AudioChunkingModule)
class AudioChunkingModule: RCTEventEmitter, AVAudioRecorderDelegate {
  private var recorder: AVAudioRecorder?
  private var isRecording = false
  private var chunkIndex = 0
  private let chunkDuration: TimeInterval = 10.0

  // MARK: - RCTEventEmitter boilerplate

  @objc
  override static func requiresMainQueueSetup() -> Bool {
    return false
  }

  @objc
  override func supportedEvents() -> [String]! {
    return ["onChunkReady"]
  }

  @objc
  override func constantsToExport() -> [AnyHashable: Any]! {
    return [:]
  }

  // MARK: - Public methods

  @objc(startChunkedRecording:rejecter:)
  func startChunkedRecording(_ resolve: @escaping RCTPromiseResolveBlock,
                             rejecter reject: @escaping RCTPromiseRejectBlock) {
    guard !isRecording else {
      resolve(nil)
      return
    }
    chunkIndex = 0
    isRecording = true

    AVAudioSession.sharedInstance().requestRecordPermission { granted in
      guard granted else {
        reject("PERMISSION_DENIED", "User denied microphone access", nil)
        return
      }
      do {
        try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .default)
        try AVAudioSession.sharedInstance().setActive(true)

        self.recordNextChunk()
        DispatchQueue.main.async { resolve(nil) }
      } catch {
        self.isRecording = false
        reject("AUDIO_SETUP_FAILED", error.localizedDescription, error)
      }
    }
  }

  @objc(stopRecording:rejecter:)
  func stopRecording(_ resolve: @escaping RCTPromiseResolveBlock,
                     rejecter reject: @escaping RCTPromiseRejectBlock) {
    guard isRecording else {
      resolve(nil)
      return
    }
    isRecording = false
    recorder?.stop()
    do {
      try AVAudioSession.sharedInstance().setActive(false)
      resolve(nil)
    } catch {
      reject("AUDIO_TEARDOWN_FAILED", error.localizedDescription, error)
    }
  }

  // MARK: - Internal chunking logic

  private func recordNextChunk() {
    let fileName = "chunk_\(chunkIndex).m4a"
    let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)

    let settings: [String: Any] = [
      AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
      AVSampleRateKey: 44_100,
      AVNumberOfChannelsKey: 1,
      AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
    ]

    do {
      recorder = try AVAudioRecorder(url: fileURL, settings: settings)
      recorder?.delegate = self
      recorder?.record(forDuration: chunkDuration)
    } catch {
      print("Failed to start chunk recorder:", error)
      isRecording = false
    }
  }

  // Called when each chunk finishes
  func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
    guard flag else {
      print("Chunk recording failed")
      return
    }
    let url = recorder.url
    do {
      let data = try Data(contentsOf: url)
      let b64  = data.base64EncodedString()
      sendEvent(withName: "onChunkReady", body: [
        "base64": b64,
        "chunkNumber": chunkIndex
      ])
      chunkIndex += 1
      if isRecording {
        recordNextChunk()
      }
    } catch {
      print("Failed to read chunk file:", error)
    }
  }
}
