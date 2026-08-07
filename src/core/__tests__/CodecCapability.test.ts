import {
  canDecodeVideo,
  canEncode,
  decodeIssueVideo,
  encoderName,
  unsupportedReason,
} from '@/src/core/compatibility/CodecCapability';
import { MIN_PACKAGE_RUNTIME } from '@/src/core/models/types';

describe('CodecCapability (min package)', () => {
  it('maps MP4 H.264 / HEVC / MOV to VideoToolbox encoders', () => {
    expect(encoderName('mp4_h264', MIN_PACKAGE_RUNTIME)).toBe('h264_videotoolbox');
    expect(encoderName('mp4_hevc', MIN_PACKAGE_RUNTIME)).toBe('hevc_videotoolbox');
    expect(encoderName('mov', MIN_PACKAGE_RUNTIME)).toBe('h264_videotoolbox');
    expect(canEncode('mp4_h264', MIN_PACKAGE_RUNTIME)).toBe(true);
  });

  it('maps common audio/image encoders available in min', () => {
    expect(encoderName('m4a', MIN_PACKAGE_RUNTIME)).toBe('aac');
    expect(encoderName('aac', MIN_PACKAGE_RUNTIME)).toBe('aac');
    expect(encoderName('wav', MIN_PACKAGE_RUNTIME)).toBe('pcm_s16le');
    expect(encoderName('flac', MIN_PACKAGE_RUNTIME)).toBe('flac');
    expect(encoderName('jpg', MIN_PACKAGE_RUNTIME)).toBe('mjpeg');
    expect(encoderName('png', MIN_PACKAGE_RUNTIME)).toBe('png');
  });

  it('disables WebM / MP3 / OGG without external libraries', () => {
    expect(encoderName('webm', MIN_PACKAGE_RUNTIME)).toBeNull();
    expect(encoderName('mp3', MIN_PACKAGE_RUNTIME)).toBeNull();
    expect(encoderName('ogg', MIN_PACKAGE_RUNTIME)).toBeNull();
    expect(unsupportedReason('webm', MIN_PACKAGE_RUNTIME)).toMatch(/libvpx/);
    expect(unsupportedReason('mp3', MIN_PACKAGE_RUNTIME)).toMatch(/libmp3lame/);
  });

  it('flags AV1 as undecodable on min package', () => {
    expect(canDecodeVideo('av1')).toBe(false);
    expect(decodeIssueVideo('av01')?.reason).toMatch(/AV1/);
    expect(canDecodeVideo('h264')).toBe(true);
  });

  it('enables libvpx when runtime reports the library', () => {
    expect(
      encoderName('webm', { packageName: 'full', externalLibraries: ['libvpx'] })
    ).toBe('libvpx-vp9');
  });
});
