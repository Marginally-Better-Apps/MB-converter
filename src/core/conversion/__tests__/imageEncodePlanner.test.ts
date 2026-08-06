import {
  binarySearchImageQuality,
  defaultImageEncodeQuality,
  nextQualityBounds,
} from '@/src/core/conversion/imageEncodePlanner';
import { ConversionError } from '@/src/core/conversion/ConversionError';

describe('imageEncodePlanner', () => {
  it('defaultImageEncodeQuality uses high quality without a target', () => {
    expect(defaultImageEncodeQuality({ hasTargetSize: false, format: 'jpg' })).toBe(0.92);
    expect(defaultImageEncodeQuality({ hasTargetSize: false, format: 'webpImage' })).toBe(0.82);
  });

  it('nextQualityBounds raises floor when under target', () => {
    expect(nextQualityBounds({ lo: 0.05, hi: 1, quality: 0.5, underTarget: true })).toEqual({
      lo: 0.5,
      hi: 1,
    });
  });

  it('nextQualityBounds lowers ceiling when over target', () => {
    expect(nextQualityBounds({ lo: 0.05, hi: 1, quality: 0.5, underTarget: false })).toEqual({
      lo: 0.05,
      hi: 0.5,
    });
  });

  it('binary-searches quality to land at or under target bytes', async () => {
    // Synthetic encoder: byteSize ≈ quality * 1000
    const encode = jest.fn(async (quality: number) => ({
      byteSize: Math.round(quality * 1000),
      outputUri: `file:///tmp/q-${quality.toFixed(4)}.jpg`,
    }));

    const result = await binarySearchImageQuality({
      targetBytes: 500,
      iterations: 12,
      encode,
    });

    expect(result.byteSize).toBeLessThanOrEqual(500);
    expect(encode).toHaveBeenCalledTimes(12);
    expect(result.quality).toBeGreaterThan(0.4);
    expect(result.quality).toBeLessThan(0.6);
  });

  it('returns lowest-quality encode when target is unreachable', async () => {
    const encode = jest.fn(async (quality: number) => ({
      byteSize: 10_000 + Math.round(quality * 100),
      outputUri: `file:///tmp/big-${quality}.jpg`,
    }));

    const result = await binarySearchImageQuality({
      targetBytes: 100,
      iterations: 8,
      encode,
    });

    expect(result.byteSize).toBeGreaterThan(100);
    expect(result.quality).toBeLessThan(0.2);
  });

  it('throws cancelled when isCancelled becomes true mid-search', async () => {
    let calls = 0;
    await expect(
      binarySearchImageQuality({
        targetBytes: 500,
        iterations: 12,
        isCancelled: () => {
          calls += 1;
          return calls > 3;
        },
        encode: async (quality) => ({
          byteSize: Math.round(quality * 1000),
          outputUri: `file:///tmp/${quality}.jpg`,
        }),
      })
    ).rejects.toThrow(ConversionError);
  });

  it('reports progress across iterations', async () => {
    const onProgress = jest.fn();
    await binarySearchImageQuality({
      targetBytes: 500,
      iterations: 4,
      onProgress,
      encode: async (quality) => ({
        byteSize: Math.round(quality * 1000),
        outputUri: `file:///tmp/${quality}.jpg`,
      }),
    });
    expect(onProgress).toHaveBeenCalledTimes(4);
    expect(onProgress).toHaveBeenLastCalledWith(1);
  });
});
