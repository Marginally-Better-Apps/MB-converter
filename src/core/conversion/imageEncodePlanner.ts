import { ConversionError } from '@/src/core/conversion/ConversionError';
import type { OutputFormat } from '@/src/core/models/types';

export type ImageEncodeAttempt = {
  byteSize: number;
  outputUri: string;
};

export type BinarySearchImageQualityParams = {
  targetBytes: number;
  encode: (quality: number) => Promise<ImageEncodeAttempt>;
  iterations?: number;
  isCancelled?: () => boolean;
  onProgress?: (fraction: number) => void;
  /** Initial search bounds (defaults match Swift ImageConverter). */
  lo?: number;
  hi?: number;
};

export type BinarySearchImageQualityResult = ImageEncodeAttempt & {
  quality: number;
};

export function defaultImageEncodeQuality(params: {
  hasTargetSize: boolean;
  format: OutputFormat;
}): number {
  if (params.format === 'webpImage') return 0.82;
  if (!params.hasTargetSize) return 0.92;
  return 0.82;
}

export function nextQualityBounds(params: {
  lo: number;
  hi: number;
  quality: number;
  underTarget: boolean;
}): { lo: number; hi: number } {
  if (params.underTarget) {
    return { lo: params.quality, hi: params.hi };
  }
  return { lo: params.lo, hi: params.quality };
}

/**
 * Binary-search the quality coefficient to land at-or-just-under `targetBytes`.
 * Prefers undershoot to overshoot (compression use case). Port of Swift ImageConverter.encodeWithTarget.
 */
export async function binarySearchImageQuality(
  params: BinarySearchImageQualityParams
): Promise<BinarySearchImageQualityResult> {
  const iterations = params.iterations ?? 12;
  let lo = params.lo ?? 0.05;
  let hi = params.hi ?? 1.0;
  let best: BinarySearchImageQualityResult | null = null;
  let lastAttempt: BinarySearchImageQualityResult | null = null;

  for (let i = 0; i < iterations; i++) {
    if (params.isCancelled?.()) {
      throw ConversionError.cancelled();
    }
    const quality = (lo + hi) / 2;
    const attempt = await params.encode(quality);
    lastAttempt = { ...attempt, quality };

    if (attempt.byteSize <= params.targetBytes) {
      best = lastAttempt;
      ({ lo, hi } = nextQualityBounds({ lo, hi, quality, underTarget: true }));
    } else {
      ({ lo, hi } = nextQualityBounds({ lo, hi, quality, underTarget: false }));
    }
    params.onProgress?.((i + 1) / iterations);
  }

  if (best) return best;

  // Couldn't get under target — encode once more at the lowest tried quality (matches Swift).
  if (params.isCancelled?.()) {
    throw ConversionError.cancelled();
  }
  const fallbackQuality = lo;
  const fallback = await params.encode(fallbackQuality);
  return { ...fallback, quality: fallbackQuality };
}
