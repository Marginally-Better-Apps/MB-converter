import { buildVideoCommands, shouldRemuxVideo } from '@/src/core/ffmpeg/videoCommandBuilder';
import { quoteFFmpegPath } from '@/src/core/ffmpeg/quote';
import type { ConversionConfig, MediaFile } from '@/src/core/models/types';
import { DEFAULT_METADATA_POLICY } from '@/src/core/models/types';

const inputPath = '/tmp/sample in.mp4';
const outputPath = '/tmp/out.mp4';
const passLogPath = '/tmp/pass.log';
const pass1DiscardPath = '/tmp/pass1.mp4';

function videoInput(overrides: Partial<MediaFile> = {}): MediaFile {
  return {
    path: inputPath,
    category: 'video',
    sizeOnDisk: 10_000_000,
    dimensions: { width: 1920, height: 1080 },
    duration: 30,
    fps: 30,
    bitrate: 5_000_000,
    audioBitrate: 128_000,
    videoCodec: 'h264',
    audioCodec: 'aac',
    containerFormat: 'mp4',
    ...overrides,
  };
}

function mp4Config(overrides: Partial<ConversionConfig> = {}): ConversionConfig {
  return {
    outputFormat: 'mp4_h264',
    usesSinglePassVideoTargetEncode: true,
    metadata: DEFAULT_METADATA_POLICY,
    ...overrides,
  };
}

