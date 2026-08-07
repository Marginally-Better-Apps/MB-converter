import type { OutputFormat, Size } from '@/src/core/models/types';

/** Container muxer overhead estimate. ~2% is typical for MP4/MOV/WebM. */
export const MUX_OVERHEAD = 0.02;

export const STANDARD_AUDIO_BITRATES = [32, 64, 96, 128, 160, 192, 256, 320] as const;

export const MIN_AUDIO_BITRATE_KBPS = STANDARD_AUDIO_BITRATES[0];
export const MIN_VIDEO_BITRATE_KBPS = 150;
export const DEFAULT_VIDEO_AUDIO_BITRATE_KBPS = 128;

const H264_MIN_BPPF = 0.045;
const HEVC_MIN_BPPF = 0.025;
const AV1_LIKE_MIN_BPPF = 0.018;
const REFERENCE_VIDEO_PIXELS = 1920 * 1080;
const REFERENCE_VIDEO_FPS = 30;
const VIDEO_PIXEL_SCALE_EXPONENT = 0.85;
const SOURCE_VIDEO_BITRATE_CEILING_RATIO = 0.9;

export function maximumAudioEncodeKbps(format: OutputFormat): number {
  if (format === 'm4a') return 256;
  return STANDARD_AUDIO_BITRATES[STANDARD_AUDIO_BITRATES.length - 1];
}

export function videoBitrateKbps(params: {
  targetBytes: number;
  durationSec: number;
  audioBitrateKbps?: number;
  minimumVideoBitrateKbps?: number;
}): number {
  const audioBitrateKbps = params.audioBitrateKbps ?? DEFAULT_VIDEO_AUDIO_BITRATE_KBPS;
  const minimum = params.minimumVideoBitrateKbps ?? MIN_VIDEO_BITRATE_KBPS;
  if (!(params.durationSec > 0)) return minimum;
  const targetBits = params.targetBytes * 8;
  const audioBits = audioBitrateKbps * 1000 * params.durationSec;
  const overhead = targetBits * MUX_OVERHEAD;
  const videoBits = Math.max(0, targetBits - audioBits - overhead);
  const kbps = videoBits / params.durationSec / 1000;
  return Math.max(minimum, Math.round(kbps));
}

export function audioBitrateKbps(params: { targetBytes: number; durationSec: number }): number {
  if (!(params.durationSec > 0)) return 128;
  const targetBits = params.targetBytes * 8;
  const raw = Math.round(targetBits / params.durationSec / 1000);
  return snappedAudioBitrate(raw);
}

export function snappedAudioBitrate(raw: number): number {
  let best: number = STANDARD_AUDIO_BITRATES[0];
  let bestDist = Math.abs(best - raw);
  for (const rate of STANDARD_AUDIO_BITRATES) {
    const dist = Math.abs(rate - raw);
    if (dist < bestDist) {
      best = rate;
      bestDist = dist;
    }
  }
  return best;
}

export function estimatedSize(params: {
  videoBitrateKbps: number;
  audioBitrateKbps: number;
  durationSec: number;
}): number {
  const totalKbps = params.videoBitrateKbps + params.audioBitrateKbps;
  const totalBits = totalKbps * 1000 * params.durationSec;
  const withOverhead = totalBits * (1 + MUX_OVERHEAD);
  return Math.trunc(withOverhead / 8);
}

export function minimumAudioTargetBytes(durationSec: number): number {
  if (!(durationSec > 0)) return 1;
  return Math.ceil((MIN_AUDIO_BITRATE_KBPS * 1000 * durationSec) / 8);
}

export function maximumAudioTargetBytes(params: {
  durationSec: number;
  maxBitrateKbps?: number;
}): number {
  const maxBitrateKbps = params.maxBitrateKbps ?? 320;
  if (!(params.durationSec > 0)) return 1;
  const bits = maxBitrateKbps * 1000 * params.durationSec;
  const withOverhead = bits * (1 + MUX_OVERHEAD);
  return Math.max(1, Math.ceil(withOverhead / 8));
}

export function capAudioEncodeKbps(params: {
  requested: number;
  sourceBps?: number | null;
  maximumKbps?: number | null;
}): number {
  const ceiling = params.maximumKbps ?? STANDARD_AUDIO_BITRATES[STANDARD_AUDIO_BITRATES.length - 1];
  const r = Math.min(ceiling, Math.max(MIN_AUDIO_BITRATE_KBPS, params.requested));
  const bps = params.sourceBps;
  if (bps == null || !(bps > 0)) return r;
  const capKbps = Math.trunc(bps / 1000);
  return Math.min(r, Math.max(1, capKbps));
}

