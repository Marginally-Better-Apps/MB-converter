import { allowedOutputs, defaultOutput, detectCategory } from '@/src/core/compatibility/FormatMatrix';
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
