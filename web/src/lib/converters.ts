import { audioBitrateKbps, bitrateKbps, defaultAudioKbps, evenDimensions } from "./bitrate";
import { encoderNameFor } from "./codecCapabilities";
import { outputFormatDetails } from "./models";
import type { ConversionConfig, MediaFile, OutputFormat } from "./models";

export interface ConversionStep {
  label: string;
  progressStart: number;
  progressWeight: number;
  args(inputPath: string, outputPath: string): string[];
}

export interface ConversionPlan {
  steps: ConversionStep[];
  cleanupPaths: string[];
}

export interface ConversionJob {
  input: MediaFile;
  config: ConversionConfig;
}

export function buildConversionPlan(job: ConversionJob): ConversionPlan {
  const { input, config } = job;
  if (config.outputFormat === "gif") {
    return input.category === "animatedImage"
      ? buildAnimatedImagePlan(input, config)
      : buildGifPlan(input, config);
  }
  if (outputFormatDetails[config.outputFormat].category === "audio") {
    return buildAudioPlan(input, config);
  }
  if (outputFormatDetails[config.outputFormat].category === "image") {
    return buildImagePlan(input, config);
  }
  if (outputFormatDetails[config.outputFormat].category === "video") {
    return buildVideoPlan(input, config);
  }
  return buildAnimatedImagePlan(input, config);
}

function buildVideoPlan(input: MediaFile, config: ConversionConfig): ConversionPlan {
  const codec = videoCodec(config.outputFormat);
  if (!codec) {
    throw new Error(`No browser FFmpeg encoder is mapped for ${config.outputFormat}.`);
  }

  const targetBytes = config.targetSizeBytes ?? input.sizeOnDisk;
  const hasAudio = input.category === "video" && Boolean(input.audioCodec);
  const audioKbps = hasAudio
    ? config.preferredAudioBitrateKbps ?? defaultAudioKbps(input, config.outputFormat)
    : 0;
  const videoKbps = targetVideoKbps(input, config, audioKbps, targetBytes);
  const commonArgs = (inputPath: string) => [
    "-i",
    inputPath,
    ...videoFilterArgs(input, config),
    ...fpsArgs(config),
    "-c:v",
    codec,
    ...videoCodecTuningArgs(config.outputFormat),
    "-b:v",
    `${videoKbps}k`,
    ...(hasAudio
      ? ["-c:a", config.outputFormat === "webm" ? "libopus" : "aac", "-b:a", `${audioKbps}k`]
      : ["-an"]),
    ...metadataArgs(config),
    ...muxerArgs(config.outputFormat),
    ...(config.outputFormat === "webm" ? [] : ["-movflags", "+faststart"])
  ];

  if (config.usesSinglePassVideoTargetEncode || !input.duration) {
    return {
      cleanupPaths: [],
      steps: [
        {
          label: "Encoding video...",
          progressStart: 0,
          progressWeight: 1,
          args: (inputPath, outputPath) => [...commonArgs(inputPath), outputPath]
        }
      ]
    };
  }

  const passLog = `/pass-${input.id}`;
  const discard = `/discard-${input.id}.${outputFormatDetails[config.outputFormat].fileExtension}`;
  return {
    cleanupPaths: [passLog, `${passLog}-0.log`, `${passLog}-0.log.mbtree`, discard],
    steps: [
      {
        label: "Analyzing source...",
        progressStart: 0,
        progressWeight: 0.45,
        args: (inputPath) => [
          ...commonArgs(inputPath),
          "-pass",
          "1",
          "-passlogfile",
          passLog,
          "-an",
          ...firstPassMuxerArgs(config.outputFormat),
          discard
        ]
      },
      {
        label: "Encoding video...",
        progressStart: 0.45,
        progressWeight: 0.55,
        args: (inputPath, outputPath) => [
          ...commonArgs(inputPath),
          "-pass",
          "2",
          "-passlogfile",
          passLog,
          outputPath
        ]
      }
    ]
  };
}

function buildAudioPlan(input: MediaFile, config: ConversionConfig): ConversionPlan {
  const codec = audioCodec(config.outputFormat);
  const targetBytes = config.targetSizeBytes ?? input.sizeOnDisk;
  const kbps = config.preferredAudioBitrateKbps ?? audioBitrateKbps(targetBytes, input.duration ?? 0);
  return {
    cleanupPaths: [],
    steps: [
      {
        label: input.category === "video" ? "Extracting audio..." : "Converting audio...",
        progressStart: 0,
        progressWeight: 1,
        args: (inputPath, outputPath) => [
          "-i",
          inputPath,
          "-vn",
          "-map",
          "0:a:0",
          ...(codec ? ["-c:a", codec] : []),
          ...(outputFormatDetails[config.outputFormat].isLossy ? ["-b:a", `${kbps}k`] : []),
          ...metadataArgs(config),
          ...muxerArgs(config.outputFormat),
          outputPath
        ]
      }
    ]
  };
}

