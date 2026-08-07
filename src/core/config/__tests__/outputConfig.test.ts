import {
  defaultConversionConfig,
  fpsOptions,
  isLossy,
  remuxHintLabel,
  resolutionOptions,
  supportsTargetSize,
  targetSizeBytesFromFraction,
  validateFps,
  validateResolution,
  validateTargetSizeBytes,
} from '@/src/core/config/outputConfig';
import type { MediaFile } from '@/src/core/models/types';

const videoInput: MediaFile = {
  path: '/tmp/clip.mp4',
  category: 'video',
  sizeOnDisk: 10_000_000,
  dimensions: { width: 1920, height: 1080 },
  duration: 30,
  fps: 30,
  videoCodec: 'avc1',
  audioCodec: 'mp4a',
  containerFormat: 'mp4',
};

describe('outputConfig helpers', () => {
  it('marks lossy vs lossless and target-size support', () => {
    expect(isLossy('mp4_h264')).toBe(true);
    expect(isLossy('png')).toBe(false);
    expect(supportsTargetSize('mp4_h264')).toBe(true);
    expect(supportsTargetSize('png')).toBe(false);
    expect(supportsTargetSize('webpImage')).toBe(false);
  });

  it('builds resolution presets below the source short edge', () => {
    const options = resolutionOptions({ width: 1920, height: 1080 });
    expect(options[0]).toMatchObject({ id: 'original', dimensions: undefined });
    expect(options.some((o) => o.id === '720p')).toBe(true);
    expect(options.some((o) => o.id === '1080p')).toBe(false);
    expect(options.some((o) => o.id === 'custom')).toBe(true);
  });

  it('builds fps options at or below source fps', () => {
    const options = fpsOptions(30);
    expect(options[0]?.value).toBeUndefined();
    expect(options.map((o) => o.value).filter(Boolean)).toEqual([24, 15]);
  });

  it('validates resolution, fps, and target size', () => {
    expect(validateResolution({ width: 1280, height: 720 }, { width: 1920, height: 1080 }).ok).toBe(
      true
    );
    expect(validateResolution({ width: 4000, height: 2000 }, { width: 1920, height: 1080 }).ok).toBe(
      false
    );
    expect(validateFps(24, 30).ok).toBe(true);
    expect(validateFps(60, 30).ok).toBe(false);
    expect(validateTargetSizeBytes(1_000_000, 10_000_000).ok).toBe(true);
    expect(validateTargetSizeBytes(0, 10_000_000).ok).toBe(false);
    expect(validateTargetSizeBytes(20_000_000, 10_000_000).ok).toBe(false);
  });

  it('computes target bytes and remux hint', () => {
    expect(targetSizeBytesFromFraction(10_000_000, 0.5)).toBe(5_000_000);
    expect(targetSizeBytesFromFraction(10_000_000, 1)).toBe(10_000_000);
    expect(remuxHintLabel(true, true)).toMatch(/remux/i);
    expect(remuxHintLabel(true, false)).toMatch(/re-encode/i);
    expect(remuxHintLabel(false, false)).toBeNull();
  });

  it('builds default conversion config for video', () => {
    const config = defaultConversionConfig(videoInput, 'mp4_h264');
    expect(config.outputFormat).toBe('mp4_h264');
    expect(config.targetSizeBytes).toBe(10_000_000);
    expect(config.prefersRemuxWhenPossible).toBe(true);
    expect(config.metadata?.stripAll).toBe(true);
    expect(config.usesSinglePassVideoTargetEncode).toBe(true);
  });
});
