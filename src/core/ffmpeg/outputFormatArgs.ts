import type { OutputFormat } from '@/src/core/models/types';

export function fileExtension(format: OutputFormat): string {
  switch (format) {
    case 'mp4_h264':
    case 'mp4_hevc':
      return 'mp4';
    case 'mov':
      return 'mov';
    case 'webm':
      return 'webm';
    case 'gif':
      return 'gif';
    case 'mp3':
      return 'mp3';
    case 'm4a':
      return 'm4a';
    case 'wav':
      return 'wav';
    case 'aac':
      return 'aac';
    case 'flac':
      return 'flac';
    case 'ogg':
      return 'ogg';
    case 'opus':
      return 'opus';
    case 'jpg':
      return 'jpg';
    case 'png':
      return 'png';
    case 'heic':
      return 'heic';
    case 'webpImage':
      return 'webp';
    case 'tiff':
      return 'tiff';
  }
}

export function categoryOf(format: OutputFormat): 'video' | 'audio' | 'image' | 'animatedImage' {
  switch (format) {
    case 'mp4_h264':
    case 'mp4_hevc':
    case 'mov':
    case 'webm':
      return 'video';
    case 'gif':
      return 'animatedImage';
    case 'mp3':
    case 'm4a':
    case 'wav':
    case 'aac':
    case 'flac':
    case 'ogg':
    case 'opus':
      return 'audio';
    case 'jpg':
    case 'png':
    case 'heic':
    case 'webpImage':
    case 'tiff':
      return 'image';
  }
}

export function ffmpegFirstPassMuxerArg(format: OutputFormat): string {
  switch (format) {
    case 'webm':
      return ' -f webm';
    case 'mov':
      return ' -f mov';
    case 'mp4_h264':
    case 'mp4_hevc':
      return ' -f mp4';
    default:
      return ' -f mp4';
  }
}

export function ffmpegOutputMuxerArg(format: OutputFormat): string {
  switch (format) {
    case 'webm':
      return ' -f webm';
    case 'mov':
      return ' -f mov';
    case 'mp4_h264':
    case 'mp4_hevc':
      return ' -f mp4';
    case 'mp3':
      return ' -f mp3';
    case 'm4a':
      return ' -f mp4';
    case 'wav':
      return ' -f wav';
    case 'aac':
      return ' -f adts';
    case 'flac':
      return ' -f flac';
    case 'ogg':
    case 'opus':
      return ' -f ogg';
    case 'jpg':
      return ' -f mjpeg';
    case 'png':
      return ' -f image2';
    case 'heic':
      return ' -f heif';
    case 'webpImage':
      return ' -f webp';
    case 'tiff':
      return ' -f image2';
    case 'gif':
      return ' -f gif';
  }
}

export function ffmpegHEVCContainerTagArg(format: OutputFormat): string {
  return format === 'mp4_hevc' ? ' -tag:v hvc1' : '';
}

export function displayName(format: OutputFormat): string {
  switch (format) {
    case 'mp4_h264':
      return 'MP4 (H.264)';
    case 'mp4_hevc':
      return 'MP4 (HEVC)';
    case 'mov':
      return 'MOV';
    case 'webm':
      return 'WebM';
    case 'gif':
      return 'GIF';
    case 'mp3':
      return 'MP3';
    case 'm4a':
      return 'M4A';
    case 'wav':
      return 'WAV';
    case 'aac':
      return 'AAC';
    case 'flac':
      return 'FLAC';
    case 'ogg':
      return 'OGG';
    case 'opus':
      return 'Opus';
    case 'jpg':
      return 'JPEG';
    case 'png':
      return 'PNG';
    case 'heic':
      return 'HEIC';
    case 'webpImage':
      return 'WebP';
    case 'tiff':
      return 'TIFF';
  }
}

const H264 = new Set(['avc1', 'avc3', 'h264']);
const HEVC = new Set(['hvc1', 'hev1', 'hevc']);
const AAC = new Set(['mp4a', 'aac']);
const MOV_AUDIO = new Set(['alac', 'lpcm', 'sowt', 'twos']);
const WAV_PCM = new Set(['lpcm', 'sowt', 'twos']);
const MP3 = new Set(['mp3', 'mp3float', 'mp3fixed']);
const FLAC = new Set(['flac']);
const VORBIS = new Set(['vorbis']);
const OPUS = new Set(['opus']);

function normalizedCodec(codec?: string | null): string | null {
  if (!codec) return null;
  const n = codec.trim().toLowerCase();
  return n.length ? n : null;
}

export function supportsVideoRemux(format: OutputFormat): boolean {
  return format === 'mp4_h264' || format === 'mp4_hevc' || format === 'mov';
}

export function canRemuxVideoCodec(format: OutputFormat, codec?: string | null): boolean {
  const id = normalizedCodec(codec);
  if (!supportsVideoRemux(format) || !id) return false;
  switch (format) {
    case 'mp4_h264':
      return H264.has(id);
    case 'mp4_hevc':
      return HEVC.has(id);
    case 'mov':
      return H264.has(id) || HEVC.has(id);
    default:
      return false;
  }
}

export function canRemuxAudioCodec(format: OutputFormat, codec?: string | null): boolean {
  const id = normalizedCodec(codec);
  if (!id) return true;
  switch (format) {
    case 'mp4_h264':
    case 'mp4_hevc':
      return AAC.has(id);
    case 'mov':
      return AAC.has(id) || MOV_AUDIO.has(id);
    default:
      return false;
  }
}

export function canRemuxStandaloneAudioCodec(
  format: OutputFormat,
  codec?: string | null,
  inputContainer?: string | null
): boolean {
  if (categoryOf(format) !== 'audio') return false;
  const id = normalizedCodec(codec);
  if (!id) return false;
  const container = normalizedCodec(inputContainer) ?? '';

  switch (format) {
    case 'm4a':
      return AAC.has(id) || MOV_AUDIO.has(id);
    case 'aac':
      return AAC.has(id);
    case 'wav':
      return WAV_PCM.has(id) || id.startsWith('pcm_');
    case 'mp3':
      return MP3.has(id);
    case 'flac':
      return FLAC.has(id);
    case 'ogg':
      return VORBIS.has(id);
    case 'opus':
      return OPUS.has(id) && (container === 'ogg' || container === 'opus');
    default:
      return false;
  }
}
