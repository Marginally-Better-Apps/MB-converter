import { conversionEnginePath } from '@/src/core/conversion/conversionRouter';
import { ConversionError } from '@/src/core/conversion/ConversionError';

describe('conversionEnginePath', () => {
  it('routes video → video formats to video', () => {
    expect(conversionEnginePath('video', 'mp4_h264')).toBe('video');
    expect(conversionEnginePath('video', 'mp4_hevc')).toBe('video');
    expect(conversionEnginePath('video', 'mov')).toBe('video');
  });

  it('routes video → audio and audio → audio to audio', () => {
    expect(conversionEnginePath('video', 'm4a')).toBe('audio');
    expect(conversionEnginePath('video', 'wav')).toBe('audio');
    expect(conversionEnginePath('audio', 'm4a')).toBe('audio');
    expect(conversionEnginePath('audio', 'aac')).toBe('audio');
  });

  it('routes image → image to image', () => {
    expect(conversionEnginePath('image', 'jpg')).toBe('image');
    expect(conversionEnginePath('image', 'png')).toBe('image');
    expect(conversionEnginePath('image', 'heic')).toBe('image');
    expect(conversionEnginePath('image', 'tiff')).toBe('image');
    expect(conversionEnginePath('image', 'webpImage')).toBe('image');
  });

  it('routes animatedImage → video or image to animated', () => {
    expect(conversionEnginePath('animatedImage', 'mp4_h264')).toBe('animated');
    expect(conversionEnginePath('animatedImage', 'jpg')).toBe('animated');
    expect(conversionEnginePath('animatedImage', 'png')).toBe('animated');
  });

  it('rejects unsupported pairs', () => {
    expect(() => conversionEnginePath('audio', 'mp4_h264')).toThrow(ConversionError);
    expect(() => conversionEnginePath('image', 'm4a')).toThrow(ConversionError);
    expect(() => conversionEnginePath('video', 'jpg')).toThrow(ConversionError);
  });
});
