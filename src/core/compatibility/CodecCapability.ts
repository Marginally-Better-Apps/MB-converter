import { displayName } from '@/src/core/ffmpeg/outputFormatArgs';
import type { FFmpegRuntimeSnapshot, OutputFormat } from '@/src/core/models/types';
import { MIN_PACKAGE_RUNTIME } from '@/src/core/models/types';

export type DecodeIssue = {
  codecLabel: string;
  reason: string;
};

export function canEncode(
  format: OutputFormat,
  runtime: FFmpegRuntimeSnapshot = MIN_PACKAGE_RUNTIME
): boolean {
  return encoderName(format, runtime) != null;
}

export function encoderName(
  format: OutputFormat,
  runtime: FFmpegRuntimeSnapshot = MIN_PACKAGE_RUNTIME
): string | null {
  switch (format) {
    case 'mp4_h264':
    case 'mov':
      return 'h264_videotoolbox';
    case 'mp4_hevc':
      return 'hevc_videotoolbox';
    case 'webm':
      return runtimeHasExternalLibrary(runtime, 'libvpx') ? 'libvpx-vp9' : null;
    case 'mp3':
      return runtimeHasExternalLibrary(runtime, 'libmp3lame') ? 'libmp3lame' : null;
    case 'm4a':
    case 'aac':
      return 'aac';
    case 'wav':
      return 'pcm_s16le';
    case 'flac':
      return 'flac';
    case 'ogg':
      return runtimeHasExternalLibrary(runtime, 'libvorbis') ? 'libvorbis' : null;
    case 'opus':
      return runtimeHasExternalLibrary(runtime, 'libopus') ? 'libopus' : 'opus';
    case 'jpg':
      return 'mjpeg';
    case 'png':
      return 'png';
    case 'heic':
      return 'heic';
    case 'webpImage':
      return 'libwebp';
    case 'tiff':
      return 'tiff';
    case 'gif':
      return 'gif';
  }
}

export function unsupportedReason(
  format: OutputFormat,
  runtime: FFmpegRuntimeSnapshot = MIN_PACKAGE_RUNTIME
): string | null {
  if (canEncode(format, runtime)) return null;
  switch (format) {
    case 'webm':
      return 'WebM video output needs the libvpx encoder, which is not included in the bundled FFmpegKit min package.';
    case 'mp3':
      return 'MP3 output needs the libmp3lame encoder, which is not included in the bundled FFmpegKit min package.';
    case 'ogg':
      return 'OGG/Vorbis output needs the libvorbis encoder, which is not included in the bundled FFmpegKit min package.';
    default:
      return `${displayName(format)} output is not available in the bundled FFmpeg runtime.`;
  }
}

export function canDecodeVideo(videoCodec?: string | null): boolean {
  return decodeIssueVideo(videoCodec) == null;
}

export function decodeIssueVideo(videoCodec?: string | null): DecodeIssue | null {
  const codec = normalizedCodec(videoCodec);
  if (!codec) return null;
  if (AV1.has(codec) || codec.startsWith('av01')) {
    return {
      codecLabel: displayCodecLabel(videoCodec),
      reason: 'AV1 video is not decodable by the bundled FFmpegKit min package.',
    };
  }
  return null;
}

export function canDecodeAudio(audioCodec?: string | null): boolean {
  return decodeIssueAudio(audioCodec) == null;
}

export function decodeIssueAudio(audioCodec?: string | null): DecodeIssue | null {
  const codec = normalizedCodec(audioCodec);
  if (!codec) return null;
  if (UNSUPPORTED_AUDIO.has(codec)) {
    return {
      codecLabel: displayCodecLabel(audioCodec),
      reason: `${displayCodecLabel(audioCodec)} audio is not decodable by the bundled FFmpegKit min package.`,
    };
  }
  return null;
}

const AV1 = new Set(['av1', 'av01']);
const UNSUPPORTED_AUDIO = new Set<string>();

function runtimeHasExternalLibrary(runtime: FFmpegRuntimeSnapshot, name: string): boolean {
  const needle = name.trim().toLowerCase();
  return runtime.externalLibraries.some(
    (library) => library.trim().toLowerCase() === needle
  );
}

function normalizedCodec(codec?: string | null): string | null {
  if (!codec) return null;
  const n = codec.trim().toLowerCase();
  return n.length ? n : null;
}

function displayCodecLabel(codec?: string | null): string {
  const trimmed = codec?.trim() ?? '';
  return trimmed.length === 0 ? 'an unknown codec' : trimmed.toUpperCase();
}
