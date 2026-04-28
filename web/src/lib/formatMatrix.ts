import { MediaCategory, OutputFormat, outputFormatDetails } from "./models";

export const supportedVideoExtensions = [
  "mjpeg",
  "mjpg",
  "webm",
  "mkv",
  "ts",
  "mts",
  "m2ts",
  "3gp",
  "hevc",
  "mp4",
  "m4v",
  "mov",
  "avi",
  "mpeg",
  "mpg",
  "f4v",
  "flv",
  "m2v",
  "mxf",
  "ogv",
  "vob",
  "asf",
  "wmv",
  "wtv",
  "swf",
  "av1",
  "ivf"
] as const;

export const supportedAudioExtensions = [
  "mp3",
  "m4a",
  "wav",
  "aac",
  "flac",
  "ogg",
  "opus",
  "alac",
  "aiff",
  "aif",
  "wma",
  "amr"
] as const;

export const supportedImageExtensions = [
  "jpg",
  "jpeg",
  "png",
  "heic",
  "heif",
  "webp",
  "avif",
  "tif",
  "tiff",
  "bmp"
] as const;

const videoSet = new Set<string>(supportedVideoExtensions);
const audioSet = new Set<string>(supportedAudioExtensions);
const imageSet = new Set<string>(supportedImageExtensions);

const mimePrefixes: Array<[string, MediaCategory]> = [
  ["video/", "video"],
  ["audio/", "audio"],
  ["image/", "image"]
];

export function extensionOf(filename: string): string {
  const withoutQuery = filename.split(/[?#]/)[0] ?? filename;
  const basename = withoutQuery.split(/[\\/]/).pop() ?? withoutQuery;
  const dot = basename.lastIndexOf(".");
  return dot >= 0 ? basename.slice(dot + 1).toLowerCase() : "";
}

export function detectCategory(filename: string, mimeType = ""): MediaCategory | null {
  const ext = extensionOf(filename);
  if (ext === "gif") return "animatedImage";
  if (videoSet.has(ext)) return "video";
  if (audioSet.has(ext)) return "audio";
  if (imageSet.has(ext)) return "image";

  const normalizedMime = mimeType.toLowerCase();
  if (normalizedMime === "image/gif") return "animatedImage";
  for (const [prefix, category] of mimePrefixes) {
    if (normalizedMime.startsWith(prefix)) return category;
  }
  return null;
}

export interface CapabilityLookup {
  canEncode(format: OutputFormat): boolean;
}

const baseAllowedOutputs: Record<MediaCategory, OutputFormat[]> = {
  video: [
    "mp4_h264",
    "mp4_hevc",
    "mov",
    "webm",
    "m4a",
    "wav",
    "aac",
    "mp3",
    "flac",
    "ogg",
    "opus"
  ],
  audio: ["m4a", "wav", "aac", "mp3", "flac", "ogg", "opus"],
  image: ["jpg", "png", "heic", "webpImage", "tiff", "gif"],
  animatedImage: ["mp4_h264", "mp4_hevc", "webm", "gif", "jpg", "png", "heic", "webpImage", "tiff"]
};

export function allowedOutputs(
  category: MediaCategory,
  capabilities: CapabilityLookup = { canEncode: () => true }
): OutputFormat[] {
  return baseAllowedOutputs[category].filter((format) => capabilities.canEncode(format));
}

export function defaultOutput(
  category: MediaCategory,
  capabilities: CapabilityLookup = { canEncode: () => true }
): OutputFormat {
  const fallback: Record<MediaCategory, OutputFormat> = {
    video: "mp4_h264",
    audio: "m4a",
    image: "jpg",
    animatedImage: "mp4_h264"
  };
  const preferred = fallback[category];
  if (capabilities.canEncode(preferred)) return preferred;
  return allowedOutputs(category, capabilities)[0] ?? preferred;
}

export function mimeTypeForFormat(format: OutputFormat): string {
  switch (format) {
    case "mp4_h264":
    case "mp4_hevc":
      return "video/mp4";
    case "mov":
      return "video/quicktime";
    case "webm":
      return "video/webm";
    case "gif":
      return "image/gif";
    case "mp3":
      return "audio/mpeg";
    case "m4a":
      return "audio/mp4";
    case "wav":
      return "audio/wav";
    case "aac":
      return "audio/aac";
    case "flac":
      return "audio/flac";
    case "ogg":
      return "audio/ogg";
    case "opus":
      return "audio/ogg; codecs=opus";
    case "jpg":
      return "image/jpeg";
    case "png":
      return "image/png";
    case "heic":
      return "image/heic";
    case "webpImage":
      return "image/webp";
    case "tiff":
      return "image/tiff";
  }
}

export function outputFilename(inputName: string, format: OutputFormat): string {
  const base = inputName.trim()
    ? inputName.replace(/\.[^.\\/]+$/, "")
    : "converted";
  const safeBase = base.replace(/[/:]/g, "-") || "converted";
  return `${safeBase}.${outputFormatDetails[format].fileExtension}`;
}
