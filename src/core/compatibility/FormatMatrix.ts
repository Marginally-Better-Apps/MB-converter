import { canEncode } from '@/src/core/compatibility/CodecCapability';
import type { FFmpegRuntimeSnapshot, MediaCategory, OutputFormat } from '@/src/core/models/types';
import { MIN_PACKAGE_RUNTIME } from '@/src/core/models/types';

export const supportedVideoFilenameExtensions = [
  'mjpeg',
  'mjpg',
  'webm',
  'mkv',
  'ts',
  'mts',
  'm2ts',
  '3gp',
  'hevc',
  'mp4',
  'm4v',
  'mov',
  'avi',
  'mpeg',
  'mpg',
  'f4v',
  'flv',
  'm2v',
  'mxf',
  'ogv',
  'vob',
  'asf',
  'wmv',
  'wtv',
  'swf',
] as const;

export const supportedAudioFilenameExtensions = [
  'mp3',
  'm4a',
  'wav',
  'aac',
  'flac',
  'ogg',
  'opus',
  'alac',
] as const;

const videoExt = new Set<string>(supportedVideoFilenameExtensions);
const audioExt = new Set<string>(supportedAudioFilenameExtensions);

export function allowedOutputs(
  category: MediaCategory,
  runtime: FFmpegRuntimeSnapshot = MIN_PACKAGE_RUNTIME
): OutputFormat[] {
  const formats: OutputFormat[] = (() => {
    switch (category) {
      case 'video':
        return ['mp4_h264', 'mp4_hevc', 'mov', 'm4a', 'wav', 'aac'];
      case 'audio':
        return ['m4a', 'wav', 'aac'];
      case 'image':
        return ['jpg', 'png', 'heic', 'webpImage', 'tiff'];
      case 'animatedImage':
        return ['mp4_h264', 'mp4_hevc', 'jpg', 'png', 'heic', 'tiff'];
    }
  })();
  return formats.filter((format) => canEncode(format, runtime));
}

export function detectCategory(pathOrFilename: string): MediaCategory | null {
  const base = pathOrFilename.split(/[\\/]/).pop() ?? pathOrFilename;
  const dot = base.lastIndexOf('.');
  const ext = dot >= 0 ? base.slice(dot + 1).toLowerCase() : '';
  if (!ext) return null;
  if (videoExt.has(ext)) return 'video';
  if (audioExt.has(ext)) return 'audio';
  if (ext === 'gif') return 'animatedImage';
  if (ext === 'jpg' || ext === 'jpeg' || ext === 'png' || ext === 'heic' || ext === 'webp' || ext === 'tif' || ext === 'tiff' || ext === 'avif') {
    return 'image';
  }
  return null;
}

export function defaultOutput(category: MediaCategory): OutputFormat {
  switch (category) {
    case 'video':
      return 'mp4_h264';
    case 'audio':
      return 'm4a';
    case 'image':
      return 'jpg';
    case 'animatedImage':
      return 'mp4_h264';
  }
}
