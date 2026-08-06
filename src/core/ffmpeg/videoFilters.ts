import type { ConversionConfig, CropRegion, MediaFile, Size } from '@/src/core/models/types';

export function evenDimensions(width: number, height: number): Size | null {
  let w = Math.trunc(width);
  let h = Math.trunc(height);
  if (w < 2 || h < 2) return null;
  w -= w % 2;
  h -= h % 2;
  if (w < 2 || h < 2) return null;
  return { width: w, height: h };
}

export function videoFilters(input: MediaFile, config: ConversionConfig): string {
  const filters: string[] = [];

  if (config.cropRegion) {
    const crop = cropFilter(input, config.cropRegion);
    if (crop) filters.push(crop);
  }

  if (config.targetDimensions) {
    const dims = evenDimensions(
      Math.round(config.targetDimensions.width),
      Math.round(config.targetDimensions.height)
    );
    if (dims) filters.push(`scale=${dims.width}:${dims.height}`);
  }

  if (filters.length === 0) return '';
  return ` -vf ${filters.join(',')}`;
}

export function fpsArgument(input: MediaFile, config: ConversionConfig): string {
  const target = config.targetFPS;
  const source = input.fps;
  if (target == null || source == null || !(target < source)) return '';
  return ` -r ${target}`;
}

function cropFilter(input: MediaFile, crop: CropRegion): string | null {
  const source = input.dimensions;
  if (!source) return null;
  const clamped = clampCrop(crop, source);
  if (!clamped || isEffectivelyFullFrame(clamped, source)) return null;

  const sourceWidth = Math.round(source.width);
  const sourceHeight = Math.round(source.height);
  if (sourceWidth <= 1 || sourceHeight <= 1) return null;

  let width = Math.max(2, Math.round(clamped.width));
  let height = Math.max(2, Math.round(clamped.height));
  width -= width % 2;
  height -= height % 2;
  width = Math.min(width, sourceWidth - (sourceWidth % 2));
  height = Math.min(height, sourceHeight - (sourceHeight % 2));

  let x = Math.max(0, Math.round(clamped.x));
  let y = Math.max(0, Math.round(clamped.y));
  x = Math.min(x, Math.max(0, sourceWidth - width));
  y = Math.min(y, Math.max(0, sourceHeight - height));
  x -= x % 2;
  y -= y % 2;

  return `crop=${width}:${height}:${x}:${y}`;
}

function clampCrop(crop: CropRegion, source: Size, minimumSize = 8): CropRegion | null {
  if (source.width <= 0 || source.height <= 0) return null;
  const maxWidth = source.width;
  const maxHeight = source.height;
  const minSize = Math.min(minimumSize, maxWidth, maxHeight);
  const nextWidth = Math.min(Math.max(crop.width, minSize), maxWidth);
  const nextHeight = Math.min(Math.max(crop.height, minSize), maxHeight);
  const nextX = Math.min(Math.max(0, crop.x), maxWidth - nextWidth);
  const nextY = Math.min(Math.max(0, crop.y), maxHeight - nextHeight);
  return {
    x: Math.round(nextX),
    y: Math.round(nextY),
    width: Math.round(nextWidth),
    height: Math.round(nextHeight),
  };
}

function isEffectivelyFullFrame(crop: CropRegion, source: Size): boolean {
  return (
    crop.x === 0 &&
    crop.y === 0 &&
    crop.width === Math.round(source.width) &&
    crop.height === Math.round(source.height)
  );
}
