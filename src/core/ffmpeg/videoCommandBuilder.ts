import { encoderName } from '@/src/core/compatibility/CodecCapability';
import { metadataOutputFlags } from '@/src/core/ffmpeg/metadataOptions';
import {
  canRemuxAudioCodec,
  canRemuxVideoCodec,
  ffmpegFirstPassMuxerArg,
  ffmpegHEVCContainerTagArg,
  ffmpegOutputMuxerArg,
} from '@/src/core/ffmpeg/outputFormatArgs';
import { quoteFFmpegPath } from '@/src/core/ffmpeg/quote';
import { fpsArgument, videoFilters } from '@/src/core/ffmpeg/videoFilters';
import type { ConversionConfig, MediaFile, MetadataExportPolicy } from '@/src/core/models/types';
import { DEFAULT_METADATA_POLICY, MIN_PACKAGE_RUNTIME } from '@/src/core/models/types';

export type VideoCommandBuildInput = {
  input: MediaFile;
  config: ConversionConfig;
  outputPath: string;
  passLogPath: string;
  pass1DiscardPath: string;
  videoKbps: number;
  audioBitrateKbps: number;
};

export type VideoCommands =
  | { mode: 'remux'; remux: string }
  | { mode: 'singlePass'; singlePass: string }
  | { mode: 'twoPass'; pass1: string; pass2: string };

export function shouldRemuxVideo(input: MediaFile, config: ConversionConfig): boolean {
  return (
    !!config.prefersRemuxWhenPossible &&
    config.cropRegion == null &&
    config.targetDimensions == null &&
    config.targetFPS == null &&
    canRemuxVideoCodec(config.outputFormat, input.videoCodec) &&
    canRemuxAudioCodec(config.outputFormat, input.audioCodec)
  );
}

export function buildVideoCommands(params: VideoCommandBuildInput): VideoCommands {
  const { input, config } = params;
  const metadata = config.metadata ?? DEFAULT_METADATA_POLICY;

  if (shouldRemuxVideo(input, config)) {
    return { mode: 'remux', remux: buildRemuxCommand(input.path, params.outputPath, config, metadata) };
  }

  const videoCodec = encoderName(config.outputFormat, MIN_PACKAGE_RUNTIME);
  if (!videoCodec) {
    throw new Error(`No encoder available for ${config.outputFormat}`);
  }

  const hasAudio = input.audioCodec != null;
  const hevcTag = ffmpegHEVCContainerTagArg(config.outputFormat);
  const audioCodec =
    config.outputFormat === 'webm'
      ? encoderName('opus', MIN_PACKAGE_RUNTIME) ?? 'opus'
      : encoderName('m4a', MIN_PACKAGE_RUNTIME) ?? 'aac';
  const audioArguments = hasAudio
    ? ` -c:a ${audioCodec} -b:a ${params.audioBitrateKbps}k`
    : ' -an';
  const filters = videoFilters(input, config);
  const fps = fpsArgument(input, config);
  const inputPath = quoteFFmpegPath(input.path);
  const outputPath = quoteFFmpegPath(params.outputPath);
  const logPath = quoteFFmpegPath(params.passLogPath);
  const fastStart = config.outputFormat === 'webm' ? '' : ' -movflags +faststart';
  const outputMuxer = ffmpegOutputMuxerArg(config.outputFormat);
  const pass1DiscardPath = quoteFFmpegPath(params.pass1DiscardPath);
  const pass2Meta = metadataOutputFlags(metadata);

  if (config.usesSinglePassVideoTargetEncode) {
    return {
      mode: 'singlePass',
      singlePass: `-y -i ${inputPath}${filters}${fps} -c:v ${videoCodec}${hevcTag} -b:v ${params.videoKbps}k${audioArguments}${outputMuxer}${fastStart}${pass2Meta} ${outputPath}`,
    };
  }

  const pass1 = `-y -i ${inputPath}${filters}${fps} -c:v ${videoCodec}${hevcTag} -b:v ${params.videoKbps}k -pass 1 -passlogfile ${logPath} -an${ffmpegFirstPassMuxerArg(config.outputFormat)} ${pass1DiscardPath}`;
  const pass2 = `-y -i ${inputPath}${filters}${fps} -c:v ${videoCodec}${hevcTag} -b:v ${params.videoKbps}k -pass 2 -passlogfile ${logPath}${audioArguments}${outputMuxer}${fastStart}${pass2Meta} ${outputPath}`;
  return { mode: 'twoPass', pass1, pass2 };
}

function buildRemuxCommand(
  inputPathRaw: string,
  outputPathRaw: string,
  config: ConversionConfig,
  metadata: MetadataExportPolicy
): string {
  const inputPath = quoteFFmpegPath(inputPathRaw);
  const outputPath = quoteFFmpegPath(outputPathRaw);
  const outputMuxer = ffmpegOutputMuxerArg(config.outputFormat);
  const fastStart = config.outputFormat === 'webm' ? '' : ' -movflags +faststart';
  const hevcTag = ffmpegHEVCContainerTagArg(config.outputFormat);
  const meta = metadataOutputFlags(metadata);
  return `-y -i ${inputPath} -map 0:v:0 -map 0:a:0? -c copy${hevcTag}${outputMuxer}${fastStart}${meta} ${outputPath}`;
}
