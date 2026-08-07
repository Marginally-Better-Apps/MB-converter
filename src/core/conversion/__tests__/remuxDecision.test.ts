import { shouldRemuxAudio } from '@/src/core/conversion/remuxDecision';
import { shouldRemuxVideo } from '@/src/core/ffmpeg/videoCommandBuilder';
import type { ConversionConfig, MediaFile } from '@/src/core/models/types';

function audioInput(overrides: Partial<MediaFile> = {}): MediaFile {
  return {
    path: '/tmp/in.m4a',
    category: 'audio',
    sizeOnDisk: 1_000_000,
    duration: 30,
    audioCodec: 'aac',
    containerFormat: 'm4a',
    ...overrides,
  };
}

function config(overrides: Partial<ConversionConfig> = {}): ConversionConfig {
  return {
    outputFormat: 'm4a',
    prefersRemuxWhenPossible: true,
    ...overrides,
  };
}

describe('remux decision helpers', () => {
  it('shouldRemuxVideo is true only when remux preferred and codecs compatible', () => {
    const video: MediaFile = {
      path: '/tmp/in.mp4',
      category: 'video',
      sizeOnDisk: 5_000_000,
      duration: 10,
      videoCodec: 'h264',
      audioCodec: 'aac',
      containerFormat: 'mp4',
    };
    expect(
      shouldRemuxVideo(video, { outputFormat: 'mp4_h264', prefersRemuxWhenPossible: true })
    ).toBe(true);
    expect(
      shouldRemuxVideo(video, { outputFormat: 'mp4_h264', prefersRemuxWhenPossible: false })
    ).toBe(false);
  });

  it('shouldRemuxAudio requires remux preference and compatible standalone codec', () => {
    expect(shouldRemuxAudio(audioInput(), config())).toBe(true);
    expect(shouldRemuxAudio(audioInput({ audioCodec: 'mp3' }), config())).toBe(false);
    expect(
      shouldRemuxAudio(audioInput(), config({ prefersRemuxWhenPossible: false }))
    ).toBe(false);
    expect(shouldRemuxAudio(audioInput(), config({ outputFormat: 'wav' }))).toBe(false);
  });

  it('shouldRemuxAudio works for video → audio when audio track is remuxable', () => {
    const video: MediaFile = {
      path: '/tmp/in.mp4',
      category: 'video',
      sizeOnDisk: 5_000_000,
      duration: 10,
      videoCodec: 'h264',
      audioCodec: 'aac',
      containerFormat: 'mp4',
    };
    expect(shouldRemuxAudio(video, config({ outputFormat: 'm4a' }))).toBe(true);
    expect(shouldRemuxAudio(video, config({ outputFormat: 'wav' }))).toBe(false);
  });
});
