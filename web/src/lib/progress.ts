import type { Dimensions, EncodingStats } from "./models";

const timePattern = /time=(\d{2}):(\d{2}):(\d{2}(?:\.\d+)?)/;

export function secondsFromFfmpegTime(value: string): number | undefined {
  const match = value.match(/^(\d{2}):(\d{2}):(\d{2}(?:\.\d+)?)$/);
  if (!match) return undefined;
  return Number(match[1]) * 3600 + Number(match[2]) * 60 + Number(match[3]);
}

export function parseEncodingStats(line: string): EncodingStats | undefined {
  if (!line.includes("time=") && !line.includes("frame=")) {
    return undefined;
  }
  const frame = line.match(/frame=\s*(\d+)/)?.[1];
  const fps = line.match(/\bfps=\s*([0-9.]+)/)?.[1];
  const encodedSize = line.match(/\bsize=\s*([^\s]+)/)?.[1];
  const time = line.match(timePattern)?.[0].replace("time=", "");
  const throughputBitrate = line.match(/\bbitrate=\s*([^\s]+)/)?.[1];
  const speed = line.match(/\bspeed=\s*([^\s]+)/)?.[1];
  return {
    frame: frame ? Number(frame) : undefined,
    fps: fps ? Number(fps) : undefined,
    encodedSize,
    time,
    timeMilliseconds: time ? Math.round((secondsFromFfmpegTime(time) ?? 0) * 1000) : undefined,
    throughputBitrate,
    speed
  };
}

export const parseProgressLine = parseEncodingStats;
export type EncodingDisplayStats = EncodingStats;

export function progressFromStats(stats: EncodingStats, duration?: number): number | undefined {
  if (!duration || duration <= 0 || stats.timeMilliseconds === undefined) {
    return undefined;
  }
  return Math.min(1, Math.max(0, stats.timeMilliseconds / 1000 / duration));
}

export function parseDurationFromProbe(output: string): number | undefined {
  const match = output.match(/Duration:\s*(\d{2}):(\d{2}):(\d{2}(?:\.\d+)?)/i);
  if (!match) return undefined;
  return Number(match[1]) * 3600 + Number(match[2]) * 60 + Number(match[3]);
}

export interface ParsedMediaMetadata {
  dimensions?: Dimensions;
  duration?: number;
  fps?: number;
  bitrate?: number;
  audioBitrate?: number;
  videoCodec?: string;
  audioCodec?: string;
  containerFormat?: string;
}

export function parseStreamMetadata(value: unknown): ParsedMediaMetadata {
  const root = value as {
    streams?: Array<Record<string, unknown>>;
    format?: Record<string, unknown>;
  };
  const streams = Array.isArray(root.streams) ? root.streams : [];
  const video = streams.find((stream) => stream.codec_type === "video");
  const audio = streams.find((stream) => stream.codec_type === "audio");
  const duration = numberFromUnknown(root.format?.duration)
    ?? numberFromUnknown(video?.duration)
    ?? numberFromUnknown(audio?.duration);
  const bitrate = intFromUnknown(root.format?.bit_rate);
  const audioBitrate = intFromUnknown(audio?.bit_rate);
  const width = intFromUnknown(video?.width);
  const height = intFromUnknown(video?.height);
  return {
    dimensions: width && height ? { width, height } : undefined,
    duration,
    fps: parseFrameRate(String(video?.avg_frame_rate ?? video?.r_frame_rate ?? "")),
    bitrate,
    audioBitrate,
    videoCodec: stringFromUnknown(video?.codec_name),
    audioCodec: stringFromUnknown(audio?.codec_name),
    containerFormat: stringFromUnknown(root.format?.format_name)?.split(",")[0]
  };
}

function parseFrameRate(value: string): number | undefined {
  if (!value || value === "0/0") return undefined;
  const [lhs, rhs] = value.split("/").map(Number);
  if (Number.isFinite(lhs) && Number.isFinite(rhs) && rhs > 0) {
    return lhs / rhs;
  }
  const direct = Number(value);
  return Number.isFinite(direct) && direct > 0 ? direct : undefined;
}

function numberFromUnknown(value: unknown): number | undefined {
  const parsed = typeof value === "number" ? value : Number(value);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : undefined;
}

function intFromUnknown(value: unknown): number | undefined {
  const parsed = numberFromUnknown(value);
  return parsed === undefined ? undefined : Math.round(parsed);
}

function stringFromUnknown(value: unknown): string | undefined {
  return typeof value === "string" && value.trim() ? value.trim() : undefined;
}