describe('videoCommandBuilder golden strings (ported from VideoConverter.swift)', () => {
  it('builds single-pass H.264 VideoToolbox encode with AAC + faststart + strip metadata', () => {
    const commands = buildVideoCommands({
      input: videoInput(),
      config: mp4Config(),
      outputPath,
      passLogPath,
      pass1DiscardPath,
      videoKbps: 2000,
      audioBitrateKbps: 128,
    });

    const quotedIn = quoteFFmpegPath(inputPath);
    const quotedOut = quoteFFmpegPath(outputPath);

    expect(commands).toEqual({
      mode: 'singlePass',
      singlePass: `-y -i ${quotedIn} -c:v h264_videotoolbox -b:v 2000k -c:a aac -b:a 128k -f mp4 -movflags +faststart -map_metadata -1 -map_chapters -1 ${quotedOut}`,
    });
  });

  it('omits audio encode args when input has no audio track', () => {
    const commands = buildVideoCommands({
      input: videoInput({ audioCodec: undefined, audioBitrate: undefined }),
      config: mp4Config(),
      outputPath,
      passLogPath,
      pass1DiscardPath,
      videoKbps: 1500,
      audioBitrateKbps: 0,
    });

    expect(commands.mode).toBe('singlePass');
    if (commands.mode !== 'singlePass') return;
    expect(commands.singlePass).toContain(' -an ');
    expect(commands.singlePass).not.toContain('-c:a');
  });

  it('adds scale filter and fps when targets are set', () => {
    const commands = buildVideoCommands({
      input: videoInput(),
      config: mp4Config({
        targetDimensions: { width: 1280, height: 720 },
        targetFPS: 24,
      }),
      outputPath,
      passLogPath,
      pass1DiscardPath,
      videoKbps: 1000,
      audioBitrateKbps: 96,
    });

    expect(commands.mode).toBe('singlePass');
    if (commands.mode !== 'singlePass') return;
    expect(commands.singlePass).toContain(' -vf scale=1280:720');
    expect(commands.singlePass).toContain(' -r 24');
  });

  it('does not add -r when target FPS is not lower than source', () => {
    const commands = buildVideoCommands({
      input: videoInput({ fps: 24 }),
      config: mp4Config({ targetFPS: 30 }),
      outputPath,
      passLogPath,
      pass1DiscardPath,
      videoKbps: 1000,
      audioBitrateKbps: 96,
    });

    expect(commands.mode).toBe('singlePass');
    if (commands.mode !== 'singlePass') return;
    expect(commands.singlePass).not.toContain(' -r ');
  });

  it('builds two-pass H.264 commands matching Swift pass1/pass2 shape', () => {
    const commands = buildVideoCommands({
      input: videoInput(),
      config: mp4Config({ usesSinglePassVideoTargetEncode: false }),
      outputPath,
      passLogPath,
      pass1DiscardPath,
      videoKbps: 1800,
      audioBitrateKbps: 128,
    });

    const quotedIn = quoteFFmpegPath(inputPath);
    const quotedOut = quoteFFmpegPath(outputPath);
    const quotedLog = quoteFFmpegPath(passLogPath);
    const quotedDiscard = quoteFFmpegPath(pass1DiscardPath);

    expect(commands).toEqual({
      mode: 'twoPass',
      pass1: `-y -i ${quotedIn} -c:v h264_videotoolbox -b:v 1800k -pass 1 -passlogfile ${quotedLog} -an -f mp4 ${quotedDiscard}`,
      pass2: `-y -i ${quotedIn} -c:v h264_videotoolbox -b:v 1800k -pass 2 -passlogfile ${quotedLog} -c:a aac -b:a 128k -f mp4 -movflags +faststart -map_metadata -1 -map_chapters -1 ${quotedOut}`,
    });
  });

  it('builds remux (stream copy) command for compatible H.264/AAC → MP4', () => {
    const commands = buildVideoCommands({
      input: videoInput({ videoCodec: 'avc1', audioCodec: 'mp4a' }),
      config: mp4Config({ prefersRemuxWhenPossible: true }),
      outputPath,
      passLogPath,
      pass1DiscardPath,
      videoKbps: 2000,
      audioBitrateKbps: 128,
    });

    const quotedIn = quoteFFmpegPath(inputPath);
    const quotedOut = quoteFFmpegPath(outputPath);

    expect(commands).toEqual({
      mode: 'remux',
      remux: `-y -i ${quotedIn} -map 0:v:0 -map 0:a:0? -c copy -f mp4 -movflags +faststart -map_metadata -1 -map_chapters -1 ${quotedOut}`,
    });
  });

  it('adds HEVC hvc1 tag for mp4_hevc remux/encode', () => {
    const commands = buildVideoCommands({
      input: videoInput({ videoCodec: 'h264', audioCodec: 'aac' }),
      config: {
        outputFormat: 'mp4_hevc',
        usesSinglePassVideoTargetEncode: true,
        metadata: DEFAULT_METADATA_POLICY,
      },
      outputPath,
      passLogPath,
      pass1DiscardPath,
      videoKbps: 2000,
      audioBitrateKbps: 128,
    });

    expect(commands.mode).toBe('singlePass');
    if (commands.mode !== 'singlePass') return;
    expect(commands.singlePass).toContain(' -c:v hevc_videotoolbox');
    expect(commands.singlePass).toContain(' -tag:v hvc1');
  });

  it('shouldRemuxVideo requires remux preference and compatible codecs', () => {
    expect(
      shouldRemuxVideo(videoInput({ videoCodec: 'h264', audioCodec: 'aac' }), mp4Config({ prefersRemuxWhenPossible: true }))
    ).toBe(true);
    expect(
      shouldRemuxVideo(videoInput({ videoCodec: 'vp9', audioCodec: 'aac' }), mp4Config({ prefersRemuxWhenPossible: true }))
    ).toBe(false);
    expect(
      shouldRemuxVideo(
        videoInput({ videoCodec: 'h264', audioCodec: 'aac' }),
        mp4Config({ prefersRemuxWhenPossible: true, targetDimensions: { width: 640, height: 360 } })
      )
    ).toBe(false);
  });

  it('quotes paths that contain spaces and single quotes', () => {
    const awkward = "/tmp/O'Brien clip.mp4";
    const commands = buildVideoCommands({
      input: videoInput({ path: awkward }),
      config: mp4Config(),
      outputPath: "/tmp/out'put.mp4",
      passLogPath,
      pass1DiscardPath,
      videoKbps: 1000,
      audioBitrateKbps: 128,
    });

    expect(commands.mode).toBe('singlePass');
    if (commands.mode !== 'singlePass') return;
    expect(commands.singlePass).toContain(quoteFFmpegPath(awkward));
    expect(commands.singlePass).toContain(quoteFFmpegPath("/tmp/out'put.mp4"));
  });
});
