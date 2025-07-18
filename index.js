import { NativeModules, Platform } from 'react-native';

const LINKING_ERROR =
  `The package 'react-native-audio-chunking' doesn't seem to be linked. Make sure:\
  \\n\\n- You rebuilt the app after installing the package\
  \\n- You are not using Expo Go (bare workflow or dev build required)\
  \\n`;

const AudioChunkingModule = NativeModules.AudioChunkingModule
  ? NativeModules.AudioChunkingModule
  : new Proxy(
      {},
      {
        get() {
          throw new Error(LINKING_ERROR);
        },
      }
    );

export default AudioChunkingModule;