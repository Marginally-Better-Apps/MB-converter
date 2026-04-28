import type {
  ConversionConfig,
  ConversionResult,
  EncodingDisplayStats,
  MediaFile
} from "./models";
import type {
  FfmpegWorkerRequest,
  FfmpegWorkerResponse,
  SerializableCodecCapabilities,
  SerializableMediaFile
} from "./ffmpegMessages";

type ClientEvent =
  | { type: "progress"; progress: number; stats?: EncodingDisplayStats }
  | { type: "log"; message: string }
  | { type: "stats"; stats: EncodingDisplayStats }
  | { type: "capabilities"; capabilities: SerializableCodecCapabilities }
  | { type: "inspected"; media: SerializableMediaFile }
  | { type: "converted"; result: Omit<ConversionResult, "objectUrl"> }
  | { type: "error"; message: string }
  | { type: "cancelled" };

type Listener = (event: ClientEvent) => void;

export class FfmpegClient {
  private worker: Worker | null = null;
  private listeners = new Set<Listener>();
  private inspectResolvers: Array<{
    mediaId: string;
    resolve: (media: SerializableMediaFile) => void;
    reject: (error: Error) => void;
  }> = [];

  addListener(listener: Listener): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  load(): void {
    this.post({ type: "load", preferThreaded: true });
  }

  inspect(media: MediaFile): void {
    this.post({ type: "inspect", media: serializeMedia(media) });
  }

  inspectMedia(media: MediaFile): Promise<SerializableMediaFile> {
    this.post({ type: "inspect", media: serializeMedia(media) });
    return new Promise((resolve, reject) => {
      this.inspectResolvers.push({ mediaId: media.id, resolve, reject });
    });
  }

  convert(input: MediaFile, config: ConversionConfig): void {
    this.post({
      type: "convert",
      job: {
        input: serializeMedia(input),
        config
      }
    });
  }

  cancel(): void {
    this.post({ type: "cancel" });
  }

  terminate(): void {
    this.worker?.terminate();
    this.worker = null;
  }

  private post(request: FfmpegWorkerRequest): void {
    const worker = this.ensureWorker();
    worker.postMessage(request);
  }

  private ensureWorker(): Worker {
    if (this.worker) return this.worker;
    this.worker = new Worker(new URL("./ffmpegWorker.ts", import.meta.url), {
      type: "module"
    });
    this.worker.addEventListener("message", (event: MessageEvent<FfmpegWorkerResponse>) => {
      const normalized = normalizeResponse(event.data);
      this.settlePendingInspect(normalized);
      this.emit(normalized);
    });
    this.worker.addEventListener("error", (event) => {
      this.emit({
        type: "error",
        message: event.message || "The FFmpeg worker failed."
      });
    });
    return this.worker;
  }

  private emit(event: ClientEvent): void {
    for (const listener of this.listeners) {
      listener(event);
    }
  }

  private settlePendingInspect(event: ClientEvent): void {
    if (event.type === "inspected") {
      const index = this.inspectResolvers.findIndex((resolver) => resolver.mediaId === event.media.id);
      const resolver = index >= 0 ? this.inspectResolvers.splice(index, 1)[0] : undefined;
      resolver?.resolve(event.media);
    } else if (event.type === "error") {
      const resolvers = this.inspectResolvers.splice(0);
      for (const resolver of resolvers) {
        resolver.reject(new Error(event.message));
      }
    }
  }
}

function normalizeResponse(response: FfmpegWorkerResponse): ClientEvent {
  if (response.type === "converted") {
    return response;
  }
  return response;
}

function serializeMedia(media: MediaFile): SerializableMediaFile {
  return {
    id: media.id,
    file: media.file,
    originalFilename: media.originalFilename,
    category: media.category,
    sizeOnDisk: media.sizeOnDisk,
    dimensions: media.dimensions,
    duration: media.duration,
    fps: media.fps,
    bitrate: media.bitrate,
    audioBitrate: media.audioBitrate,
    videoCodec: media.videoCodec,
    audioCodec: media.audioCodec,
    containerFormat: media.containerFormat,
    mimeType: media.mimeType
  };
}

export const ffmpegClient = new FfmpegClient();
