import { NativeEventEmitter, NativeModules, Platform } from 'react-native';
import AudioChunkingModule from './index';

// Example usage of the Audio Chunking Module
class AudioChunkingExample {
  constructor() {
    this.eventEmitter = new NativeEventEmitter(AudioChunkingModule);
    this.setupEventListeners();
  }

  setupEventListeners() {
    // Listen for chunk completion events
    this.eventEmitter.addListener('onChunkReady', (chunk) => {
      console.log('Chunk ready:', {
        chunkNumber: chunk.chunkNumber,
        format: chunk.format,
        sampleRate: chunk.sampleRate,
        channels: chunk.channels,
        bitsPerSample: chunk.bitsPerSample,
        audioDataLength: chunk.audioData.length
      });
      
      // Process the audio chunk (e.g., send to server, save to file, etc.)
      this.processAudioChunk(chunk);
    });

    // Listen for the final chunk
    this.eventEmitter.addListener('onLastChunkReady', (chunk) => {
      console.log('Final chunk ready:', {
        chunkNumber: chunk.chunkNumber,
        format: chunk.format,
        sampleRate: chunk.sampleRate,
        channels: chunk.channels,
        bitsPerSample: chunk.bitsPerSample,
        audioDataLength: chunk.audioData.length
      });
      
      // Process the final chunk
      this.processAudioChunk(chunk);
    });

    // Listen for debug events
    this.eventEmitter.addListener('onDebug', (message) => {
      console.log('Debug:', message);
    });
  }

  async startRecording() {
    try {
      console.log('Starting chunked recording...');
      await AudioChunkingModule.startChunkedRecording();
      console.log('Recording started successfully');
    } catch (error) {
      console.error('Failed to start recording:', error);
    }
  }

  async stopRecording() {
    try {
      console.log('Stopping recording...');
      await AudioChunkingModule.stopRecording();
      console.log('Recording stopped successfully');
    } catch (error) {
      console.error('Failed to stop recording:', error);
    }
  }

  processAudioChunk(chunk) {
    // Example: Convert base64 to binary and save to file
    const audioData = Buffer.from(chunk.audioData, 'base64');
    
    // Example: Send to server
    this.sendToServer(chunk);
    
    // Example: Save to local storage
    this.saveToLocalStorage(chunk);
  }

  async sendToServer(chunk) {
    try {
      const response = await fetch('https://your-api.com/upload-audio', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          audioData: chunk.audioData,
          format: chunk.format,
          sampleRate: chunk.sampleRate,
          channels: chunk.channels,
          bitsPerSample: chunk.bitsPerSample,
          chunkNumber: chunk.chunkNumber,
          timestamp: new Date().toISOString()
        })
      });
      
      if (response.ok) {
        console.log(`Chunk ${chunk.chunkNumber} uploaded successfully`);
      } else {
        console.error(`Failed to upload chunk ${chunk.chunkNumber}`);
      }
    } catch (error) {
      console.error('Error sending chunk to server:', error);
    }
  }

  saveToLocalStorage(chunk) {
    // Example: Save to AsyncStorage or file system
    console.log(`Saving chunk ${chunk.chunkNumber} to local storage`);
    // Implementation depends on your storage solution
  }

  cleanup() {
    // Remove event listeners when done
    this.eventEmitter.removeAllListeners('onChunkReady');
    this.eventEmitter.removeAllListeners('onLastChunkReady');
    this.eventEmitter.removeAllListeners('onDebug');
  }
}

// Usage example
const audioExample = new AudioChunkingExample();

// Start recording
// audioExample.startRecording();

// Stop recording after some time
// setTimeout(() => {
//   audioExample.stopRecording();
// }, 300000); // 5 minutes

// Cleanup when component unmounts
// audioExample.cleanup();

export default AudioChunkingExample; 