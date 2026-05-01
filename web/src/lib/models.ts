export type MediaCategory = "video" | "audio" | "image" | "animatedImage";

export type OutputFormat =
  | "mp4_h264"
  | "mp4_hevc"
  | "mov"
  | "webm"
  | "mp3"
  | "m4a"
  | "wav"
  | "aac"
  | "flac"
  | "ogg"
  | "opus"
  | "jpg"
  | "png"
  | "heic"
  | "webpImage"
  | "tiff"
  | "gif";

export type OutputOperationMode = "manual" | "autoTarget";
export type ThemeMode = "system" | "light" | "dark";

export interface OutputFormatDetail {
  fileExtension: string;
  displayName: string;
  category: MediaCategory;
  isLossy: boolean;
  supportsTargetSize: boolean;
}

export const outputFormats: Record<OutputFormat, OutputFormatDetail> = {
  mp4_h264: {
    fileExtension: "mp4",
    displayName: "MP4 (H.264)",
    category: "video",
    isLossy: true,
    supportsTargetSize: true
  },
  mp4_hevc: {
    fileExtension: "mp4",
    displayName: "MP4 (HEVC)",
    category: "video",
    isLossy: true,
    supportsTargetSize: true
  },
  mov: {
    fileExtension: "mov",
    displayName: "MOV",
    category: "video",
    isLossy: true,
    supportsTargetSize: true
  },
  webm: {
    fileExtension: "webm",
    displayName: "WebM",
    category: "video",
    isLossy: true,
    supportsTargetSize: true
  },
  mp3: {
    fileExtension: "mp3",
    displayName: "MP3",
    category: "audio",
    isLossy: true,
    supportsTargetSize: true
  },
  m4a: {
    fileExtension: "m4a",
    displayName: "M4A",
    category: "audio",
    isLossy: true,
    supportsTargetSize: true
  },
  wav: {
    fileExtension: "wav",
    displayName: "WAV",
    category: "audio",
    isLossy: false,
    supportsTargetSize: false
  },
  aac: {
    fileExtension: "aac",
    displayName: "AAC",
    category: "audio",
    isLossy: true,
    supportsTargetSize: true
  },
  flac: {
    fileExtension: "flac",
    displayName: "FLAC",
    category: "audio",
    isLossy: false,
    supportsTargetSize: false
  },
  ogg: {
    fileExtension: "ogg",
    displayName: "OGG",
    category: "audio",
    isLossy: true,
    supportsTargetSize: true
  },
  opus: {
    fileExtension: "opus",
    displayName: "Opus",
    category: "audio",
    isLossy: true,
    supportsTargetSize: true
  },
  jpg: {
    fileExtension: "jpg",
    displayName: "JPEG",
    category: "image",
    isLossy: true,
    supportsTargetSize: true
  },
  png: {
    fileExtension: "png",
    displayName: "PNG",
    category: "image",
    isLossy: false,
    supportsTargetSize: false
  },
  heic: {
    fileExtension: "heic",
    displayName: "HEIC",
    category: "image",
    isLossy: true,
    supportsTargetSize: true
  },
  webpImage: {
    fileExtension: "webp",
    displayName: "WebP",
    category: "image",
    isLossy: true,
    supportsTargetSize: false
  },
  tiff: {
    fileExtension: "tiff",
    displayName: "TIFF",
    category: "image",
    isLossy: false,
    supportsTargetSize: false
  },
  gif: {
    fileExtension: "gif",
    displayName: "GIF",
    category: "animatedImage",
    isLossy: true,
    supportsTargetSize: true
  }
};

export const allOutputFormats = Object.keys(outputFormats) as OutputFormat[];
export const outputFormatDetails = outputFormats;

export interface Dimensions {
  width: number;
  height: number;
}

export interface CropRegion {
  x: number;
  y: number;
  width: number;
  height: number;
}

export interface MetadataExportPolicy {
  stripAll: boolean;
  retainedFormatTags: Record<string, string>;
  retainedStreamTags: Record<number, Record<string, string>>;
  retainedImageTags: Array<{ key: string; value: string }>;
}

export interface MediaFile {
  id: string;
  file: File;
  objectUrl: string;
  originalFilename: string;
  category: MediaCategory;
  sizeOnDisk: number;
  dimensions?: Dimensions;
  duration?: number;
  fps?: number;
  bitrate?: number;
  audioBitrate?: number;
  videoCodec?: string;
  audioCodec?: string;
  containerFormat: string;
  mimeType?: string;
}

export interface AutoTargetLockPolicy {
  resolution: boolean;
  fps: boolean;
  audioQuality: boolean;
}

export interface ConversionConfig {
  outputFormat: OutputFormat;
  targetDimensions?: Dimensions;
  targetFPS?: number;
  targetSizeBytes?: number;
  cropRegion?: CropRegion;
  imageQuality?: number;
  videoQuality?: number;
  usesSinglePassVideoTargetEncode: boolean;
  frameTimeForExtraction?: number;
  preferredAudioBitrateKbps?: number;
  operationMode: OutputOperationMode;
  autoTargetLockPolicy: AutoTargetLockPolicy;
  prefersRemuxWhenPossible: boolean;
  metadata: MetadataExportPolicy;
}

export interface ConversionResult {
  id: string;
  blob: Blob;
  objectUrl: string;
  outputFormat: OutputFormat;
  filename: string;
  sizeOnDisk: number;
  dimensions?: Dimensions;
  duration?: number;
  fps?: number;
  bitrate?: number;
  audioBitrate?: number;
  videoCodec?: string;
  audioCodec?: string;
  completedAt: number;
}

export interface HistoryEntry {
  id: string;
  inputName: string;
  outputName: string;
  inputSize: number;
  outputSize: number;
  outputFormat: OutputFormat;
  completedAt: number;
}

export interface RuntimeCapabilities {
  loaded: boolean;
  threaded: boolean;
  encoders: string[];
  decoders: string[];
  muxers: string[];
  demuxers: string[];
  ffmpegVersion?: string;
  error?: string;
}

export interface EncodingStats {
  frame?: number;
  fps?: number;
  encodedSize?: string;
  time?: string;
  timeMilliseconds?: number;
  throughputBitrate?: string;
  speed?: string;
}

export type ConversionProgress = {
  progress: number;
  passLabel: string;
  determinate: boolean;
  stats?: EncodingStats;
  logLine?: string;
};

export const defaultMetadataPolicy: MetadataExportPolicy = {
  stripAll: true,
  retainedFormatTags: {},
  retainedStreamTags: {},
  retainedImageTags: []
};

export const manualLockPolicy: AutoTargetLockPolicy = {
  resolution: true,
  fps: true,
  audioQuality: true
};

export const unlockedAutoPolicy: AutoTargetLockPolicy = {
  resolution: false,
  fps: false,
  audioQuality: false
};
