export type FFmpegExecuteResult = {
  sessionId: string;
  returnCode: number;
};

export type FFmpegRuntimeInfo = {
  packageName: string;
  ffmpegVersion: string;
  ffmpegKitVersion: string;
  buildDate: string;
  externalLibraries: string[];
  releaseTag?: string;
  vendor?: string;
};

/** Subset of FFprobe / MediaInformation JSON (shape varies by file). */
export type MediaInformation = Record<string, unknown>;

export type FFmpegProgressEvent = {
  sessionId: string;
  timeMilliseconds: number;
  videoFrameNumber: number;
  videoFps: number;
  size: number;
  bitrate: number;
  speed: number;
};

export type FFmpegLogEvent = {
  message: string;
  level: number;
  sessionId?: string;
};

export type FFmpegModuleEvents = {
  onProgress: (event: FFmpegProgressEvent) => void;
  onLog: (event: FFmpegLogEvent) => void;
};
