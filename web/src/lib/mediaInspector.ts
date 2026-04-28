import { defaultCodecCapabilities } from "./codecCapabilities";
import { detectCategory, extensionOf } from "./formatMatrix";
import { ffmpegClient } from "./ffmpegClient";
import type { MediaFile } from "./models";

export async function createMediaFile(file: File): Promise<MediaFile> {
  const category = detectCategory(file.name, file.type);
  if (!category) {
    throw new Error("This file type is not supported yet.");
  }

  const objectUrl = URL.createObjectURL(file);
  const base: MediaFile = {
    id: crypto.randomUUID(),
    file,
    objectUrl,
    originalFilename: file.name,
    category,
    sizeOnDisk: file.size,
    containerFormat: extensionOf(file.name),
    mimeType: file.type || undefined
  };

  try {
    const nativeMetadata = await inspectWithBrowser(objectUrl, category);
    return {
      ...base,
      ...nativeMetadata,
      bitrate:
        nativeMetadata.duration && nativeMetadata.duration > 0
          ? Math.round((file.size * 8) / nativeMetadata.duration)
          : undefined
    };
  } catch {
    try {
      const probed = (await ffmpegClient.inspectMedia(base)) as Partial<MediaFile>;
      return {
        ...base,
        ...probed
      };
    } catch {
      return base;
    }
  }
}

export function isImportLikelySupported(file: File): boolean {
  const category = detectCategory(file.name, file.type);
  if (!category) return false;
  if (category === "image" || category === "animatedImage") return true;
  return defaultCodecCapabilities.loaded || file.size < 2 * 1024 * 1024 * 1024;
}

function inspectWithBrowser(
  objectUrl: string,
  category: MediaFile["category"]
): Promise<Partial<MediaFile>> {
  if (category === "animatedImage" || category === "image") {
    return new Promise((resolve, reject) => {
      const image = new Image();
      image.onload = () => resolve({ dimensions: { width: image.naturalWidth, height: image.naturalHeight } });
      image.onerror = () => reject(new Error("Image metadata unavailable."));
      image.src = objectUrl;
    });
  }

  if (category === "audio") {
    return new Promise((resolve, reject) => {
      const audio = document.createElement("audio");
      audio.preload = "metadata";
      audio.onloadedmetadata = () => {
        resolve({ duration: finitePositive(audio.duration) });
      };
      audio.onerror = () => reject(new Error("Audio metadata unavailable."));
      audio.src = objectUrl;
    });
  }

  return new Promise((resolve, reject) => {
    const video = document.createElement("video");
    video.preload = "metadata";
    video.onloadedmetadata = () => {
      resolve({
        duration: finitePositive(video.duration),
        dimensions:
          video.videoWidth > 0 && video.videoHeight > 0
            ? { width: video.videoWidth, height: video.videoHeight }
            : undefined
      });
    };
    video.onerror = () => reject(new Error("Video metadata unavailable."));
    video.src = objectUrl;
  });
}

function finitePositive(value: number): number | undefined {
  return Number.isFinite(value) && value > 0 ? value : undefined;
}
