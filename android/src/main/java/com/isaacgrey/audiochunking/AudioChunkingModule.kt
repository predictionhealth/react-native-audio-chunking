package com.isaacgrey.audiochunking

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioDeviceCallback
import android.os.Handler
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

class AudioChunkingModule(reactContext: ReactApplicationContext) :
    ReactContextBaseJavaModule(reactContext), LifecycleEventListener {

    companion object {
        const val NAME = "AudioChunkingModule"
        private const val CHUNK_DURATION_MS = 120000L
        private const val SAMPLE_RATE = 44100
        private const val BIT_RATE = 128000
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

    private val audioDeviceCallback = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
        object : AudioDeviceCallback() {
            override fun onAudioDevicesAdded(addedDevices: Array<out AudioDeviceInfo>) {
                val payload = Arguments.createMap().apply { putArray("inputs", buildInputsList()) }
                sendEvent("onAudioRouteChange", payload)
            }
            override fun onAudioDevicesRemoved(removedDevices: Array<out AudioDeviceInfo>) {
                val payload = Arguments.createMap().apply { putArray("inputs", buildInputsList()) }
                sendEvent("onAudioRouteChange", payload)
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
            chunkTimer?.cancel()
            chunkTimer = null
            stopChunkRequested = true
            try { audioRecord?.stop() } catch (_: Exception) {}
            recordingThread?.join(3000)
            recordingThread = null
            releaseRecordingResources()
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
        promise.resolve(null)
    }

    @ReactMethod
    fun startChunkedRecording(promise: Promise) {
        if (isRecording) {
            promise.resolve(null)
            return
        }
        if (ActivityCompat.checkSelfPermission(reactApplicationContext, Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            promise.reject("PERMISSION_DENIED", "User denied microphone permission")
            return
        }
        try {
            isRecording = true
            chunkCounter = 0
            recordNextChunk()
            promise.resolve(null)
        } catch (e: Exception) {
            isRecording = false
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
            isRecording = false
            chunkTimer?.cancel()
            chunkTimer = null
            finishCurrentChunk(isLast = true)
            promise.resolve(null)
        } catch (e: Exception) {
            promise.reject("AUDIO_TEARDOWN_FAILED", e.message, e)
        }
    }

    private fun recordNextChunk() {
        if (!isRecording) return

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
                        device?.let { record.setPreferredDevice(it) }
                    }
                }
        } else {
            AudioRecord(MediaRecorder.AudioSource.MIC, SAMPLE_RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT, bufferSize)
        }

        if (ar.state != AudioRecord.STATE_INITIALIZED) {
            ar.release()
            sendDebugEvent("AudioRecord failed to initialize")
            isRecording = false
            return
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
        recordingThread = Thread { runRecordingLoop(ar, codec, muxer) }.also { it.start() }

        chunkTimer = Timer()
        chunkTimer?.schedule(object : TimerTask() {
            override fun run() {
                if (isRecording) {
                    finishCurrentChunk(isLast = false)
                    recordNextChunk()
                }
            }
        }, CHUNK_DURATION_MS)
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
        chunkTimer?.cancel()
        chunkTimer = null

        stopChunkRequested = true
        try { audioRecord?.stop() } catch (_: Exception) {}
        recordingThread?.join(5000)
        recordingThread = null

        releaseRecordingResources()

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
                    sendEvent(if (isLast) "onLastChunkReady" else "onChunkReady", payload)
                    chunkCounter++
                } catch (e: Exception) {
                    sendDebugEvent("Failed to read chunk: ${e.message}")
                }
            }
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
