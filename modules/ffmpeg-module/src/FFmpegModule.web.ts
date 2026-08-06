import { NativeModule } from 'expo';

import type {
  FFmpegExecuteResult,
  FFmpegModuleEvents,
  FFmpegRuntimeInfo,
  MediaInformation,
} from './FFmpegModule.types';

class FFmpegModuleWeb extends NativeModule<FFmpegModuleEvents> {
  async execute(_command: string | string[]): Promise<FFmpegExecuteResult> {
    throw new Error('FFmpegModule is iOS-only and unavailable on web.');
  }

  async cancel(_sessionId?: string): Promise<boolean> {
    return false;
  }

  async probe(_path: string, _timeoutMs?: number): Promise<MediaInformation> {
    throw new Error('FFmpegModule is iOS-only and unavailable on web.');
  }

  getRuntimeInfo(): FFmpegRuntimeInfo {
    return {
      packageName: 'unlinked',
      ffmpegVersion: 'unavailable',
      ffmpegKitVersion: 'unavailable',
      buildDate: 'unavailable',
      externalLibraries: [],
      releaseTag: 'min.v5.1.2.6',
      vendor: 'tylerjonesio/ffmpeg-kit-spm',
    };
  }
}

export default new FFmpegModuleWeb();
