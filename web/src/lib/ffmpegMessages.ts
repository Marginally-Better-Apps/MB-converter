import type {
  ConversionConfig,
  EncodingStats,
  MediaCategory,
  MediaFile,
  OutputFormat
} from "./models";
import type { SerializableCodecCapabilities } from "./codecCapabilities";

export type { SerializableCodecCapabilities };

export type SerializableMediaFile = Omit<MediaFile, "objectUrl">;

export interface WorkerConversionJob {
  input: MediaFile;
  config: ConversionConfig;
}

export interface SerializableWorkerConversionJob {
  input: SerializableMediaFile;
  config: ConversionConfig;
}

export type FfmpegWorkerRequest =
  | { type: "load"; preferThreaded?: boolean }
  | { type: "inspect"; media: SerializableMediaFile }
  | { type: "convert"; job: SerializableWorkerConversionJob }
  | { type: "cancel" };

export type FfmpegWorkerResponse =
  | { type: "capabilities"; capabilities: SerializableCodecCapabilities }
  | { type: "inspected"; media: SerializableMediaFile }
  | { type: "progress"; progress: number; time?: number; stats?: EncodingStats }
  | { type: "stats"; stats: EncodingStats }
  | { type: "log"; message: string }
  | {
      type: "converted";
      result: {
        id: string;
        blob: Blob;
        outputFormat: OutputFormat;
        filename: string;
        sizeOnDisk: number;
        dimensions?: { width: number; height: number };
        duration?: number;
        fps?: number;
        bitrate?: number;
        audioBitrate?: number;
        videoCodec?: string;
        audioCodec?: string;
        completedAt: number;
      };
    }
  | { type: "cancelled" }
  | { type: "error"; message: string };

export type FfmpegWorkerResponseByType<T extends FfmpegWorkerResponse["type"]> =
  Extract<FfmpegWorkerResponse, { type: T }>;

export function workerMediaToMediaFile(media: SerializableMediaFile): MediaFile {
  return {
    ...media,
    objectUrl: ""
  };
}

export function categoryLabel(category: MediaCategory): string {
  switch (category) {
    case "animatedImage":
      return "Animated";
    case "video":
      return "Video";
    case "audio":
      return "Audio";
    case "image":
      return "Image";
  }
}
