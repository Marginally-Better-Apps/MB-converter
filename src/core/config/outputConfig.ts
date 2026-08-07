import { categoryOf } from '@/src/core/ffmpeg/outputFormatArgs';
import type {
  ConversionConfig,
  MediaFile,
  OutputFormat,
  Size,
} from '@/src/core/models/types';
import { DEFAULT_METADATA_POLICY } from '@/src/core/models/types';

export type ResolutionOption = {
  id: string;
  label: string;
  dimensions?: Size;
};

export type FPSOption = {
  id: string;
  label: string;
  value?: number;
};

export type ValidationResult = { ok: true } | { ok: false; message: string };

const RESOLUTION_PRESETS: Array<{ id: string; label: string; shortEdge: number }> = [
  { id: '2K', label: '2K', shortEdge: 1440 },
  { id: '1080p', label: '1080p', shortEdge: 1080 },
  { id: '720p', label: '720p', shortEdge: 720 },
  { id: '480p', label: '480p', shortEdge: 480 },
  { id: '360p', label: '360p', shortEdge: 360 },
];

export function isLossy(format: OutputFormat): boolean {
  switch (format) {
    case 'mp4_h264':
    case 'mp4_hevc':
    case 'mov':
    case 'webm':
    case 'gif':
    case 'mp3':
    case 'm4a':
    case 'aac':
    case 'ogg':
    case 'opus':
    case 'jpg':
    case 'heic':
    case 'webpImage':
      return true;
    case 'wav':
    case 'flac':
    case 'png':
    case 'tiff':
      return false;
  }
}

/** Lossless formats (and WebP quality mode) cannot guarantee an arbitrary target size. */
export function supportsTargetSize(format: OutputFormat): boolean {
  if (format === 'webpImage') return false;
  return isLossy(format);
}

export function scaledDimensions(presetShortEdge: number, source: Size): Size {
  const shortEdge = Math.min(source.width, source.height);
  if (shortEdge <= 0) return source;
  const scale = Math.min(1, presetShortEdge / shortEdge);
  return {
    width: Math.round(source.width * scale),
    height: Math.round(source.height * scale),
  };
}

export function resolutionOptions(source?: Size): ResolutionOption[] {
  if (!source) return [];
  const sourceShortEdge = Math.min(source.width, source.height);
  const options: ResolutionOption[] = [
    { id: 'original', label: 'Original', dimensions: undefined },
  ];
  for (const preset of RESOLUTION_PRESETS) {
    if (sourceShortEdge > preset.shortEdge) {
      options.push({
        id: preset.id,
        label: preset.label,
        dimensions: scaledDimensions(preset.shortEdge, source),
      });
    }
  }
  options.push({ id: 'custom', label: 'Custom', dimensions: undefined });
  return options;
}

export function fpsOptions(sourceFps?: number): FPSOption[] {
  if (sourceFps == null || !(sourceFps > 0)) return [];
  const options: FPSOption[] = [
    {
      id: 'original',
      label: `${formatFpsLabel(sourceFps)} (Source)`,
      value: undefined,
    },
  ];
  for (const fps of [60, 30, 24, 15]) {
    if (fps > Math.ceil(sourceFps)) continue;
    if (Math.abs(fps - sourceFps) < 0.01) continue;
    options.push({ id: String(fps), label: String(fps), value: fps });
  }
  return options;
}

function formatFpsLabel(fps: number): string {
  const rounded = Math.round(fps);
  if (Math.abs(fps - rounded) < 0.01) return `${rounded} fps`;
  return `${fps.toFixed(1)} fps`;
}

export function validateResolution(target: Size, source: Size): ValidationResult {
  if (!(target.width > 0) || !(target.height > 0)) {
    return { ok: false, message: 'Resolution must be positive.' };
  }
  if (target.width > source.width || target.height > source.height) {
    return { ok: false, message: 'Resolution cannot exceed the source.' };
  }
  return { ok: true };
}

export function validateFps(target: number, sourceFps: number): ValidationResult {
  if (!(target > 0)) {
    return { ok: false, message: 'FPS must be positive.' };
  }
  if (target > sourceFps + 0.01) {
    return { ok: false, message: 'FPS cannot exceed the source.' };
  }
  return { ok: true };
}

export function validateTargetSizeBytes(
  targetBytes: number | undefined,
  sourceBytes: number
): ValidationResult {
  if (targetBytes == null) {
    return { ok: false, message: 'Target size is required.' };
  }
  if (!(targetBytes > 0)) {
    return { ok: false, message: 'Target size must be greater than zero.' };
  }
  if (targetBytes > sourceBytes) {
    return { ok: false, message: 'Target size cannot exceed the source file size.' };
  }
  return { ok: true };
}

export function targetSizeBytesFromFraction(sourceBytes: number, fraction: number): number {
  const clamped = Math.min(1, Math.max(0, fraction));
  return Math.max(1, Math.floor(sourceBytes * clamped));
}

export function remuxHintLabel(
  prefersRemuxWhenPossible: boolean,
  canRemux: boolean
): string | null {
  if (!prefersRemuxWhenPossible) return null;
  if (canRemux) {
    return 'Max target: remux compatible streams without re-encoding.';
  }
  return 'Max target: remux if compatible; otherwise re-encode.';
}

export function defaultConversionConfig(
  input: MediaFile,
  outputFormat: OutputFormat
): ConversionConfig {
  const category = categoryOf(outputFormat);
  const canTarget = supportsTargetSize(outputFormat);
  return {
    outputFormat,
    targetSizeBytes: canTarget ? Math.max(1, input.sizeOnDisk) : undefined,
    targetFPS: undefined,
    targetDimensions: undefined,
    videoQuality: category === 'video' ? 1 : undefined,
    imageQuality: category === 'image' ? (outputFormat === 'webpImage' ? 0.82 : 1) : undefined,
    usesSinglePassVideoTargetEncode: category === 'video',
    prefersRemuxWhenPossible: canTarget,
    operationMode: 'manual',
    metadata: { ...DEFAULT_METADATA_POLICY },
  };
}

export function shouldShowResolution(
  input: MediaFile,
  outputFormat: OutputFormat
): boolean {
  return categoryOf(outputFormat) !== 'audio' && input.dimensions != null;
}

export function shouldShowFps(input: MediaFile, outputFormat: OutputFormat): boolean {
  return categoryOf(outputFormat) === 'video' && input.fps != null;
}