function buildImagePlan(input: MediaFile, config: ConversionConfig): ConversionPlan {
  const codec = imageCodec(config.outputFormat);
  if (!codec) {
    throw new Error(`No image encoder is mapped for ${config.outputFormat}.`);
  }
  const seekArgs = input.category === "video" ? ["-ss", String(config.frameTimeForExtraction ?? 0)] : [];
  const qualityArgs = imageQualityArgs(config);
  return {
    cleanupPaths: [],
    steps: [
      {
        label: input.category === "video" ? "Extracting frame..." : "Converting image...",
        progressStart: 0,
        progressWeight: 1,
        args: (inputPath, outputPath) => [
          ...seekArgs,
          "-i",
          inputPath,
          ...(config.outputFormat === "gif" ? gifFilterArgs(input, config) : mediaFilterArgs(input, config)),
          "-frames:v",
          "1",
          "-c:v",
          codec,
          ...qualityArgs,
          ...metadataArgs(config),
          ...muxerArgs(config.outputFormat),
          outputPath
        ]
      }
    ]
  };
}

function buildGifPlan(input: MediaFile, config: ConversionConfig): ConversionPlan {
  return {
    cleanupPaths: [],
    steps: [
      {
        label: input.category === "video" ? "Encoding GIF..." : "Converting GIF...",
        progressStart: 0,
        progressWeight: 1,
        args: (inputPath, outputPath) => [
          ...(input.category === "video" ? ["-ss", String(config.frameTimeForExtraction ?? 0)] : []),
          "-i",
          inputPath,
          ...gifFilterArgs(input, config),
          ...(input.category === "video" ? ["-frames:v", "1"] : []),
          "-c:v",
          "gif",
          ...metadataArgs(config),
          ...muxerArgs("gif"),
          outputPath
        ]
      }
    ]
  };
}

function buildAnimatedImagePlan(input: MediaFile, config: ConversionConfig): ConversionPlan {
  const codec = config.outputFormat === "gif" ? "gif" : videoCodec(config.outputFormat);
  if (!codec) {
    throw new Error(`No animated output encoder is mapped for ${config.outputFormat}.`);
  }
  return {
    cleanupPaths: [],
    steps: [
      {
        label: "Encoding animation...",
        progressStart: 0,
        progressWeight: 1,
        args: (inputPath, outputPath) => [
          "-i",
          inputPath,
          ...(config.outputFormat === "gif" ? gifFilterArgs(input, config) : mediaFilterArgs(input, config)),
          ...fpsArgs(config),
          "-c:v",
          codec,
          ...(config.outputFormat === "gif" ? [] : ["-pix_fmt", "yuv420p"]),
          ...metadataArgs(config),
          ...muxerArgs(config.outputFormat),
          outputPath
        ]
      }
    ]
  };
}

function targetVideoKbps(
  input: MediaFile,
  config: ConversionConfig,
  audioKbps: number,
  targetBytes: number
): number {
  if (input.duration) {
    return Math.max(
      minimumVideoKbps(input, config),
      bitrateKbps(targetBytes, input.duration, audioKbps)
    );
  }
  const sourceKbps = Math.round(((input.bitrate ?? 2_500_000) - (input.audioBitrate ?? 0)) / 1000);
  const quality = config.videoQuality ?? 0.72;
  return Math.max(minimumVideoKbps(input, config), Math.round(sourceKbps * quality));
}

function minimumVideoKbps(input: MediaFile, config: ConversionConfig): number {
  const dimensions = config.targetDimensions ?? input.dimensions;
  const pixels = dimensions ? dimensions.width * dimensions.height : 1280 * 720;
  const fps = config.targetFPS ?? input.fps ?? 30;
  const base = config.outputFormat === "webm" ? 0.055 : 0.07;
  return Math.max(180, Math.round((pixels * fps * base) / 1000));
}

function videoFilterArgs(input: MediaFile, config: ConversionConfig): string[] {
  const filters = videoFilterExpression(input, config);
  if (!filters.length) return [];
  return ["-vf", filters.join(",")];
}

function mediaFilterArgs(input: MediaFile, config: ConversionConfig): string[] {
  return config.outputFormat === "gif" ? gifFilterArgs(input, config) : videoFilterArgs(input, config);
}

