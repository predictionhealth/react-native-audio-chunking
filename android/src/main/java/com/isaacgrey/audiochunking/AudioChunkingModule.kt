package com.isaacgrey.audiochunking

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.media.MediaRecorder
import android.os.Build
import android.util.Base64
import androidx.core.app.ActivityCompat
import com.facebook.react.bridge.*
import com.facebook.react.modules.core.DeviceEventManagerModule
import java.io.File
import java.io.FileInputStream
import java.io.IOException
import java.util.*

@ReactModule(name = AudioChunkingModule.NAME)
class AudioChunkingModule(reactContext: ReactApplicationContext) : ReactContextBaseJavaModule(reactContext), LifecycleEventListener {
    companion object {
        const val NAME = "AudioChunkingModule"
        private const val CHUNK_DURATION_MS = 120000L // 120 seconds
        private const val SAMPLE_RATE = 44100
    }

    private var mediaRecorder: MediaRecorder? = null
    private var isRecording = false
    private var chunkCounter = 0
    private var currentChunkFile: File? = null
    private var chunkTimer: Timer? = null

    override fun getName(): String = NAME

    override fun initialize() {
        super.initialize()
        reactApplicationContext.addLifecycleEventListener(this)
    }

    override fun onHostResume() {
        // Handle app resume if needed
    }

    override fun onHostPause() {
        // Handle app pause if needed
    }

    override fun onHostDestroy() {
        stopRecordingInternal()
    }

    @ReactMethod
    fun startChunkedRecording(promise: Promise) {
        if (isRecording) {
            promise.resolve(null)
            return
        }

        // Check permissions
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
            stopRecordingInternal()
            promise.resolve(null)
        } catch (e: Exception) {
            promise.reject("AUDIO_TEARDOWN_FAILED", e.message, e)
        }
    }

    private fun stopRecordingInternal() {
        isRecording = false
        chunkTimer?.cancel()
        chunkTimer = null
        
        mediaRecorder?.let { recorder ->
            try {
                recorder.stop()
                recorder.release()
            } catch (e: Exception) {
                sendDebugEvent("Error stopping recorder: ${e.message}")
            }
        }
        mediaRecorder = null
    }

    private fun recordNextChunk() {
        if (!isRecording) return

        try {
            // Create temporary file for this chunk
            val fileName = "chunk_${chunkCounter}.m4a"
            currentChunkFile = File(reactApplicationContext.cacheDir, fileName)
            
            // Remove existing file if it exists
            currentChunkFile?.let { if (it.exists()) it.delete() }

            // Setup MediaRecorder
            mediaRecorder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                MediaRecorder(reactApplicationContext)
            } else {
                @Suppress("DEPRECATION")
                MediaRecorder()
            }

            mediaRecorder?.apply {
                setAudioSource(MediaRecorder.AudioSource.MIC)
                setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
                setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
                setAudioSamplingRate(SAMPLE_RATE)
                setAudioChannels(1)
                setAudioEncodingBitRate(128000)
                setOutputFile(currentChunkFile?.absolutePath)
                
                try {
                    prepare()
                    start()
                    
                    // Schedule next chunk
                    chunkTimer = Timer()
                    chunkTimer?.schedule(object : TimerTask() {
                        override fun run() {
                            if (isRecording) {
                                finishCurrentChunk()
                                recordNextChunk()
                            }
                        }
                    }, CHUNK_DURATION_MS)
                    
                } catch (e: IOException) {
                    sendDebugEvent("Failed to start recording: ${e.message}")
                    isRecording = false
                }
            }
        } catch (e: Exception) {
            sendDebugEvent("Recorder setup failed: ${e.message}")
            isRecording = false
        }
    }

    private fun finishCurrentChunk() {
        mediaRecorder?.let { recorder ->
            try {
                recorder.stop()
                recorder.release()
                
                // Read the recorded file and convert to base64
                currentChunkFile?.let { file ->
                    if (file.exists() && file.length() > 0) {
                        val audioData = file.readBytes()
                        val base64String = Base64.encodeToString(audioData, Base64.NO_WRAP)
                        
                        val payload = Arguments.createMap().apply {
                            putString("audioData", base64String)
                            putString("format", "m4a")
                            putInt("sampleRate", SAMPLE_RATE)
                            putInt("channels", 1)
                            putInt("bitsPerSample", 16)
                            putInt("chunkNumber", chunkCounter)
                        }
                        
                        val eventName = if (isRecording) "onChunkReady" else "onLastChunkReady"
                        sendEvent(eventName, payload)
                        chunkCounter++
                    }
                }
            } catch (e: Exception) {
                sendDebugEvent("Failed to finish chunk: ${e.message}")
            }
        }
        mediaRecorder = null
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

    override fun getConstants(): MutableMap<String, Any> {
        return mutableMapOf()
    }
} 