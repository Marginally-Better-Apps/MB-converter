import { allOutputFormats, OutputFormat, outputFormats } from "./models";

export type CodecCapabilitySnapshot = {
  loaded: boolean;
  runtimeLabel: string;
  encoders: Set<string>;
  decoders: Set<string>;
  muxers: Set<string>;
  demuxers: Set<string>;
};

export type SerializableCodecCapabilities = Omit<
  CodecCapabilitySnapshot,
  "encoders" | "decoders" | "muxers" | "demuxers"
> & {
  encoders: string[];
  decoders: string[];
  muxers: string[];
  demuxers: string[];
};

const optimisticBrowserEncoders = new Set([
  "libx264",
  "libx265",
  "mpeg4",
  "libvpx-vp9",
  "aac",
  "pcm_s16le",
  "flac",
  "libmp3lame",
  "libvorbis",
  "libopus",
  "opus",
  "mjpeg",
  "png",
  "libwebp",
  "tiff",
  "gif"
]);

export const defaultCodecCapabilities: CodecCapabilitySnapshot = {
  loaded: false,
  runtimeLabel: "ffmpeg.wasm",
  encoders: optimisticBrowserEncoders,
  decoders: new Set(),
  muxers: new Set(),
  demuxers: new Set()
};

export function deserializeCodecCapabilities(
  value: SerializableCodecCapabilities
): CodecCapabilitySnapshot {
  return {
    loaded: value.loaded,
    runtimeLabel: value.runtimeLabel,
    encoders: new Set(value.encoders),
    decoders: new Set(value.decoders),
    muxers: new Set(value.muxers),
    demuxers: new Set(value.demuxers)
  };
}

export function serializeCodecCapabilities(
  value: CodecCapabilitySnapshot
): SerializableCodecCapabilities {
  return {
    loaded: value.loaded,
    runtimeLabel: value.runtimeLabel,
    encoders: [...value.encoders].sort(),
    decoders: [...value.decoders].sort(),
    muxers: [...value.muxers].sort(),
    demuxers: [...value.demuxers].sort()
  };
}

export function encoderNameFor(format: OutputFormat): string | undefined {
  switch (format) {
    case "mp4_h264":
    case "mov":
      return "libx264";
    case "mp4_hevc":
      return "libx265";
    case "webm":
      return "libvpx-vp9";
    case "mp3":
      return "libmp3lame";
    case "m4a":
    case "aac":
      return "aac";
    case "wav":
      return "pcm_s16le";
    case "flac":
      return "flac";
    case "ogg":
      return "libvorbis";
    case "opus":
      return "libopus";
    case "jpg":
      return "mjpeg";
    case "png":
      return "png";
    case "heic":
      return "heic";
    case "webpImage":
      return "libwebp";
    case "tiff":
      return "tiff";
    case "gif":
      return "gif";
  }
}

export function fallbackEncoderNames(format: OutputFormat): string[] {
  switch (format) {
    case "mp4_h264":
    case "mov":
      return ["libx264", "h264", "mpeg4"];
    case "mp4_hevc":
      return ["libx265", "hevc"];
    case "opus":
      return ["libopus", "opus"];
    case "ogg":
      return ["libvorbis", "vorbis"];
    case "webpImage":
      return ["libwebp", "webp"];
    default: {
      const encoder = encoderNameFor(format);
      return encoder ? [encoder] : [];
    }
  }
}

export function canEncode(
  format: OutputFormat,
  capabilities: CodecCapabilitySnapshot = defaultCodecCapabilities
): boolean {
  const encoders = fallbackEncoderNames(format);
  if (encoders.length === 0) {
    return false;
  }
  if (!capabilities.loaded) {
    return encoders.some((name) => capabilities.encoders.has(name));
  }
  return encoders.some((name) => capabilities.encoders.has(name));
}

export function unsupportedReason(
  format: OutputFormat,
  capabilities: CodecCapabilitySnapshot = defaultCodecCapabilities
): string | undefined {
  if (canEncode(format, capabilities)) {
    return undefined;
  }
  return `${outputFormats[format].displayName} output is not available in the loaded browser FFmpeg runtime.`;
}

export function availableOutputs(
  candidates: OutputFormat[],
  capabilities: CodecCapabilitySnapshot = defaultCodecCapabilities
): OutputFormat[] {
  return candidates.filter((format) => canEncode(format, capabilities));
}

export function advertisedOutputs(
  capabilities: CodecCapabilitySnapshot = defaultCodecCapabilities
): OutputFormat[] {
  return allOutputFormats.filter((format) => canEncode(format, capabilities));
}

export function parseFfmpegList(output: string): Set<string> {
  const values = new Set<string>();
  for (const line of output.split(/\r?\n/)) {
    const match = line.match(/^\s*[A-Z.]{6,}\s+([A-Za-z0-9_]+)\b/);
    if (match) {
      values.add(match[1].toLowerCase());
    }
  }
  return values;
}
