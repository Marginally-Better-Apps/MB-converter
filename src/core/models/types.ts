export type MediaCategory = 'video' | 'audio' | 'image' | 'animatedImage';

export type OutputFormat =
  | 'mp4_h264'
  | 'mp4_hevc'
  | 'mov'
  | 'webm'
  | 'mp3'
  | 'm4a'
  | 'wav'
  | 'aac'
  | 'flac'
  | 'ogg'
  | 'opus'
  | 'jpg'
  | 'png'
  | 'heic'
  | 'webpImage'
  | 'tiff'
  | 'gif';

export type OutputOperationMode = 'manual' | 'autoTarget';

export type Size = {
  width: number;
  height: number;
};

export type CropRegion = {
  x: number;
  y: number;
  width: number;
  height: number;
};

export type MetadataExportPolicy = {
  stripAll: boolean;
  retainedFormatTags: Record<string, string>;
  retainedStreamTags: Record<number, Record<string, string>>;
  sourceStreamIndicesForTagStrip: number[];
};

export const DEFAULT_METADATA_POLICY: MetadataExportPolicy = {
  stripAll: true,
  retainedFormatTags: {},
  retainedStreamTags: {},
  sourceStreamIndicesForTagStrip: [],
};

export type MediaFile = {
  path: string;
  category: MediaCategory;
  sizeOnDisk: number;
  dimensions?: Size;
  duration?: number;
  fps?: number;
  bitrate?: number;
  audioBitrate?: number;
  videoCodec?: string;
  audioCodec?: string;
  containerFormat: string;
};

export type ConversionConfig = {
  outputFormat: OutputFormat;
  targetDimensions?: Size;
  targetFPS?: number;
  targetSizeBytes?: number;
  cropRegion?: CropRegion;
  videoQuality?: number;
  usesSinglePassVideoTargetEncode?: boolean;
  frameTimeForExtraction?: number;
  preferredAudioBitrateKbps?: number;
  operationMode?: OutputOperationMode;
  prefersRemuxWhenPossible?: boolean;
  metadata?: MetadataExportPolicy;
};

export type FFmpegRuntimeSnapshot = {
  packageName: string;
  externalLibraries: string[];
};

/** Default assumption for unit tests / offline: ffmpeg-kit min package. */
export const MIN_PACKAGE_RUNTIME: FFmpegRuntimeSnapshot = {
  packageName: 'min',
  externalLibraries: [],
};
