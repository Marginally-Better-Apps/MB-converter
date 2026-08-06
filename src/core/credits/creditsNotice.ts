/**
 * In-app summary of CREDITS.md (FFmpeg LGPL notice).
 * Keep this practical — full legal text lives in the repo file.
 */

export const FFMPEG_PACKAGE = 'tylerjonesio/ffmpeg-kit-spm min.v5.1.2.6';

export const FFMPEG_SOURCE_URL = 'https://ffmpeg.org';

export const FFMPEG_KIT_SPM_URL = 'https://github.com/tylerjonesio/ffmpeg-kit-spm';

export const CREDITS_TITLE = 'Open-source notices';

export const CREDITS_SUMMARY =
  'MB Converter vendors FFmpeg via FFmpegKit (min package). FFmpeg is licensed under LGPL v2.1+ / LGPL v3. Application source remains MIT; FFmpeg and other native dependencies keep their own licenses.';

export const CREDITS_BULLETS = [
  'FFmpeg binaries: LGPL (min build — no GPL-only external codecs such as libx264).',
  'Source: ffmpeg.org. Wrapper packaging: tylerjonesio/ffmpeg-kit-spm.',
  'Full notices: CREDITS.md in the project repository.',
] as const;

export type CreditsNotice = {
  title: string;
  summary: string;
  bullets: readonly string[];
  ffmpegSourceUrl: string;
  ffmpegPackage: string;
};

export function getCreditsNotice(): CreditsNotice {
  return {
    title: CREDITS_TITLE,
    summary: CREDITS_SUMMARY,
    bullets: CREDITS_BULLETS,
    ffmpegSourceUrl: FFMPEG_SOURCE_URL,
    ffmpegPackage: FFMPEG_PACKAGE,
  };
}
