import {
  CREDITS_BULLETS,
  CREDITS_SUMMARY,
  CREDITS_TITLE,
  FFMPEG_PACKAGE,
  FFMPEG_SOURCE_URL,
  getCreditsNotice,
} from '../creditsNotice';

describe('getCreditsNotice', () => {
  it('summarizes FFmpeg LGPL notice for Settings / Credits UI', () => {
    const notice = getCreditsNotice();

    expect(notice.title).toBe(CREDITS_TITLE);
    expect(notice.summary).toContain('LGPL');
    expect(notice.summary).toBe(CREDITS_SUMMARY);
    expect(notice.ffmpegSourceUrl).toBe(FFMPEG_SOURCE_URL);
    expect(notice.ffmpegPackage).toContain('ffmpeg-kit-spm');
    expect(notice.ffmpegPackage).toBe(FFMPEG_PACKAGE);
    expect(notice.bullets.length).toBeGreaterThanOrEqual(2);
    expect(notice.bullets).toEqual([...CREDITS_BULLETS]);
    expect(notice.bullets.some((b) => /CREDITS\.md/i.test(b))).toBe(true);
  });
});
