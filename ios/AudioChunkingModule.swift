import Foundation
import AVFoundation
import React

@objc(AudioChunkingModule)
class AudioChunkingModule: RCTEventEmitter, AVAudioRecorderDelegate {
    // MARK: - Properties
    private var recorder: AVAudioRecorder?
    private var isRecording = false
    private var chunkCounter = 0
    private let chunkDurationMs: Int = 120000
    private var sampleRate: Double = 22050

    // Legacy properties (unused with recorder approach)
    private var audioEngine: AVAudioEngine?
    private var inputNode: AVAudioInputNode?
    private var recordingStartTime: TimeInterval = 0
    private var audioBuffer = Data()
    private let processingQueue = DispatchQueue(label: "audio.processing", qos: .userInitiated)
    private var preferredInputUid: String?

    // MARK: - RCTEventEmitter
    @objc
    override static func requiresMainQueueSetup() -> Bool {
        return false
    }

    @objc
    override func supportedEvents() -> [String]! {
        return ["onChunkReady", "onLastChunkReady", "onDebug", "onAudioRouteChange"]
    }

    @objc
    override func constantsToExport() -> [AnyHashable: Any]! {
        return [:]
    }

    // MARK: - Session Setup
    override init() {
        super.init()
        setupAudioSession()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(routeDidChange(_:)),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func setupAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetooth])
            try session.setActive(true)
        } catch {
            sendEvent(withName: "onDebug", body: "Failed to setup audio session: \(error)")
        }
    }

    private func resetModuleState() {
        isRecording = false
        chunkCounter = 0
    }

    // MARK: - Route Change
    @objc private func routeDidChange(_ notification: Notification) {
        let inputs = availableInputsList()
        sendEvent(withName: "onAudioRouteChange", body: ["inputs": inputs])
    }

    private func availableInputsList() -> [[String: String]] {
        let session = AVAudioSession.sharedInstance()
        return (session.availableInputs ?? []).map { port in
            [
                "name": port.portName,
                "uid": port.uid,
                "portType": port.portType.rawValue
            ]
        }
    }

    // MARK: - Input Selection
    @objc(getAvailableInputs:rejecter:)
    func getAvailableInputs(_ resolve: @escaping RCTPromiseResolveBlock,
                            rejecter reject: @escaping RCTPromiseRejectBlock) {
        resolve(availableInputsList())
    }

    @objc(setPreferredInput:resolver:rejecter:)
    func setPreferredInput(_ uid: String,
                           resolver resolve: @escaping RCTPromiseResolveBlock,
                           rejecter reject: @escaping RCTPromiseRejectBlock) {
        let session = AVAudioSession.sharedInstance()
        guard let port = session.availableInputs?.first(where: { $0.uid == uid }) else {
            reject("INPUT_NOT_FOUND", "No input with uid \(uid)", nil)
            return
        }
        do {
            try session.setPreferredInput(port)
            preferredInputUid = uid
            resolve(nil)
        } catch {
            reject("SET_INPUT_FAILED", error.localizedDescription, error)
        }
    }

    private func reapplyPreferredInput() {
        guard let uid = preferredInputUid else { return }
        let session = AVAudioSession.sharedInstance()
        guard let port = session.availableInputs?.first(where: { $0.uid == uid }) else { return }
        try? session.setPreferredInput(port)
    }

    // MARK: - Recording Control
    @objc(startChunkedRecording:rejecter:)
    func startChunkedRecording(_ resolve: @escaping RCTPromiseResolveBlock,
                               rejecter reject: @escaping RCTPromiseRejectBlock) {
        guard !isRecording else {
            resolve(nil)
            return
        }
        isRecording = true
        chunkCounter = 0

        AVAudioSession.sharedInstance().requestRecordPermission { granted in
            guard granted else {
                reject("PERMISSION_DENIED", "User denied microphone", nil)
                return
            }
            do {
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

    // MARK: - Chunking Logic via AVAudioRecorder
    private func recordNextChunk() {
        let fileName = "chunk_\(chunkCounter).m4a"
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: fileURL)

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        do {
            recorder = try AVAudioRecorder(url: fileURL, settings: settings)
            recorder?.delegate = self
            recorder?.record(forDuration: TimeInterval(chunkDurationMs) / 1000.0)
        } catch {
            sendEvent(withName: "onDebug", body: "Recorder failed to start: \(error)")
            isRecording = false
        }
    }

    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        guard flag else {
            sendEvent(withName: "onDebug", body: "Chunk encoding failed")
            return
        }
        do {
            let data = try Data(contentsOf: recorder.url)
            let base64String = data.base64EncodedString()
            let payload: [String: Any] = [
                "audioData": base64String,
                "format": "m4a",
                "sampleRate": Int(sampleRate),
                "channels": 1,
                "bitsPerSample": 16,
                "chunkNumber": chunkCounter
            ]
            let eventName = isRecording ? "onChunkReady" : "onLastChunkReady"
            sendEvent(withName: eventName, body: payload)
            chunkCounter += 1
            if isRecording {
                recordNextChunk()
            }
        } catch {
            sendEvent(withName: "onDebug", body: "Failed to read chunk file: \(error)")
        }
    }
}