function gifFilterArgs(input: MediaFile, config: ConversionConfig): string[] {
  const filters = videoFilterExpression(input, config);
  const fps = Math.min(config.targetFPS ?? input.fps ?? 15, 30);
  filters.push(`fps=${Math.max(1, Math.round(fps))}`);
  if (!filters.length) return [];
  return ["-vf", filters.join(",")];
}

function videoFilterExpression(input: MediaFile, config: ConversionConfig): string[] {
  const filters: string[] = [];
  if (config.cropRegion && input.dimensions) {
    const crop = config.cropRegion;
    const full =
      crop.x <= 0 &&
      crop.y <= 0 &&
      Math.round(crop.width) >= Math.round(input.dimensions.width) &&
      Math.round(crop.height) >= Math.round(input.dimensions.height);
    if (!full) {
      filters.push(`crop=${Math.round(crop.width)}:${Math.round(crop.height)}:${Math.round(crop.x)}:${Math.round(crop.y)}`);
    }
  }
  if (config.targetDimensions) {
    const dimensions = evenDimensions(config.targetDimensions);
    filters.push(`scale=${dimensions.width}:${dimensions.height}`);
  }
  return filters;
}

function fpsArgs(config: ConversionConfig): string[] {
  return config.targetFPS ? ["-r", String(config.targetFPS)] : [];
}

function threadArgs(format: OutputFormat): string[] {
  if (format === "webm") {
    return ["-threads", "2", "-row-mt", "1"];
  }
  return ["-threads", "2"];
}

function metadataArgs(config: ConversionConfig): string[] {
  if (config.metadata.stripAll) {
    return ["-map_metadata", "-1"];
  }
  return Object.entries(config.metadata.retainedFormatTags).flatMap(([key, value]) => [
    "-metadata",
    `${key}=${value}`
  ]);
}

function videoCodec(format: OutputFormat): string | undefined {
  return encoderNameFor(format);
}

function audioCodec(format: OutputFormat): string | undefined {
  switch (format) {
    case "m4a":
    case "aac":
      return "aac";
    case "wav":
      return "pcm_s16le";
    case "flac":
      return "flac";
    case "mp3":
      return "libmp3lame";
    case "ogg":
      return "libvorbis";
    case "opus":
      return "libopus";
    default:
      return undefined;
  }
}

function imageCodec(format: OutputFormat): string | undefined {
  switch (format) {
    case "jpg":
      return "mjpeg";
    case "png":
      return "png";
    case "heic":
      return "heic";
    case "webpImage":
      return "libwebp";
    case "tiff":
      return "tiff";
    default:
      return undefined;
  }
}

function imageQualityArgs(config: ConversionConfig): string[] {
  if (config.outputFormat === "webpImage") {
    const quality = Math.round((config.imageQuality ?? 0.82) * 100);
    return ["-quality", String(quality)];
  }
  if (config.outputFormat === "jpg") {
    const quality = Math.max(2, Math.min(31, Math.round(31 - (config.imageQuality ?? 0.82) * 27)));
    return ["-q:v", String(quality)];
  }
  return [];
}

function videoCodecTuningArgs(format: OutputFormat): string[] {
  switch (format) {
    case "mp4_h264":
    case "mov":
      return ["-preset", "veryfast", "-pix_fmt", "yuv420p"];
    case "mp4_hevc":
      return ["-preset", "fast", "-tag:v", "hvc1", "-pix_fmt", "yuv420p"];
    case "webm":
      return ["-row-mt", "1", "-pix_fmt", "yuv420p"];
    default:
      return [];
  }
}

function muxerArgs(format: OutputFormat): string[] {
  switch (format) {
    case "mp4_h264":
    case "mp4_hevc":
      return ["-f", "mp4"];
    case "mov":
      return ["-f", "mov"];
    case "webm":
      return ["-f", "webm"];
    case "mp3":
      return ["-f", "mp3"];
    case "m4a":
      return ["-f", "mp4"];
    case "wav":
      return ["-f", "wav"];
    case "aac":
      return ["-f", "adts"];
    case "flac":
      return ["-f", "flac"];
    case "ogg":
    case "opus":
      return ["-f", "ogg"];
    case "jpg":
      return ["-f", "mjpeg"];
    case "png":
    case "tiff":
      return ["-f", "image2"];
    case "heic":
      return ["-f", "heif"];
    case "webpImage":
      return ["-f", "webp"];
    case "gif":
      return ["-f", "gif"];
  }
}

function firstPassMuxerArgs(format: OutputFormat): string[] {
  switch (format) {
    case "webm":
      return ["-f", "webm"];
    case "mov":
      return ["-f", "mov"];
    default:
      return ["-f", "mp4"];
  }
}
