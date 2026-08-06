import { buildAudioFFmpegCommand, buildAudioRemuxCommand } from '@/src/core/ffmpeg/audioCommandBuilder';
import { quoteFFmpegPath } from '@/src/core/ffmpeg/quote';
import { DEFAULT_METADATA_POLICY } from '@/src/core/models/types';

describe('audioCommandBuilder golden strings (ported from AudioConverter.swift)', () => {
  const inputPath = '/tmp/in.mov';
  const outputPath = '/tmp/out.m4a';

  it('builds AAC M4A transcode with stereo normalize', () => {
    const command = buildAudioFFmpegCommand({
      inputPath,
      outputPath,
      outputFormat: 'm4a',
      audioCodec: 'aac',
      bitrateKbps: 192,
      treatAsLossyForBitrateArg: true,
      metadata: DEFAULT_METADATA_POLICY,
    });

    expect(command).toBe(
      `-y -i ${quoteFFmpegPath(inputPath)} -vn -map 0:a:0 -c:a aac -b:a 192k -ac 2 -f mp4 -map_metadata -1 -map_chapters -1 ${quoteFFmpegPath(outputPath)}`
    );
  });

  it('builds WAV PCM encode without bitrate arg', () => {
    const command = buildAudioFFmpegCommand({
      inputPath,
      outputPath: '/tmp/out.wav',
      outputFormat: 'wav',
      audioCodec: 'pcm_s16le',
      bitrateKbps: null,
      treatAsLossyForBitrateArg: false,
      metadata: DEFAULT_METADATA_POLICY,
    });

    expect(command).toBe(
      `-y -i ${quoteFFmpegPath(inputPath)} -vn -map 0:a:0 -c:a pcm_s16le -f wav -map_metadata -1 -map_chapters -1 ${quoteFFmpegPath('/tmp/out.wav')}`
    );
  });

  it('builds audio remux (stream copy) command', () => {
    const command = buildAudioRemuxCommand({
      inputPath,
      outputPath,
      outputFormat: 'm4a',
      metadata: DEFAULT_METADATA_POLICY,
    });

    expect(command).toBe(
      `-y -i ${quoteFFmpegPath(inputPath)} -vn -map 0:a:0 -c copy -f mp4 -map_metadata -1 -map_chapters -1 ${quoteFFmpegPath(outputPath)}`
    );
  });
});
