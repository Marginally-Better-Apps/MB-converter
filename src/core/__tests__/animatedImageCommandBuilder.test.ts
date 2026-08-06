import { buildAnimatedImageToVideoCommands } from '@/src/core/ffmpeg/animatedImageCommandBuilder';
import { quoteFFmpegPath } from '@/src/core/ffmpeg/quote';
import { DEFAULT_METADATA_POLICY } from '@/src/core/models/types';

describe('animatedImageCommandBuilder golden strings (ported from AnimatedImageConverter.swift)', () => {
  const inputPath = '/tmp/anim.gif';
  const outputPath = '/tmp/out.mp4';
  const passLogPath = '/tmp/pass.log';
  const pass1DiscardPath = '/tmp/pass1.mp4';

  it('builds single-pass GIF→MP4 H.264 with yuv420p and no audio', () => {
    const commands = buildAnimatedImageToVideoCommands({
      inputPath,
      outputPath,
      passLogPath,
      pass1DiscardPath,
      outputFormat: 'mp4_h264',
      videoKbps: 1200,
      targetDimensions: { width: 480, height: 270 },
      targetFPS: 15,
      usesSinglePass: true,
      metadata: DEFAULT_METADATA_POLICY,
    });

    const quotedIn = quoteFFmpegPath(inputPath);
    const quotedOut = quoteFFmpegPath(outputPath);

    expect(commands).toEqual({
      mode: 'singlePass',
      singlePass: `-y -i ${quotedIn} -vf scale=480:270 -r 15 -c:v h264_videotoolbox -b:v 1200k -pix_fmt yuv420p -an -f mp4 -map_metadata -1 -map_chapters -1 ${quotedOut}`,
    });
  });

  it('builds two-pass GIF→MP4 commands', () => {
    const commands = buildAnimatedImageToVideoCommands({
      inputPath,
      outputPath,
      passLogPath,
      pass1DiscardPath,
      outputFormat: 'mp4_h264',
      videoKbps: 800,
      usesSinglePass: false,
      metadata: DEFAULT_METADATA_POLICY,
    });

    expect(commands.mode).toBe('twoPass');
    if (commands.mode !== 'twoPass') return;
    expect(commands.pass1).toContain('-pass 1');
    expect(commands.pass1).toContain('-pix_fmt yuv420p');
    expect(commands.pass1).toContain(' -an ');
    expect(commands.pass2).toContain('-pass 2');
    expect(commands.pass2).toContain('-pix_fmt yuv420p');
    expect(commands.pass2).toContain(' -an');
  });
});
