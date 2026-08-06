import { encoderName } from '@/src/core/compatibility/CodecCapability';
import { metadataOutputFlags } from '@/src/core/ffmpeg/metadataOptions';
import {
  ffmpegFirstPassMuxerArg,
  ffmpegHEVCContainerTagArg,
  ffmpegOutputMuxerArg,
} from '@/src/core/ffmpeg/outputFormatArgs';
import { quoteFFmpegPath } from '@/src/core/ffmpeg/quote';
import { evenDimensions } from '@/src/core/ffmpeg/videoFilters';
import type { MetadataExportPolicy, OutputFormat, Size } from '@/src/core/models/types';
import { MIN_PACKAGE_RUNTIME } from '@/src/core/models/types';

export type AnimatedImageCommandInput = {
  inputPath: string;
  outputPath: string;
  passLogPath: string;
  pass1DiscardPath: string;
  outputFormat: OutputFormat;
  videoKbps: number;
  targetDimensions?: Size;
  targetFPS?: number;
  sourceFPS?: number;
  usesSinglePass: boolean;
  metadata: MetadataExportPolicy;
};

export type AnimatedImageCommands =
  | { mode: 'singlePass'; singlePass: string }
  | { mode: 'twoPass'; pass1: string; pass2: string };

export function buildAnimatedImageToVideoCommands(
  params: AnimatedImageCommandInput
): AnimatedImageCommands {
  const codec = encoderName(params.outputFormat, MIN_PACKAGE_RUNTIME);
  if (!codec) {
    throw new Error(`No encoder available for ${params.outputFormat}`);
  }

  const hevcTag = ffmpegHEVCContainerTagArg(params.outputFormat);
  const pixelFormat = params.outputFormat === 'webm' ? '' : ' -pix_fmt yuv420p';
  const filters = animatedVideoFilters(params.targetDimensions);
  const fps = animatedFpsArgument(params.targetFPS, params.sourceFPS);
  const inputPath = quoteFFmpegPath(params.inputPath);
  const outputPath = quoteFFmpegPath(params.outputPath);
  const logPath = quoteFFmpegPath(params.passLogPath);
  const outputMuxer = ffmpegOutputMuxerArg(params.outputFormat);
  const pass1DiscardPath = quoteFFmpegPath(params.pass1DiscardPath);
  const pass2Meta = metadataOutputFlags(params.metadata);

  if (params.usesSinglePass) {
    return {
      mode: 'singlePass',
      singlePass: `-y -i ${inputPath}${filters}${fps} -c:v ${codec}${hevcTag} -b:v ${params.videoKbps}k${pixelFormat} -an${outputMuxer}${pass2Meta} ${outputPath}`,
    };
  }

  const pass1 = `-y -i ${inputPath}${filters}${fps} -c:v ${codec}${hevcTag} -b:v ${params.videoKbps}k -pass 1 -passlogfile ${logPath}${pixelFormat} -an${ffmpegFirstPassMuxerArg(params.outputFormat)} ${pass1DiscardPath}`;
  const pass2 = `-y -i ${inputPath}${filters}${fps} -c:v ${codec}${hevcTag} -b:v ${params.videoKbps}k -pass 2 -passlogfile ${logPath}${pixelFormat} -an${outputMuxer}${pass2Meta} ${outputPath}`;
  return { mode: 'twoPass', pass1, pass2 };
}

function animatedVideoFilters(target?: Size): string {
  if (!target) return '';
  const dims = evenDimensions(Math.round(target.width), Math.round(target.height));
  if (!dims) return '';
  return ` -vf scale=${dims.width}:${dims.height}`;
}

function animatedFpsArgument(targetFPS?: number, sourceFPS?: number): string {
  const fps = targetFPS ?? sourceFPS;
  if (fps == null) return '';
  return ` -r ${fps}`;
}
