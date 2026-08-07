import { NativeModule, requireNativeModule } from 'expo';

import type {
  FFmpegExecuteResult,
  FFmpegModuleEvents,
  FFmpegRuntimeInfo,
  MediaInformation,
} from './FFmpegModule.types';

declare class FFmpegModuleNative extends NativeModule<FFmpegModuleEvents> {
  execute(command: string | string[]): Promise<FFmpegExecuteResult>;
  cancel(sessionId?: string): Promise<boolean>;
  probe(path: string, timeoutMs?: number): Promise<MediaInformation>;
  getRuntimeInfo(): FFmpegRuntimeInfo;
}

export default requireNativeModule<FFmpegModuleNative>('FFmpegModule');
