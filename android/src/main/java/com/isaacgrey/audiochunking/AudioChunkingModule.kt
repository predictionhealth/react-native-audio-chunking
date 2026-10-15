package com.isaacgrey.audiochunking

import android.Manifest
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.AudioDeviceCallback
import android.media.AudioFocusRequest
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.media.AudioDeviceInfo
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaMuxer
import android.media.MediaRecorder
import android.os.Build
import android.util.Base64
import androidx.core.app.ActivityCompat
import com.facebook.react.bridge.*
import com.facebook.react.modules.core.DeviceEventManagerModule
import java.io.File
import java.util.*
import java.util.concurrent.atomic.AtomicBoolean

class AudioChunkingModule(reactContext: ReactApplicationContext) :
    ReactContextBaseJavaModule(reactContext), LifecycleEventListener {

    companion object {
        const val NAME = "AudioChunkingModule"
        private const val CHUNK_DURATION_MS = 120000L
        private const val SAMPLE_RATE = 44100
        private const val BIT_RATE = 128000
        private const val BT_SCO_CONNECT_TIMEOUT_MS = 5000L
    }

    private var audioRecord: AudioRecord? = null
    private var mediaCodec: MediaCodec? = null
    private var mediaMuxer: MediaMuxer? = null
    private var muxerTrackIndex = -1
    private var recordingThread: Thread? = null
    private var chunkTimer: Timer? = null
    private var currentChunkFile: File? = null
    private var isRecording = false
    @Volatile private var stopChunkRequested = false
    private var chunkCounter = 0
    private var selectedDeviceId: Int? = null
    private var bluetoothScoStarted = false
    private var scoReceiver: BroadcastReceiver? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    // Interruption state (e.g. incoming phone call, signalled on Android via audio
    // focus loss). When interrupted we flush the in-progress chunk and suspend the
    // loop, then resume on focus gain rather than letting it die or record silence.
    @Volatile private var wasInterrupted = false
    // Guards against emitting onLastChunkReady more than once so JS never double-transcribes.
    @Volatile private var lastChunkEmitted = false
    // Serializes chunk transitions across the native-modules thread, the chunk Timer
    // thread, and the audio-focus handler thread so they can't tear down / spin up the
    // recorder concurrently.
    private val chunkLock = Any()
    private var audioFocusRequest: AudioFocusRequest? = null
    // Focus callbacks run here (not the UI thread) because handling one can join the
    // recording thread for up to 5s, which would risk an ANR on the main thread.
    private val focusHandlerThread = HandlerThread("audio-chunking-focus").also { it.start() }
    private val focusHandler = Handler(focusHandlerThread.looper)
    private val audioFocusListener = AudioManager.OnAudioFocusChangeListener { focusChange ->
        focusHandler.post { handleAudioFocusChange(focusChange) }
    }

    private val audioDeviceCallback = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
        object : AudioDeviceCallback() {
            override fun onAudioDevicesAdded(addedDevices: Array<out AudioDeviceInfo>) {
                sendDebugEvent("AudioDeviceCallback: devices added: ${addedDevices.joinToString { "${it.productName}(${audioDeviceTypeToString(it.type)})" }}")
                sendRouteChangeEvent(reason = 1)
            }
            override fun onAudioDevicesRemoved(removedDevices: Array<out AudioDeviceInfo>) {
                sendDebugEvent("AudioDeviceCallback: devices removed: ${removedDevices.joinToString { "${it.productName}(${audioDeviceTypeToString(it.type)})" }}")
                // reason=2 signals oldDeviceUnavailable to JS so it can fall back to built-in
                // even when nothing takes the removed device's place.
                sendRouteChangeEvent(reason = 2)
            }
        }
    } else null

    override fun getName(): String = NAME

    override fun initialize() {
        super.initialize()
        reactApplicationContext.addLifecycleEventListener(this)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            val audioManager = reactApplicationContext.getSystemService(Context.AUDIO_SERVICE) as AudioManager
            audioManager.registerAudioDeviceCallback(audioDeviceCallback, Handler(Looper.getMainLooper()))
        }
    }

    override fun onHostResume() {}
    override fun onHostPause() {}

    override fun onHostDestroy() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            val audioManager = reactApplicationContext.getSystemService(Context.AUDIO_SERVICE) as AudioManager
            audioManager.unregisterAudioDeviceCallback(audioDeviceCallback)
        }
        if (isRecording) {
            isRecording = false
            wasInterrupted = false
            chunkTimer?.cancel()
            chunkTimer = null
            stopChunkRequested = true
            try { audioRecord?.stop() } catch (_: Exception) {}
            recordingThread?.join(3000)
            recordingThread = null
            releaseRecordingResources()
            stopBluetoothScoIfStarted()
            unregisterScoReceiver()
            abandonAudioFocus()
        }
    }

    @ReactMethod
    fun getAvailableInputs(promise: Promise) {
        promise.resolve(buildInputsList())
    }

    private fun buildInputsList(): WritableArray {
        val result = Arguments.createArray()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            val audioManager = reactApplicationContext.getSystemService(Context.AUDIO_SERVICE) as AudioManager
            for (device in audioManager.getDevices(AudioManager.GET_DEVICES_INPUTS)) {
                result.pushMap(Arguments.createMap().apply {
                    putString("name", device.productName.toString())
                    putString("uid", device.id.toString())
                    putString("portType", audioDeviceTypeToString(device.type))
                })
            }
        }
        return result
    }

    // The input devices currently connected/available. On Android getDevices(GET_DEVICES_INPUTS)
    // only returns devices that are actually present, so "available" is effectively the active
    // route — the close analogue of iOS's AVAudioSession.currentRoute.inputs. Keeping any
    // connected mic (built-in, wired, USB, or Bluetooth) selected and only falling back to
    // built-in when a device is unplugged is what matches iOS: whatever mic the user is on
    // stays in use (and is resumed after a phone call).
    private fun activeInputDevices(): List<AudioDeviceInfo> {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return emptyList()
        val audioManager = reactApplicationContext.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        return audioManager.getDevices(AudioManager.GET_DEVICES_INPUTS).toList()
    }

    private fun buildActiveInputsList(): WritableArray {
        val result = Arguments.createArray()
        for (device in activeInputDevices()) {
            result.pushMap(Arguments.createMap().apply {
                putString("name", device.productName.toString())
                putString("uid", device.id.toString())
                putString("portType", audioDeviceTypeToString(device.type))
            })
        }
        return result
    }

    private fun sendRouteChangeEvent(reason: Int) {
        val payload = Arguments.createMap().apply {
            putArray("inputs", buildInputsList())
            putArray("activeInputs", buildActiveInputsList())
            putInt("reason", reason)
        }
        sendEvent("onAudioRouteChange", payload)
    }

    private fun audioDeviceTypeToString(type: Int): String {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return "Unknown"
        return when (type) {
            AudioDeviceInfo.TYPE_BLUETOOTH_SCO -> "BluetoothSCO"
            AudioDeviceInfo.TYPE_BLUETOOTH_A2DP -> "BluetoothA2DP"
            AudioDeviceInfo.TYPE_BUILTIN_MIC -> "BuiltInMic"
            AudioDeviceInfo.TYPE_WIRED_HEADSET -> "WiredHeadset"
            AudioDeviceInfo.TYPE_USB_DEVICE -> "USBDevice"
            else -> "Unknown"
        }
    }

    @ReactMethod
    fun setPreferredInput(uid: String, promise: Promise) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            promise.reject("UNSUPPORTED", "Requires API 23+")
            return
        }
        val deviceId = uid.toIntOrNull()
        if (deviceId == null) {
            promise.reject("INVALID_UID", "uid must be a numeric string")
            return
        }
        val audioManager = reactApplicationContext.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val device = audioManager.getDevices(AudioManager.GET_DEVICES_INPUTS).firstOrNull { it.id == deviceId }
        if (device == null) {
            promise.reject("INPUT_NOT_FOUND", "No device with id $deviceId")
            return
        }
        selectedDeviceId = deviceId
        sendDebugEvent("setPreferredInput: id=$deviceId name=${device.productName} type=${audioDeviceTypeToString(device.type)}")
        promise.resolve(null)
    }

    @ReactMethod
    fun clearPreferredInput(promise: Promise) {
        selectedDeviceId = null
        sendDebugEvent("clearPreferredInput: reset to default (built-in) mic")
        promise.resolve(null)
    }

    @ReactMethod
    fun startChunkedRecording(promise: Promise) {
        if (isRecording) { promise.resolve(null); return }
        if (ActivityCompat.checkSelfPermission(reactApplicationContext, Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            promise.reject("PERMISSION_DENIED", "User denied microphone permission"); return
        }
        try {
            isRecording = true
            chunkCounter = 0
            wasInterrupted = false
            lastChunkEmitted = false
            requestAudioFocus()

            // Guard against a stale preferred input (mirrors iOS): if the selected device is no
            // longer connected — e.g. a headset unplugged between selection and record — clear
            // it so we fall back to the built-in mic, and notify JS so its state catches up. A
            // still-connected device (wired, USB, or Bluetooth) is kept and used.
            selectedDeviceId?.let { id ->
                if (activeInputDevices().none { it.id == id }) {
                    sendDebugEvent("[StartChunked] preferred input $id no longer connected — clearing to built-in")
                    selectedDeviceId = null
                    sendRouteChangeEvent(reason = 2)
                }
            }

            val isBtScoDevice = selectedDeviceId?.let { id ->
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                    val audioManager = reactApplicationContext.getSystemService(Context.AUDIO_SERVICE) as AudioManager
                    val device = audioManager.getDevices(AudioManager.GET_DEVICES_INPUTS).firstOrNull { it.id == id }
                    sendDebugEvent("startChunkedRecording: selectedDeviceId=$id name=${device?.productName} type=${device?.type?.let { audioDeviceTypeToString(it) } ?: "null"}")
                    device?.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO
                } else false
            } ?: run {
                sendDebugEvent("startChunkedRecording: no preferred device, using default mic")
                false
            }

            if (isBtScoDevice) {
                sendDebugEvent("Bluetooth SCO device — must call startBluetoothSco() before AudioRecord")
                startBluetoothScoAndRecord(promise)
            } else {
                sendDebugEvent("startChunkedRecording: non-SCO path, starting directly")
                recordNextChunk()
                promise.resolve(null)
            }
        } catch (e: Exception) {
            isRecording = false
            abandonAudioFocus()
            promise.reject("AUDIO_SETUP_FAILED", e.message, e)
        }
    }

    @ReactMethod
    fun stopRecording(promise: Promise) {
        if (!isRecording) {
            promise.resolve(null)
            return
        }
        try {
            synchronized(chunkLock) {
                isRecording = false
                chunkTimer?.cancel()
                chunkTimer = null
                if (wasInterrupted) {
                    // The recorder was already torn down by an interruption, so there's no
                    // live chunk to flush. Signal completion directly so JS doesn't hang in
                    // "Processing" forever.
                    wasInterrupted = false
                    emitLastChunk(emptyLastChunkPayload())
                } else {
                    finishCurrentChunk(isLast = true)
                }
            }
            stopBluetoothScoIfStarted()
            abandonAudioFocus()
            promise.resolve(null)
        } catch (e: Exception) {
            promise.reject("AUDIO_TEARDOWN_FAILED", e.message, e)
        }
    }

    private fun startBluetoothScoAndRecord(promise: Promise) {
        connectBluetoothScoThen {
            try {
                if (isRecording) { recordNextChunk(); promise.resolve(null) }
                else { isRecording = false; promise.reject("RECORDING_CANCELLED", "Cancelled before SCO connected") }
            } catch (e: Exception) { isRecording = false; promise.reject("AUDIO_SETUP_FAILED", e.message, e) }
        }
    }

    // Establishes the Bluetooth SCO audio link, invoking onReady once connected (or after a
    // timeout — SCO sometimes never broadcasts CONNECTED). Used both to start recording on a
    // BT headset and to re-establish SCO after a phone call tears it down (see resume), since
    // AudioRecord on a disconnected SCO device otherwise captures silence.
    private fun connectBluetoothScoThen(onReady: () -> Unit) {
        val audioManager = reactApplicationContext.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val settled = AtomicBoolean(false)

        fun settleOnce(block: () -> Unit) {
            if (settled.compareAndSet(false, true)) block()
        }

        val timeoutRunnable = Runnable {
            sendDebugEvent("BT SCO connect timeout after ${BT_SCO_CONNECT_TIMEOUT_MS}ms — proceeding anyway")
            unregisterScoReceiver()
            settleOnce { onReady() }
        }

        // Clear any stale receiver before registering a fresh one.
        unregisterScoReceiver()

        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                val state = intent.getIntExtra(AudioManager.EXTRA_SCO_AUDIO_STATE, -1)
                sendDebugEvent("SCO broadcast: state=$state (DISCONNECTED=0, CONNECTED=1, CONNECTING=2)")
                when (state) {
                    AudioManager.SCO_AUDIO_STATE_CONNECTED -> {
                        sendDebugEvent("BT SCO connected")
                        mainHandler.removeCallbacks(timeoutRunnable)
                        unregisterScoReceiver()
                        settleOnce { onReady() }
                    }
                    AudioManager.SCO_AUDIO_STATE_DISCONNECTED ->
                        sendDebugEvent("BT SCO DISCONNECTED — waiting for CONNECTED or timeout")
                    AudioManager.SCO_AUDIO_STATE_CONNECTING ->
                        sendDebugEvent("BT SCO CONNECTING — waiting...")
                    else -> sendDebugEvent("BT SCO unknown state=$state")
                }
            }
        }
        scoReceiver = receiver
        reactApplicationContext.registerReceiver(receiver, IntentFilter(AudioManager.ACTION_SCO_AUDIO_STATE_UPDATED))

        bluetoothScoStarted = true
        audioManager.startBluetoothSco()
        @Suppress("DEPRECATION")
        audioManager.isBluetoothScoOn = true
        sendDebugEvent("startBluetoothSco() called — timeout in ${BT_SCO_CONNECT_TIMEOUT_MS}ms")
        mainHandler.postDelayed(timeoutRunnable, BT_SCO_CONNECT_TIMEOUT_MS)
    }

    private fun isPreferredDeviceBtSco(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return false
        val id = selectedDeviceId ?: return false
        val audioManager = reactApplicationContext.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val device = audioManager.getDevices(AudioManager.GET_DEVICES_INPUTS).firstOrNull { it.id == id }
        return device?.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO
    }

    private fun unregisterScoReceiver() {
        scoReceiver?.let {
            try { reactApplicationContext.unregisterReceiver(it) } catch (_: Exception) {}
            scoReceiver = null
        }
    }

    private fun stopBluetoothScoIfStarted() {
        if (bluetoothScoStarted) {
            sendDebugEvent("Stopping Bluetooth SCO")
            try {
                val audioManager = reactApplicationContext.getSystemService(Context.AUDIO_SERVICE) as AudioManager
                audioManager.stopBluetoothSco()
                @Suppress("DEPRECATION")
                audioManager.isBluetoothScoOn = false
            } catch (_: Exception) {}
            bluetoothScoStarted = false
        }
    }

    // MARK: - Interruption handling (audio focus)

    private fun requestAudioFocus() {
        val audioManager = reactApplicationContext.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val attributes = AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_MEDIA)
                .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                .build()
            val request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                .setAudioAttributes(attributes)
                .setOnAudioFocusChangeListener(audioFocusListener, focusHandler)
                .build()
            audioFocusRequest = request
            val result = audioManager.requestAudioFocus(request)
            sendDebugEvent("requestAudioFocus result=$result")
        } else {
            @Suppress("DEPRECATION")
            val result = audioManager.requestAudioFocus(
                audioFocusListener,
                AudioManager.STREAM_MUSIC,
                AudioManager.AUDIOFOCUS_GAIN
            )
            sendDebugEvent("requestAudioFocus(legacy) result=$result")
        }
    }

    private fun abandonAudioFocus() {
        val audioManager = reactApplicationContext.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            audioFocusRequest?.let { audioManager.abandonAudioFocusRequest(it) }
            audioFocusRequest = null
        } else {
            @Suppress("DEPRECATION")
            audioManager.abandonAudioFocus(audioFocusListener)
        }
    }

    private fun handleAudioFocusChange(focusChange: Int) {
        sendDebugEvent("[Interruption] focusChange=$focusChange isRecording=$isRecording wasInterrupted=$wasInterrupted")
        when (focusChange) {
            // A phone call (or other higher-priority capture) takes the mic. Flush the
            // audio captured so far as a chunk and suspend the loop; AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK
            // is intentionally ignored (that's ducking, not an interruption).
            AudioManager.AUDIOFOCUS_LOSS,
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT -> synchronized(chunkLock) {
                if (isRecording && !wasInterrupted) {
                    wasInterrupted = true
                    chunkTimer?.cancel()
                    chunkTimer = null
                    finishCurrentChunk(isLast = false)
                }
            }
            // The call ended and we have focus again: restart the chunk loop so recording
            // continues and the terminal onLastChunkReady will still fire on stop.
            AudioManager.AUDIOFOCUS_GAIN -> synchronized(chunkLock) {
                if (isRecording && wasInterrupted) {
                    wasInterrupted = false
                    if (isPreferredDeviceBtSco()) {
                        // The phone call tore down our SCO link; re-establish it before
                        // resuming, otherwise AudioRecord on the (now disconnected) SCO
                        // device captures silence. Recording restarts in the onReady callback.
                        sendDebugEvent("[Interruption] re-establishing Bluetooth SCO before resuming")
                        connectBluetoothScoThen {
                            synchronized(chunkLock) {
                                if (isRecording) {
                                    recordNextChunk()
                                    sendDebugEvent("[Interruption] resumed recording (SCO reconnected)")
                                }
                            }
                        }
                    } else {
                        recordNextChunk()
                        sendDebugEvent("[Interruption] resumed recording")
                    }
                }
            }
        }
    }

    private fun emitLastChunk(payload: WritableMap) {
        if (lastChunkEmitted) return
        lastChunkEmitted = true
        sendEvent("onLastChunkReady", payload)
    }

    private fun emptyLastChunkPayload(): WritableMap = Arguments.createMap().apply {
        putString("audioData", "")
        putString("format", "m4a")
        putInt("chunkNumber", chunkCounter)
        putBoolean("empty", true)
    }

    private fun recordNextChunk() {
        synchronized(chunkLock) {
        if (!isRecording || wasInterrupted) return@synchronized

        val fileName = "chunk_${chunkCounter}.m4a"
        currentChunkFile = File(reactApplicationContext.cacheDir, fileName).also {
            if (it.exists()) it.delete()
        }

        val minBuf = AudioRecord.getMinBufferSize(SAMPLE_RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
        val bufferSize = maxOf(minBuf * 4, SAMPLE_RATE * 4)

        val ar: AudioRecord = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            AudioRecord.Builder()
                .setAudioSource(MediaRecorder.AudioSource.MIC)
                .setAudioFormat(
                    AudioFormat.Builder()
                        .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                        .setSampleRate(SAMPLE_RATE)
                        .setChannelMask(AudioFormat.CHANNEL_IN_MONO)
                        .build()
                )
                .setBufferSizeInBytes(bufferSize)
                .build()
                .also { record ->
                    selectedDeviceId?.let { id ->
                        val audioManager = reactApplicationContext.getSystemService(Context.AUDIO_SERVICE) as AudioManager
                        val device = audioManager.getDevices(AudioManager.GET_DEVICES_INPUTS).firstOrNull { it.id == id }
                        if (device != null) {
                            sendDebugEvent("recordNextChunk: setPreferredDevice name=${device.productName} type=${audioDeviceTypeToString(device.type)} chunk=$chunkCounter")
                            record.setPreferredDevice(device)
                        } else {
                            sendDebugEvent("recordNextChunk: preferred device id=$id not found — using default")
                        }
                    }
                }
        } else {
            AudioRecord(MediaRecorder.AudioSource.MIC, SAMPLE_RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT, bufferSize)
        }

        if (ar.state != AudioRecord.STATE_INITIALIZED) {
            ar.release()
            sendDebugEvent("AudioRecord failed to initialize")
            isRecording = false
            return@synchronized
        }

        val codecFormat = MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_AAC, SAMPLE_RATE, 1).apply {
            setInteger(MediaFormat.KEY_BIT_RATE, BIT_RATE)
            setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, bufferSize)
            setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
        }
        val codec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC).apply {
            configure(codecFormat, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            start()
        }

        val muxer = MediaMuxer(currentChunkFile!!.absolutePath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)

        audioRecord = ar
        mediaCodec = codec
        mediaMuxer = muxer
        muxerTrackIndex = -1
        stopChunkRequested = false

        ar.startRecording()
        sendDebugEvent("recordNextChunk: AudioRecord started, recordingState=${ar.recordingState} (RECORDING=3) chunk=$chunkCounter")
        recordingThread = Thread { runRecordingLoop(ar, codec, muxer) }.also { it.start() }

        chunkTimer = Timer()
        chunkTimer?.schedule(object : TimerTask() {
            override fun run() {
                synchronized(chunkLock) {
                    if (isRecording && !wasInterrupted) {
                        finishCurrentChunk(isLast = false)
                        recordNextChunk()
                    }
                }
            }
        }, CHUNK_DURATION_MS)
        }
    }

    private fun runRecordingLoop(ar: AudioRecord, codec: MediaCodec, muxer: MediaMuxer) {
        val readBuffer = ByteArray(4096)
        val bufferInfo = MediaCodec.BufferInfo()
        var eosSignaled = false
        var muxerStarted = false

        while (true) {
            if (!eosSignaled) {
                if (stopChunkRequested) {
                    val idx = codec.dequeueInputBuffer(10_000)
                    if (idx >= 0) {
                        codec.queueInputBuffer(idx, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                        eosSignaled = true
                    }
                } else {
                    val bytesRead = ar.read(readBuffer, 0, readBuffer.size)
                    when {
                        bytesRead > 0 -> {
                            val idx = codec.dequeueInputBuffer(10_000)
                            if (idx >= 0) {
                                codec.getInputBuffer(idx)!!.apply {
                                    clear()
                                    put(readBuffer, 0, bytesRead)
                                }
                                codec.queueInputBuffer(idx, 0, bytesRead, System.nanoTime() / 1000, 0)
                            }
                        }
                        bytesRead < 0 -> {
                            val idx = codec.dequeueInputBuffer(10_000)
                            if (idx >= 0) {
                                codec.queueInputBuffer(idx, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                                eosSignaled = true
                            }
                        }
                    }
                }
            }

            var reachedEos = false
            while (true) {
                val idx = codec.dequeueOutputBuffer(bufferInfo, 0)
                when {
                    idx == MediaCodec.INFO_TRY_AGAIN_LATER -> break
                    idx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                        if (!muxerStarted) {
                            muxerTrackIndex = muxer.addTrack(codec.outputFormat)
                            muxer.start()
                            muxerStarted = true
                        }
                    }
                    idx >= 0 -> {
                        val out = codec.getOutputBuffer(idx)
                        if (muxerStarted && out != null && bufferInfo.size > 0 &&
                            (bufferInfo.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) == 0) {
                            muxer.writeSampleData(muxerTrackIndex, out, bufferInfo)
                        }
                        codec.releaseOutputBuffer(idx, false)
                        if ((bufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) {
                            reachedEos = true
                            break
                        }
                    }
                }
            }
            if (reachedEos) break
        }
    }

    private fun finishCurrentChunk(isLast: Boolean) {
        synchronized(chunkLock) {
        chunkTimer?.cancel()
        chunkTimer = null

        stopChunkRequested = true
        try { audioRecord?.stop() } catch (_: Exception) {}
        recordingThread?.join(5000)
        recordingThread = null

        releaseRecordingResources()

        var emitted = false
        currentChunkFile?.let { file ->
            if (file.exists() && file.length() > 0) {
                try {
                    val base64 = Base64.encodeToString(file.readBytes(), Base64.NO_WRAP)
                    val payload = Arguments.createMap().apply {
                        putString("audioData", base64)
                        putString("format", "m4a")
                        putInt("sampleRate", SAMPLE_RATE)
                        putInt("channels", 1)
                        putInt("bitsPerSample", 16)
                        putInt("chunkNumber", chunkCounter)
                    }
                    if (isLast) emitLastChunk(payload) else sendEvent("onChunkReady", payload)
                    chunkCounter++
                    emitted = true
                } catch (e: Exception) {
                    sendDebugEvent("Failed to read chunk: ${e.message}")
                }
            }
        }

        // If this was the final chunk but it had no audio (or failed to read),
        // still signal completion so JS doesn't hang in "Processing".
        if (isLast && !emitted) {
            emitLastChunk(emptyLastChunkPayload())
        }

        // Drop the reference so a later finish (e.g. a stop during the SCO-reconnect
        // window) can't re-read and re-emit this already-emitted file.
        currentChunkFile = null
        }
    }

    private fun releaseRecordingResources() {
        try { audioRecord?.release() } catch (_: Exception) {}
        audioRecord = null
        stopChunkRequested = false

        try {
            mediaCodec?.stop()
            mediaCodec?.release()
        } catch (_: Exception) {}
        mediaCodec = null

        try {
            if (muxerTrackIndex >= 0) mediaMuxer?.stop()
            mediaMuxer?.release()
        } catch (e: Exception) {
            sendDebugEvent("Muxer release error: ${e.message}")
        }
        mediaMuxer = null
        muxerTrackIndex = -1
    }

    private fun sendEvent(eventName: String, body: WritableMap?) {
        reactApplicationContext
            .getJSModule(DeviceEventManagerModule.RCTDeviceEventEmitter::class.java)
            .emit(eventName, body)
    }

    private fun sendDebugEvent(message: String) {
        reactApplicationContext
            .getJSModule(DeviceEventManagerModule.RCTDeviceEventEmitter::class.java)
            .emit("onDebug", message)
    }

    override fun getConstants(): MutableMap<String, Any> = mutableMapOf()
}
