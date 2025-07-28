# React Native Audio Chunking

A React Native module for recording audio and automatically splitting it into 120-second chunks. Supports both iOS and Android platforms.

## Features

- **Cross-platform**: Works on both iOS and Android
- **Automatic chunking**: Records audio in 120-second segments
- **High-quality audio**: Uses AAC encoding in M4A format
- **Base64 encoding**: Returns audio data as base64 strings for easy transmission
- **Event-driven**: Emits events when chunks are ready
- **Permission handling**: Automatically handles microphone permissions
- **Lifecycle management**: Properly manages app lifecycle events

## Installation

### 1. Install the package

```bash
npm install react-native-audio-chunking
# or
yarn add react-native-audio-chunking
```

### 2. iOS Setup

For iOS, the module uses CocoaPods. Run:

```bash
cd ios && pod install
```

### 3. Android Setup

For Android, the module is automatically linked. Make sure your app has the necessary permissions in `android/app/src/main/AndroidManifest.xml`:

```xml
<uses-permission android:name="android.permission.RECORD_AUDIO" />
<uses-permission android:name="android.permission.WRITE_EXTERNAL_STORAGE" />
<uses-permission android:name="android.permission.READ_EXTERNAL_STORAGE" />
```

## Usage

### Basic Usage

```javascript
import { NativeEventEmitter } from 'react-native';
import AudioChunkingModule from 'react-native-audio-chunking';

// Create event emitter
const eventEmitter = new NativeEventEmitter(AudioChunkingModule);

// Setup event listeners
eventEmitter.addListener('onChunkReady', (chunk) => {
  console.log('Chunk ready:', chunk);
  // Process the chunk (e.g., send to server, save to file)
});

eventEmitter.addListener('onLastChunkReady', (chunk) => {
  console.log('Final chunk ready:', chunk);
  // Process the final chunk
});

eventEmitter.addListener('onDebug', (message) => {
  console.log('Debug:', message);
});

// Start recording
await AudioChunkingModule.startChunkedRecording();

// Stop recording
await AudioChunkingModule.stopRecording();
```

### Advanced Usage

See `example-usage.js` for a complete example with error handling and server upload.

## API Reference

### Methods

#### `startChunkedRecording(): Promise<void>`

Starts recording audio with automatic chunking. Each chunk will be 120 seconds long.

**Returns:** Promise that resolves when recording starts successfully.

**Throws:**
- `PERMISSION_DENIED` - If microphone permission is not granted
- `AUDIO_SETUP_FAILED` - If audio setup fails

#### `stopRecording(): Promise<void>`

Stops recording and finalizes the last chunk.

**Returns:** Promise that resolves when recording stops successfully.

**Throws:**
- `AUDIO_TEARDOWN_FAILED` - If audio teardown fails

### Events

#### `onChunkReady`

Emitted when a chunk is completed (except the last one).

**Payload:**
```javascript
{
  audioData: string,      // Base64 encoded audio data
  format: string,         // "m4a"
  sampleRate: number,     // 44100
  channels: number,       // 1
  bitsPerSample: number,  // 16
  chunkNumber: number     // Zero-based chunk index
}
```

#### `onLastChunkReady`

Emitted when the final chunk is completed after stopping recording.

**Payload:** Same as `onChunkReady`

#### `onDebug`

Emitted for debugging information.

**Payload:** `string` - Debug message

## Platform Differences

### iOS
- Uses `AVAudioRecorder` for recording
- Audio session management handled automatically
- Temporary files stored in app's temporary directory

### Android
- Uses `MediaRecorder` for recording
- Permission checking handled automatically
- Temporary files stored in app's cache directory
- Supports Android 5.0 (API 21) and above

## Audio Format

Both platforms record audio in the following format:
- **Container:** MPEG-4 (M4A)
- **Codec:** AAC
- **Sample Rate:** 44,100 Hz
- **Channels:** 1 (Mono)
- **Bit Depth:** 16-bit
- **Bit Rate:** 128 kbps

## Permissions

### iOS
The module automatically requests microphone permission when `startChunkedRecording()` is called.

### Android
Add the following permissions to your `AndroidManifest.xml`:

```xml
<uses-permission android:name="android.permission.RECORD_AUDIO" />
<uses-permission android:name="android.permission.WRITE_EXTERNAL_STORAGE" />
<uses-permission android:name="android.permission.READ_EXTERNAL_STORAGE" />
```

## Error Handling

Always wrap the module calls in try-catch blocks:

```javascript
try {
  await AudioChunkingModule.startChunkedRecording();
} catch (error) {
  if (error.code === 'PERMISSION_DENIED') {
    // Handle permission denied
  } else if (error.code === 'AUDIO_SETUP_FAILED') {
    // Handle audio setup failure
  }
}
```

## Troubleshooting

### Common Issues

1. **Permission denied on Android**
   - Make sure you've added the RECORD_AUDIO permission to AndroidManifest.xml
   - Request permission at runtime if targeting Android 6.0+

2. **Audio not recording**
   - Check if microphone permission is granted
   - Ensure no other app is using the microphone
   - Check debug events for error messages

3. **Chunks not being received**
   - Make sure event listeners are set up before starting recording
   - Check that the event emitter is properly configured

### Debug Events

Listen to the `onDebug` event to get detailed information about what's happening:

```javascript
eventEmitter.addListener('onDebug', (message) => {
  console.log('Debug:', message);
});
```

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Add tests if applicable
5. Submit a pull request

## License

ISC License - see LICENSE file for details. 