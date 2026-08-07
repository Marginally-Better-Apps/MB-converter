import { progressFractionFromFFmpegStats } from '@/src/core/conversion/progressFraction';

describe('progressFractionFromFFmpegStats', () => {
  it('returns null when duration is unknown', () => {
    expect(progressFractionFromFFmpegStats(5_000, null)).toBeNull();
    expect(progressFractionFromFFmpegStats(5_000, undefined)).toBeNull();
    expect(progressFractionFromFFmpegStats(5_000, 0)).toBeNull();
    expect(progressFractionFromFFmpegStats(5_000, -1)).toBeNull();
  });

  it('maps time / duration into 0…1', () => {
    expect(progressFractionFromFFmpegStats(5_000, 10)).toBeCloseTo(0.5);
    expect(progressFractionFromFFmpegStats(0, 10)).toBe(0);
    expect(progressFractionFromFFmpegStats(10_000, 10)).toBe(1);
  });

  it('clamps above 1 and below 0', () => {
    expect(progressFractionFromFFmpegStats(20_000, 10)).toBe(1);
    expect(progressFractionFromFFmpegStats(-100, 10)).toBe(0);
  });
});
