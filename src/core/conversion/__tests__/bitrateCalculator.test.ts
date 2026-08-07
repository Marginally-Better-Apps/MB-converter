import {
  audioBitrateKbps,
  capAudioEncodeKbps,
  estimatedSize,
  maximumAudioTargetBytes,
  minimumAudioTargetBytes,
  minimumVideoBitrateKbps,
  qualityDrivenVideoBitrateKbps,
  snappedAudioBitrate,
  sourceVideoBitrateBps,
  suggestedAudioBitrate,
  videoBitrateKbps,
} from '@/src/core/conversion/bitrateCalculator';

describe('BitrateCalculator', () => {
  it('computes video bitrate for a target size', () => {
    const kbps = videoBitrateKbps({
      targetBytes: 10_000_000,
      durationSec: 60,
      audioBitrateKbps: 128,
    });
    expect(kbps).toBeGreaterThan(150);
    // ~10MB / 60s minus audio/overhead ≈ 1200+ kbps range
    expect(kbps).toBeGreaterThan(1000);
    expect(kbps).toBeLessThan(1500);
  });

  it('floors video bitrate at the minimum', () => {
    expect(
      videoBitrateKbps({
        targetBytes: 1000,
        durationSec: 60,
        audioBitrateKbps: 128,
        minimumVideoBitrateKbps: 150,
      })
    ).toBe(150);
  });

  it('snaps audio bitrate to standard CBR ladder', () => {
    expect(snappedAudioBitrate(100)).toBe(96);
    expect(snappedAudioBitrate(140)).toBe(128);
    expect(snappedAudioBitrate(300)).toBe(320);
  });

  it('computes audio bitrate from target bytes', () => {
    // 128 kbps * 10s = 160_000 bytes (before snap)
    const kbps = audioBitrateKbps({ targetBytes: 160_000, durationSec: 10 });
    expect(kbps).toBe(128);
  });

  it('estimates size with mux overhead', () => {
    const bytes = estimatedSize({
      videoBitrateKbps: 1000,
      audioBitrateKbps: 128,
      durationSec: 10,
    });
    // (1128 kbps * 10s * 1000 / 8) * 1.02
    expect(bytes).toBe(Math.floor((1128 * 1000 * 10 * 1.02) / 8));
  });

  it('suggests audio bitrate by total target kbps bands', () => {
    expect(suggestedAudioBitrate({ targetBytes: 100_000, durationSec: 10 })).toBe(64);
    expect(suggestedAudioBitrate({ targetBytes: 500_000, durationSec: 10 })).toBe(96);
    expect(suggestedAudioBitrate({ targetBytes: 2_000_000, durationSec: 10 })).toBe(128);
    expect(suggestedAudioBitrate({ targetBytes: 5_000_000, durationSec: 10 })).toBe(192);
  });

  it('caps audio encode kbps against source and ceiling', () => {
    expect(capAudioEncodeKbps({ requested: 320, sourceBps: 96_000 })).toBe(96);
    expect(capAudioEncodeKbps({ requested: 64, sourceBps: 192_000, maximumKbps: 256 })).toBe(64);
    expect(capAudioEncodeKbps({ requested: 400, sourceBps: null, maximumKbps: 256 })).toBe(256);
  });

  it('derives source video bitrate from total minus audio', () => {
    expect(sourceVideoBitrateBps({ totalBitrateBps: 5_000_000, audioBitrateBps: 128_000 })).toBe(
      4_872_000
    );
    expect(sourceVideoBitrateBps({ totalBitrateBps: null, audioBitrateBps: 128_000 })).toBeNull();
  });

  it('scales minimum video bitrate by resolution and codec family', () => {
    const h264 = minimumVideoBitrateKbps({
      dimensions: { width: 1920, height: 1080 },
      fps: 30,
      outputFormat: 'mp4_h264',
    });
    const hevc = minimumVideoBitrateKbps({
      dimensions: { width: 1920, height: 1080 },
      fps: 30,
      outputFormat: 'mp4_hevc',
    });
    expect(h264).toBeGreaterThan(150);
    expect(hevc).toBeLessThan(h264);
  });

  it('maps quality slider to video bitrate between min and max', () => {
    const dims = { width: 1280, height: 720 };
    const lo = qualityDrivenVideoBitrateKbps({
      quality: 0,
      dimensions: dims,
      fps: 30,
      outputFormat: 'mp4_h264',
    });
    const hi = qualityDrivenVideoBitrateKbps({
      quality: 1,
      dimensions: dims,
      fps: 30,
      outputFormat: 'mp4_h264',
    });
    const mid = qualityDrivenVideoBitrateKbps({
      quality: 0.5,
      dimensions: dims,
      fps: 30,
      outputFormat: 'mp4_h264',
    });
    expect(lo).toBeLessThan(mid);
    expect(mid).toBeLessThan(hi);
  });

  it('computes audio target byte bounds', () => {
    expect(minimumAudioTargetBytes(10)).toBeGreaterThan(0);
    expect(maximumAudioTargetBytes({ durationSec: 10, maxBitrateKbps: 320 })).toBeGreaterThan(
      minimumAudioTargetBytes(10)
    );
  });
});
