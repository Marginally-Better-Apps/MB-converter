import { metadataOutputFlags } from '@/src/core/ffmpeg/metadataOptions';
import { ffmpegOutputMuxerArg } from '@/src/core/ffmpeg/outputFormatArgs';
import { quoteFFmpegPath } from '@/src/core/ffmpeg/quote';
import type { MetadataExportPolicy, OutputFormat } from '@/src/core/models/types';

export type AudioFFmpegEncodeInput = {
  inputPath: string;
  outputPath: string;
  outputFormat: OutputFormat;
  audioCodec: string;
  bitrateKbps: number | null;
  treatAsLossyForBitrateArg: boolean;
  metadata: MetadataExportPolicy;
};

export function buildAudioFFmpegCommand(params: AudioFFmpegEncodeInput): string {
  const inputPath = quoteFFmpegPath(params.inputPath);
  const outputPath = quoteFFmpegPath(params.outputPath);
  const addBitrate = params.treatAsLossyForBitrateArg && (params.bitrateKbps ?? 0) > 0;
  const bitrateArg = addBitrate ? ` -b:a ${params.bitrateKbps}k` : '';
  const formatArgs = ffmpegAudioFormatArguments(params.outputFormat);
  const meta = metadataOutputFlags(params.metadata);
  return `-y -i ${inputPath} -vn -map 0:a:0 -c:a ${params.audioCodec}${bitrateArg}${formatArgs}${ffmpegOutputMuxerArg(params.outputFormat)}${meta} ${outputPath}`;
}

export function buildAudioRemuxCommand(params: {
  inputPath: string;
  outputPath: string;
  outputFormat: OutputFormat;
  metadata: MetadataExportPolicy;
}): string {
  const inputPath = quoteFFmpegPath(params.inputPath);
  const outputPath = quoteFFmpegPath(params.outputPath);
  const meta = metadataOutputFlags(params.metadata);
  return `-y -i ${inputPath} -vn -map 0:a:0 -c copy${ffmpegOutputMuxerArg(params.outputFormat)}${meta} ${outputPath}`;
}

function ffmpegAudioFormatArguments(format: OutputFormat): string {
  switch (format) {
    case 'mp3':
      return ' -ac 2 -ar 48000';
    case 'm4a':
      return ' -ac 2';
    default:
      return '';
  }
}
