import {
  allowedOutputs,
  defaultOutput,
  detectCategory,
  detectCategoryFromMime,
  extensionForMime,
} from '@/src/core/compatibility/FormatMatrix';
import { MIN_PACKAGE_RUNTIME } from '@/src/core/models/types';

describe('FormatMatrix', () => {
  it('detects video/audio/image/gif categories from extensions', () => {
    expect(detectCategory('clip.mp4')).toBe('video');
    expect(detectCategory('clip.MOV')).toBe('video');
    expect(detectCategory('track.m4a')).toBe('audio');
    expect(detectCategory('photo.jpg')).toBe('image');
    expect(detectCategory('anim.gif')).toBe('animatedImage');
    expect(detectCategory('weird.xyz')).toBeNull();
  });

  it('detects category from mime / UTI-like type strings', () => {
    expect(detectCategoryFromMime('video/mp4')).toBe('video');
    expect(detectCategoryFromMime('video/quicktime')).toBe('video');
    expect(detectCategoryFromMime('audio/mpeg')).toBe('audio');
    expect(detectCategoryFromMime('audio/x-m4a')).toBe('audio');
    expect(detectCategoryFromMime('image/jpeg')).toBe('image');
    expect(detectCategoryFromMime('image/heic')).toBe('image');
    expect(detectCategoryFromMime('image/gif')).toBe('animatedImage');
    expect(detectCategoryFromMime('image/gif; charset=binary')).toBe('animatedImage');
    expect(detectCategoryFromMime('application/octet-stream')).toBeNull();
    expect(detectCategoryFromMime('public.mpeg-4')).toBe('video');
    expect(detectCategoryFromMime('com.apple.m4a-audio')).toBe('audio');
  });

  it('maps mime types to preferred file extensions', () => {
    expect(extensionForMime('video/quicktime')).toBe('mov');
    expect(extensionForMime('audio/mpeg')).toBe('mp3');
    expect(extensionForMime('image/heif')).toBe('heic');
    expect(extensionForMime('text/plain')).toBeNull();
  });

  it('allows video→MP4 H.264 path and audio extract formats on min runtime', () => {
    const outputs = allowedOutputs('video', MIN_PACKAGE_RUNTIME);
    expect(outputs).toContain('mp4_h264');
    expect(outputs).toContain('mp4_hevc');
    expect(outputs).toContain('mov');
    expect(outputs).toContain('m4a');
    expect(outputs).toContain('wav');
    expect(outputs).toContain('aac');
    expect(outputs).not.toContain('webm');
  });

  it('defaults video input to mp4_h264', () => {
    expect(defaultOutput('video')).toBe('mp4_h264');
    expect(defaultOutput('audio')).toBe('m4a');
    expect(defaultOutput('animatedImage')).toBe('mp4_h264');
  });
});
