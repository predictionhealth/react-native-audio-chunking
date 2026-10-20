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

    // Interruption state (e.g. incoming phone call). When an interruption begins the
    // system stops our recorder; we suspend the chunk loop and resume it when the
    // interruption ends rather than letting the chain die silently.
    private var wasInterrupted = false
    // Guards against emitting onLastChunkReady more than once so JS never double-transcribes.
    private var lastChunkEmitted = false
    // The input port the current recorder was created on. An AVAudioRecorder keeps the
    // input format it started with, so when the route moves to another mic mid-chunk
    // (e.g. a Bluetooth headset connects) it records silence until the route comes back.
    private var recorderInputUid: String?

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
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(audioInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
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
        wasInterrupted = false
        lastChunkEmitted = false
    }

    // Emits the terminal onLastChunkReady event at most once per recording session so the
    // JS layer always leaves its "Processing" state, even when the final chunk is missing
    // (e.g. the recorder was already torn down by an interruption).
    private func emitLastChunk(_ payload: [String: Any]) {
        guard !lastChunkEmitted else { return }
        lastChunkEmitted = true
        sendEvent(withName: "onLastChunkReady", body: payload)
    }

    // MARK: - Route Change
    @objc private func routeDidChange(_ notification: Notification) {
        let reasonValue = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 999
        let session = AVAudioSession.sharedInstance()
        let availableInputs = availableInputsList()
        let activeInputs = session.currentRoute.inputs.map { port in
            ["name": port.portName, "uid": port.uid, "portType": port.portType.rawValue]
        }
        sendEvent(withName: "onDebug", body: "[RouteChange] reason=\(reasonValue) preferredInputUid=\(preferredInputUid ?? "nil") isRecording=\(isRecording) available=\(availableInputs.map { $0["name"] ?? "" }) active=\(activeInputs.map { $0["name"] ?? "" })")
        sendEvent(withName: "onAudioRouteChange", body: [
            "inputs": availableInputs,
            "activeInputs": activeInputs,
            "reason": reasonValue
        ])
        DispatchQueue.main.async { self.rollChunkIfInputChanged() }
    }

    // When the active input is no longer the one the recorder was created on, end the
    // chunk early. The delegate emits it as a normal onChunkReady and starts the next
    // chunk, which picks up the new route. Covers both directions: switching onto a
    // Bluetooth mic and falling back to built-in when it disconnects.
    private func rollChunkIfInputChanged() {
        guard isRecording, !wasInterrupted, let recorder = recorder else { return }
        // An empty route is a transient mid-switch state; the next route change carries
        // the new input.
        guard let currentUid = AVAudioSession.sharedInstance().currentRoute.inputs.first?.uid,
              currentUid != recorderInputUid else { return }
        sendEvent(withName: "onDebug", body: "[RouteChange] input changed \(recorderInputUid ?? "nil") -> \(currentUid), rolling chunk=\(chunkCounter)")
        // Set before stopping so a burst of route notifications rolls the chunk only once.
        recorderInputUid = currentUid
        recorder.stop()
    }

    @objc private func audioInterruption(_ notification: Notification) {
        let info = notification.userInfo
        let typeValue = info?[AVAudioSessionInterruptionTypeKey] as? UInt ?? 999
        sendEvent(withName: "onDebug", body: "[Interruption] type=\(typeValue) isRecording=\(isRecording) wasInterrupted=\(wasInterrupted) preferredInputUid=\(preferredInputUid ?? "nil")")

        guard let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

        switch type {
        case .began:
            // The system has paused/stopped our recorder. Suspend the chunk loop so the
            // delegate does NOT auto-advance onto a dead session, and flush whatever audio
            // was captured before the interruption. We resume on .ended.
            guard isRecording, !wasInterrupted else { return }
            wasInterrupted = true
            recorder?.stop()

        case .ended:
            // Re-activate the session and restart the chunk loop so recording continues and
            // the terminal onLastChunkReady will still fire when the user stops.
            guard isRecording, wasInterrupted else { return }
            wasInterrupted = false
            let optionsValue = info?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            do {
                try AVAudioSession.sharedInstance().setActive(true)
                reapplyPreferredInput()
                recordNextChunk()
                sendEvent(withName: "onDebug", body: "[Interruption] resumed recording shouldResume=\(options.contains(.shouldResume))")
            } catch {
                // Leave isRecording true; stopRecording still has a fallback that guarantees
                // JS won't hang in "Processing" even if we can't reactivate here.
                sendEvent(withName: "onDebug", body: "[Interruption] failed to resume: \(error)")
            }

        @unknown default:
            break
        }
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

    @objc(clearPreferredInput:rejecter:)
    func clearPreferredInput(_ resolve: @escaping RCTPromiseResolveBlock,
                             rejecter reject: @escaping RCTPromiseRejectBlock) {
        do {
            try AVAudioSession.sharedInstance().setPreferredInput(nil)
            preferredInputUid = nil
            resolve(nil)
        } catch {
            reject("CLEAR_INPUT_FAILED", error.localizedDescription, error)
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
        wasInterrupted = false
        lastChunkEmitted = false

        AVAudioSession.sharedInstance().requestRecordPermission { granted in
            guard granted else {
                reject("PERMISSION_DENIED", "User denied microphone", nil)
                return
            }
            do {
                try AVAudioSession.sharedInstance().setActive(true)

                // Guard against stale preferred input: the device may have been removed while the
                // session was inactive (iOS doesn't fire oldDeviceUnavailable in that case).
                // If preferredInput is no longer in the active route, clear it so we fall back
                // to built-in, and notify JS so its state catches up before recording starts.
                if let uid = self.preferredInputUid {
                    let session = AVAudioSession.sharedInstance()
                    let activeInputs = session.currentRoute.inputs
                    if !activeInputs.contains(where: { $0.uid == uid }) {
                        self.sendEvent(withName: "onDebug", body: "[StartChunked] preferredInput \(uid) not in active route — clearing to built-in")
                        try? session.setPreferredInput(nil)
                        self.preferredInputUid = nil
                        let availList = self.availableInputsList()
                        let activeList = activeInputs.map { p in
                            ["name": p.portName, "uid": p.uid, "portType": p.portType.rawValue]
                        }
                        self.sendEvent(withName: "onAudioRouteChange", body: [
                            "inputs": availList,
                            "activeInputs": activeList,
                            "reason": 2  // signal to JS: treat as oldDeviceUnavailable
                        ])
                    }
                }

                self.sendEvent(withName: "onDebug", body: "[StartChunked] preferredInputUid=\(self.preferredInputUid ?? "nil")")
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

        if wasInterrupted {
            // The recorder was already torn down by an interruption and will not flush a
            // final chunk, so stop() would never trigger the delegate. Signal completion
            // directly so JS doesn't hang in "Processing" forever.
            wasInterrupted = false
            emitLastChunk([
                "audioData": "",
                "format": "m4a",
                "chunkNumber": chunkCounter,
                "empty": true
            ])
            resolve(nil)
            return
        }

        recorder?.stop()
        resolve(nil)
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
            recorderInputUid = AVAudioSession.sharedInstance().currentRoute.inputs.first?.uid
            // stopRecording runs on another queue. If it landed after the delegate decided to
            // start this chunk, it stopped the previous (finished) recorder, so stop this one
            // now; the delegate then emits it as the last chunk instead of recording on for a
            // full chunk after the user pressed stop.
            if !isRecording {
                recorder?.stop()
            }
        } catch {
            sendEvent(withName: "onDebug", body: "Recorder failed to start: \(error)")
            isRecording = false
        }
    }

    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        sendEvent(withName: "onDebug", body: "[ChunkFinished] flag=\(flag) isRecording=\(isRecording) wasInterrupted=\(wasInterrupted) chunk=\(chunkCounter)")
        guard flag else {
            sendEvent(withName: "onDebug", body: "Chunk encoding failed (flag=false)")
            if !isRecording {
                // Stop was requested but the final chunk failed to encode. Still signal
                // completion so JS doesn't hang in "Processing".
                emitLastChunk([
                    "audioData": "",
                    "format": "m4a",
                    "chunkNumber": chunkCounter,
                    "empty": true
                ])
            } else if !wasInterrupted {
                // Unexpected failure while recording (not an interruption) — keep the loop
                // alive. While interrupted we wait for the .ended handler to restart it.
                recordNextChunk()
            }
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
            if isRecording {
                sendEvent(withName: "onChunkReady", body: payload)
                chunkCounter += 1
                // Don't start the next chunk while interrupted; the .ended handler
                // re-activates the session and restarts the loop.
                if !wasInterrupted {
                    recordNextChunk()
                }
            } else {
                emitLastChunk(payload)
                chunkCounter += 1
            }
        } catch {
            sendEvent(withName: "onDebug", body: "Failed to read chunk file: \(error)")
            if !isRecording {
                // Couldn't read the final chunk file, but Stop was requested — don't leave
                // JS hanging in "Processing".
                emitLastChunk([
                    "audioData": "",
                    "format": "m4a",
                    "chunkNumber": chunkCounter,
                    "empty": true
                ])
            }
        }
    }
}
