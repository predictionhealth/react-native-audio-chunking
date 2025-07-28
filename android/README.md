# Android Implementation

This directory contains the Android implementation of the React Native Audio Chunking module.

## Structure

- `src/main/java/com/isaacgrey/audiochunking/` - Kotlin source files
  - `AudioChunkingModule.kt` - Main module implementation
  - `AudioChunkingPackage.kt` - React Native package registration
- `src/main/AndroidManifest.xml` - Android manifest with permissions
- `build.gradle` - Module build configuration
- `gradle.properties` - Gradle properties

## Features

The Android implementation provides the same functionality as the iOS version:

- **120-second audio chunks**: Records audio in 120-second segments
- **M4A format**: Uses AAC encoding in MPEG-4 container
- **Base64 encoding**: Returns audio data as base64 strings
- **Event emission**: Sends events for chunk completion and debugging
- **Permission handling**: Checks for RECORD_AUDIO permission
- **Lifecycle management**: Properly handles app lifecycle events

## API

The module exposes the same methods as the iOS version:

- `startChunkedRecording()` - Starts recording with automatic chunking
- `stopRecording()` - Stops recording and finalizes the last chunk

## Events

- `onChunkReady` - Emitted when a chunk is completed (except the last one)
- `onLastChunkReady` - Emitted when the final chunk is completed
- `onDebug` - Emitted for debugging information

## Permissions

The module requires the following permissions:
- `RECORD_AUDIO` - For audio recording
- `WRITE_EXTERNAL_STORAGE` - For temporary file storage
- `READ_EXTERNAL_STORAGE` - For reading temporary files

## Build Requirements

- Minimum SDK: 21 (Android 5.0)
- Target SDK: 33 (Android 13)
- Kotlin version: 1.8.0
- React Native: 0.60.0+ 