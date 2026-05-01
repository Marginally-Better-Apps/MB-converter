import type { Dimensions, MediaFile, OutputFormat } from "./models";

export function clamp(value: number, min: number, max: number): number {
  return Math.min(max, Math.max(min, value));
}

export function scaledDimensions(source: Dimensions, shortEdge: number): Dimensions {
  const minEdge = Math.min(source.width, source.height);
  if (minEdge <= 0 || minEdge <= shortEdge) {
    return source;
  }
  const scale = shortEdge / minEdge;
  return evenDimensions({
    width: Math.round(source.width * scale),
    height: Math.round(source.height * scale)
  });
}

export function evenDimensions(dimensions: Dimensions): Dimensions {
  return {
    width: Math.max(2, Math.round(dimensions.width / 2) * 2),
    height: Math.max(2, Math.round(dimensions.height / 2) * 2)
  };
}

export function bitrateKbps(targetBytes: number, durationSeconds: number, reservedAudioKbps = 0): number {
  if (!Number.isFinite(durationSeconds) || durationSeconds <= 0) {
    return 0;
  }
  const totalKbps = Math.floor((targetBytes * 8) / durationSeconds / 1000);
  return Math.max(24, totalKbps - reservedAudioKbps);
}

export function audioBitrateKbps(targetBytes: number, durationSeconds: number): number {
  if (!Number.isFinite(durationSeconds) || durationSeconds <= 0) {
    return 128;
  }
  return clamp(Math.floor((targetBytes * 8) / durationSeconds / 1000), 32, 320);
}

export function defaultAudioKbps(input: MediaFile, outputFormat: OutputFormat): number {
  if (outputFormat === "wav") {
    return 1411;
  }
  if (outputFormat === "flac") {
    return Math.min(1000, Math.max(320, Math.round((input.audioBitrate ?? input.bitrate ?? 640000) / 1000)));
  }
  return clamp(Math.round((input.audioBitrate ?? input.bitrate ?? 160000) / 1000), 64, 192);
}

export function targetBytesForFraction(inputSize: number, fraction: number, minimum = 8 * 1024): number {
  return Math.max(minimum, Math.round(inputSize * clamp(fraction, 0.02, 1)));
}