export function sourceVideoBitrateBps(params: {
  totalBitrateBps?: number | null;
  audioBitrateBps?: number | null;
}): number | null {
  if (params.totalBitrateBps == null || !(params.totalBitrateBps > 0)) return null;
  const audioBps = Math.max(0, params.audioBitrateBps ?? 0);
  return Math.max(1, params.totalBitrateBps - audioBps);
}

export function suggestedAudioBitrate(params: {
  targetBytes: number;
  durationSec: number;
}): number {
  if (!(params.durationSec > 0)) return DEFAULT_VIDEO_AUDIO_BITRATE_KBPS;
  const targetTotalKbps = (params.targetBytes * 8) / params.durationSec / 1000;
  if (targetTotalKbps < 300) return 64;
  if (targetTotalKbps < 800) return 96;
  if (targetTotalKbps < 2000) return 128;
  return 192;
}

function minimumBitsPerPixelPerFrame(format: OutputFormat): number {
  switch (format) {
    case 'mp4_hevc':
      return HEVC_MIN_BPPF;
    case 'webm':
      return AV1_LIKE_MIN_BPPF;
    default:
      return H264_MIN_BPPF;
  }
}

function qualityMaximumBitsPerPixelPerFrame(format: OutputFormat): number {
  switch (format) {
    case 'mp4_hevc':
      return 0.1;
    case 'webm':
      return 0.075;
    default:
      return 0.14;
  }
}

export function minimumVideoBitrateKbps(params: {
  dimensions?: Size | null;
  fps?: number | null;
  outputFormat: OutputFormat;
  sourceVideoBitrateBps?: number | null;
}): number {
  const { dimensions, fps } = params;
  if (
    !dimensions ||
    !(dimensions.width > 0) ||
    !(dimensions.height > 0) ||
    fps == null ||
    !(fps > 0)
  ) {
    return MIN_VIDEO_BITRATE_KBPS;
  }

  const pixels = dimensions.width * dimensions.height;
  const pixelScale = Math.pow(pixels / REFERENCE_VIDEO_PIXELS, VIDEO_PIXEL_SCALE_EXPONENT);
  const fpsScale = Math.sqrt(fps / REFERENCE_VIDEO_FPS);
  const referenceKbps =
    (REFERENCE_VIDEO_PIXELS * REFERENCE_VIDEO_FPS * minimumBitsPerPixelPerFrame(params.outputFormat)) /
    1000;
  const uncappedKbps = Math.max(
    MIN_VIDEO_BITRATE_KBPS,
    Math.ceil(referenceKbps * pixelScale * fpsScale)
  );

  const sourceBps = params.sourceVideoBitrateBps;
  if (sourceBps == null || !(sourceBps > 0)) return uncappedKbps;

  const sourceCapKbps = Math.floor((sourceBps * SOURCE_VIDEO_BITRATE_CEILING_RATIO) / 1000);
  return Math.max(MIN_VIDEO_BITRATE_KBPS, Math.min(uncappedKbps, sourceCapKbps));
}

function qualityDrivenMaximumVideoBitrateKbps(params: {
  dimensions?: Size | null;
  fps?: number | null;
  outputFormat: OutputFormat;
  sourceVideoBitrateBps?: number | null;
  minimumKbps: number;
}): number {
  const sourceBps = params.sourceVideoBitrateBps;
  if (sourceBps != null && sourceBps > 0) {
    const sourceKbps = Math.max(params.minimumKbps, Math.round(sourceBps / 1000));
    return Math.max(params.minimumKbps, sourceKbps);
  }

  const dimensions = params.dimensions;
  if (!dimensions || !(dimensions.width > 0) || !(dimensions.height > 0)) {
    return Math.max(params.minimumKbps, 8000);
  }

  const effectiveFPS = Math.max(1, params.fps ?? REFERENCE_VIDEO_FPS);
  const pixels = dimensions.width * dimensions.height;
  const kbps =
    (pixels * effectiveFPS * qualityMaximumBitsPerPixelPerFrame(params.outputFormat)) / 1000;
  return Math.max(params.minimumKbps, Math.ceil(kbps));
}

export function qualityDrivenVideoBitrateKbps(params: {
  quality: number;
  dimensions?: Size | null;
  fps?: number | null;
  outputFormat: OutputFormat;
  sourceVideoBitrateBps?: number | null;
}): number {
  const clampedQuality = Math.min(1, Math.max(0, params.quality));
  const minimumKbps = minimumVideoBitrateKbps(params);
  const maximumKbps = qualityDrivenMaximumVideoBitrateKbps({
    ...params,
    minimumKbps,
  });
  if (maximumKbps <= minimumKbps) return minimumKbps;

  const ratio = maximumKbps / minimumKbps;
  const kbps = minimumKbps * Math.pow(ratio, clampedQuality);
  return Math.max(minimumKbps, Math.min(maximumKbps, Math.round(kbps)));
}
