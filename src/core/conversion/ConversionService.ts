import {
  audioBitrateKbps,
  capAudioEncodeKbps,
  maximumAudioEncodeKbps,
  minimumVideoBitrateKbps,
  qualityDrivenVideoBitrateKbps,
  sourceVideoBitrateBps,
  suggestedAudioBitrate,
  videoBitrateKbps,
} from '@/src/core/conversion/bitrateCalculator';
import { conversionEnginePath } from '@/src/core/conversion/conversionRouter';
import { ConversionError } from '@/src/core/conversion/ConversionError';
import {
  binarySearchImageQuality,
  defaultImageEncodeQuality,
} from '@/src/core/conversion/imageEncodePlanner';
import { progressFractionFromFFmpegStats } from '@/src/core/conversion/progressFraction';
import { shouldRemuxAudio } from '@/src/core/conversion/remuxDecision';
import {
  conversionOutputPath,
  conversionPassLogPath,
  joinTempPath,
} from '@/src/core/conversion/tempStorage';
import { encoderName } from '@/src/core/compatibility/CodecCapability';
import { buildAnimatedImageToVideoCommands } from '@/src/core/ffmpeg/animatedImageCommandBuilder';
import { buildAudioFFmpegCommand, buildAudioRemuxCommand } from '@/src/core/ffmpeg/audioCommandBuilder';
import { categoryOf, fileExtension } from '@/src/core/ffmpeg/outputFormatArgs';
import { buildVideoCommands } from '@/src/core/ffmpeg/videoCommandBuilder';
import type {
  ConversionConfig,
  MediaFile,
  OutputFormat,
  Size,
} from '@/src/core/models/types';
import { DEFAULT_METADATA_POLICY } from '@/src/core/models/types';

export type ConversionResult = {
  path: string;
  outputFormat: OutputFormat;
  sizeOnDisk: number;
  dimensions?: Size;
};

export type ConversionProgressCallbacks = {
  onProgress?: (fraction: number) => void;
};

export type FFmpegProgressEvent = {
  sessionId: string;
  timeMilliseconds: number;
  videoFrameNumber: number;
  videoFps: number;
  size: number;
  bitrate: number;
  speed: number;
};

export type FFmpegModuleLike = {
  execute(command: string | string[]): Promise<{ sessionId: string; returnCode: number }>;
  cancel(sessionId?: string): Promise<boolean>;
  addListener(
    event: 'onProgress' | 'onLog',
    listener: (event: FFmpegProgressEvent) => void
  ): { remove: () => void };
};

export type ImageEncodeParams = {
  uri: string;
  format: OutputFormat;
  quality: number;
  outputUri: string;
  crop?: { x: number; y: number; width: number; height: number };
  maxPixel?: number;
  metadata?: { stripAll: boolean };
};

export type ImageEncodeResult = {
  outputUri: string;
  byteSize: number;
  width: number;
  height: number;
};

export type ImageEncodeModuleLike = {
  encode(params: ImageEncodeParams): Promise<ImageEncodeResult>;
};

export type ConversionServiceDeps = {
  ffmpeg: FFmpegModuleLike;
  imageEncode: ImageEncodeModuleLike;
  tempDirectory: string;
  fileSize?: (path: string) => Promise<number>;
  pathExists?: (path: string) => Promise<boolean>;
  isCancelReturnCode?: (returnCode: number) => boolean;
  ensureTempDirectory?: (directory: string) => Promise<void>;
};

/**
 * Orchestrates conversion: router → command build / image encode → native execute → result.
 * Cancel is cooperative at the service layer (flags + FFmpegModule.cancel / search abort).
 */
export class ConversionService {
  private cancelled = false;
  private activeSessionId: string | null = null;
  private readonly deps: ConversionServiceDeps;

  constructor(deps: ConversionServiceDeps) {
    this.deps = deps;
  }

  async cancel(): Promise<void> {
    this.cancelled = true;
    try {
      await this.deps.ffmpeg.cancel(this.activeSessionId ?? undefined);
    } catch {
      // Idempotent best-effort
    }
  }

  async convert(
    input: MediaFile,
    config: ConversionConfig,
    callbacks: ConversionProgressCallbacks = {}
  ): Promise<ConversionResult> {
    this.cancelled = false;
    this.activeSessionId = null;

    const path = conversionEnginePath(input.category, config.outputFormat);
    await this.deps.ensureTempDirectory?.(this.deps.tempDirectory);
    this.throwIfCancelled();

    switch (path) {
      case 'video':
        return this.convertVideo(input, config, callbacks);
      case 'audio':
        return this.convertAudio(input, config, callbacks);
      case 'animated':
        return this.convertAnimated(input, config, callbacks);
      case 'image':
        return this.convertImage(input, config, callbacks);
    }
  }

  private async convertVideo(
    input: MediaFile,
    config: ConversionConfig,
    callbacks: ConversionProgressCallbacks
  ): Promise<ConversionResult> {
    const outputPath = conversionOutputPath(this.deps.tempDirectory, config.outputFormat);
    const passLogPath = conversionPassLogPath(this.deps.tempDirectory);
    const pass1DiscardPath = joinTempPath(
      this.deps.tempDirectory,
      `pass1-discard.${fileExtension(config.outputFormat)}`
    );

    const hasAudio = input.audioCodec != null;
    const targetBytes = config.targetSizeBytes ?? input.sizeOnDisk;
    const duration = input.duration != null && input.duration > 0 ? input.duration : null;
    const sourceVideoBps = sourceVideoBitrateBps({
      totalBitrateBps: input.bitrate,
      audioBitrateBps: input.audioBitrate,
    });

    let audioKbps = 0;
    if (hasAudio) {
      const suggested =
        duration != null
          ? suggestedAudioBitrate({ targetBytes, durationSec: duration })
          : 128;
      const requested = config.preferredAudioBitrateKbps ?? suggested;
      audioKbps = capAudioEncodeKbps({
        requested,
        sourceBps: input.audioBitrate,
      });
      if (config.outputFormat === 'webm') {
        audioKbps = Math.min(audioKbps, 128);
      }
    }

    const minimumVideo = minimumVideoBitrateKbps({
      dimensions: config.targetDimensions ?? input.dimensions,
      fps: config.targetFPS ?? input.fps,
      outputFormat: config.outputFormat,
      sourceVideoBitrateBps: sourceVideoBps,
    });

    let videoKbps: number;
    if (duration != null) {
      videoKbps = videoBitrateKbps({
        targetBytes,
        durationSec: duration,
        audioBitrateKbps: audioKbps,
        minimumVideoBitrateKbps: minimumVideo,
      });
    } else {
      videoKbps = qualityDrivenVideoBitrateKbps({
        quality: config.videoQuality ?? 0.72,
        dimensions: config.targetDimensions ?? input.dimensions,
        fps: config.targetFPS ?? input.fps,
        outputFormat: config.outputFormat,
        sourceVideoBitrateBps: sourceVideoBps,
      });
    }

    const commands = buildVideoCommands({
      input,
      config,
      outputPath,
      passLogPath,
      pass1DiscardPath,
      videoKbps,
      audioBitrateKbps: audioKbps,
    });

    callbacks.onProgress?.(0);

    if (commands.mode === 'remux') {
      await this.runFFmpeg(commands.remux, duration, callbacks);
    } else if (commands.mode === 'singlePass') {
      await this.runFFmpeg(commands.singlePass, duration, callbacks);
    } else {
      await this.runFFmpeg(commands.pass1, duration, {
        onProgress: (f) => callbacks.onProgress?.(f * 0.45),
      });
      this.throwIfCancelled();
      await this.runFFmpeg(commands.pass2, duration, {
        onProgress: (f) => callbacks.onProgress?.(0.45 + f * 0.55),
      });
    }

    callbacks.onProgress?.(1);
    return this.finalizeResult(outputPath, config.outputFormat, input.dimensions);
  }

  private async convertAudio(
    input: MediaFile,
    config: ConversionConfig,
    callbacks: ConversionProgressCallbacks
  ): Promise<ConversionResult> {
    if (input.category === 'video' && input.audioCodec == null) {
      throw ConversionError.invalidInput('This video has no audio track to extract.');
    }
    const duration = input.duration;
    if (duration == null || !(duration > 0)) {
      throw ConversionError.invalidInput('Audio duration is unavailable.');
    }

    const outputPath = conversionOutputPath(this.deps.tempDirectory, config.outputFormat);
    const metadata = config.metadata ?? DEFAULT_METADATA_POLICY;
    callbacks.onProgress?.(0);

    if (shouldRemuxAudio(input, config)) {
      try {
        const remux = buildAudioRemuxCommand({
          inputPath: input.path,
          outputPath,
          outputFormat: config.outputFormat,
          metadata,
        });
        await this.runFFmpeg(remux, duration, callbacks);
        callbacks.onProgress?.(1);
        return this.finalizeResult(outputPath, config.outputFormat);
      } catch (error) {
        if (error instanceof ConversionError && error.code === 'cancelled') throw error;
        // Fall through to encode
      }
    }

    this.throwIfCancelled();

    let bitrate =
      config.targetSizeBytes != null
        ? audioBitrateKbps({ targetBytes: config.targetSizeBytes, durationSec: duration })
        : 192;
    if (config.preferredAudioBitrateKbps != null) {
      bitrate = config.preferredAudioBitrateKbps;
    }
    const sourceBps = input.category === 'video' ? input.audioBitrate : input.bitrate;
    bitrate = capAudioEncodeKbps({
      requested: bitrate,
      sourceBps,
      maximumKbps: maximumAudioEncodeKbps(config.outputFormat),
    });

    const audioCodec = encoderName(config.outputFormat);
    if (!audioCodec) {
      throw ConversionError.codecUnavailable(`No encoder for ${config.outputFormat}`);
    }

    const command = buildAudioFFmpegCommand({
      inputPath: input.path,
      outputPath,
      outputFormat: config.outputFormat,
      audioCodec,
      bitrateKbps: bitrate,
      treatAsLossyForBitrateArg: config.outputFormat !== 'wav' && config.outputFormat !== 'flac',
      metadata,
    });

    await this.runFFmpeg(command, duration, callbacks);
    callbacks.onProgress?.(1);
    return this.finalizeResult(outputPath, config.outputFormat);
  }

  private async convertAnimated(
    input: MediaFile,
    config: ConversionConfig,
    callbacks: ConversionProgressCallbacks
  ): Promise<ConversionResult> {
    if (categoryOf(config.outputFormat) === 'image') {
      return this.convertImage(input, config, callbacks);
    }

    const duration = input.duration;
    if (duration == null || !(duration > 0)) {
      throw ConversionError.invalidInput('GIF duration is unavailable.');
    }

    const outputPath = conversionOutputPath(this.deps.tempDirectory, config.outputFormat);
    const passLogPath = conversionPassLogPath(this.deps.tempDirectory);
    const pass1DiscardPath = joinTempPath(
      this.deps.tempDirectory,
      `pass1-discard.${fileExtension(config.outputFormat)}`
    );
    const targetBytes = config.targetSizeBytes ?? input.sizeOnDisk;
    const sourceVideoBps = sourceVideoBitrateBps({
      totalBitrateBps: input.bitrate,
      audioBitrateBps: input.audioBitrate,
    });
    const minimumVideo = minimumVideoBitrateKbps({
      dimensions: config.targetDimensions ?? input.dimensions,
      fps: config.targetFPS ?? input.fps,
      outputFormat: config.outputFormat,
      sourceVideoBitrateBps: sourceVideoBps,
    });
    const videoKbps = videoBitrateKbps({
      targetBytes,
      durationSec: duration,
      audioBitrateKbps: 0,
      minimumVideoBitrateKbps: minimumVideo,
    });

    const commands = buildAnimatedImageToVideoCommands({
      inputPath: input.path,
      outputPath,
      passLogPath,
      pass1DiscardPath,
      outputFormat: config.outputFormat,
      videoKbps,
      targetDimensions: config.targetDimensions,
      targetFPS: config.targetFPS,
      sourceFPS: input.fps,
      usesSinglePass: !!config.usesSinglePassVideoTargetEncode,
      metadata: config.metadata ?? DEFAULT_METADATA_POLICY,
    });

    callbacks.onProgress?.(0);
    if (commands.mode === 'singlePass') {
      await this.runFFmpeg(commands.singlePass, duration, callbacks);
    } else {
      await this.runFFmpeg(commands.pass1, duration, {
        onProgress: (f) => callbacks.onProgress?.(f * 0.45),
      });
      this.throwIfCancelled();
      await this.runFFmpeg(commands.pass2, duration, {
        onProgress: (f) => callbacks.onProgress?.(0.45 + f * 0.55),
      });
    }
    callbacks.onProgress?.(1);
    return this.finalizeResult(outputPath, config.outputFormat, input.dimensions);
  }

  private async convertImage(
    input: MediaFile,
    config: ConversionConfig,
    callbacks: ConversionProgressCallbacks
  ): Promise<ConversionResult> {
    const outputPath = conversionOutputPath(this.deps.tempDirectory, config.outputFormat);
    const stripAll = config.metadata?.stripAll ?? true;
    const maxPixel =
      config.targetDimensions != null
        ? Math.ceil(Math.max(config.targetDimensions.width, config.targetDimensions.height))
        : undefined;

    callbacks.onProgress?.(0.05);

    const runEncode = async (quality: number) => {
      this.throwIfCancelled();
      const attemptPath =
        config.targetSizeBytes != null
          ? conversionOutputPath(this.deps.tempDirectory, config.outputFormat)
          : outputPath;
      const encoded = await this.deps.imageEncode.encode({
        uri: pathToFileUri(input.path),
        format: config.outputFormat,
        quality,
        outputUri: pathToFileUri(attemptPath),
        crop: config.cropRegion,
        maxPixel,
        metadata: { stripAll },
      });
      return {
        byteSize: encoded.byteSize,
        outputUri: encoded.outputUri,
        width: encoded.width,
        height: encoded.height,
      };
    };

    if (config.targetSizeBytes != null && supportsImageTargetSize(config.outputFormat)) {
      let lastMeta: { width: number; height: number } | null = null;
      const search = await binarySearchImageQuality({
        targetBytes: config.targetSizeBytes,
        iterations: 12,
        isCancelled: () => this.cancelled,
        onProgress: (f) => callbacks.onProgress?.(0.3 + f * 0.65),
        encode: async (quality) => {
          const attempt = await runEncode(quality);
          lastMeta = { width: attempt.width, height: attempt.height };
          return { byteSize: attempt.byteSize, outputUri: attempt.outputUri };
        },
      });
      this.throwIfCancelled();
      const finalPath = fileUriToPath(search.outputUri);
      const size = (await this.deps.fileSize?.(finalPath)) ?? search.byteSize;
      callbacks.onProgress?.(1);
      return {
        path: finalPath,
        outputFormat: config.outputFormat,
        sizeOnDisk: size,
        dimensions: lastMeta ?? undefined,
      };
    }

    const quality = defaultImageEncodeQuality({
      hasTargetSize: false,
      format: config.outputFormat,
    });
    const q = config.imageQuality ?? quality;
    const encoded = await runEncode(q);
    callbacks.onProgress?.(1);
    return {
      path: fileUriToPath(encoded.outputUri),
      outputFormat: config.outputFormat,
      sizeOnDisk: encoded.byteSize,
      dimensions: { width: encoded.width, height: encoded.height },
    };
  }

  private async runFFmpeg(
    command: string,
    durationSec: number | null,
    callbacks: ConversionProgressCallbacks
  ): Promise<void> {
    this.throwIfCancelled();

    const subscription = this.deps.ffmpeg.addListener('onProgress', (event) => {
      const fraction = progressFractionFromFFmpegStats(event.timeMilliseconds, durationSec);
      if (fraction != null) {
        callbacks.onProgress?.(fraction);
      }
    });

    try {
      const result = await this.deps.ffmpeg.execute(command);
      this.activeSessionId = result.sessionId;

      if (this.cancelled || this.isCancelCode(result.returnCode)) {
        throw ConversionError.cancelled();
      }
      if (result.returnCode !== 0) {
        throw ConversionError.engineFailed(`FFmpeg exited with code ${result.returnCode}`);
      }
    } catch (error) {
      if (error instanceof ConversionError) throw error;
      if (this.cancelled) throw ConversionError.cancelled();
      throw ConversionError.engineFailed(error instanceof Error ? error.message : String(error));
    } finally {
      subscription.remove();
      this.activeSessionId = null;
    }

    this.throwIfCancelled();
  }

  private async finalizeResult(
    path: string,
    outputFormat: OutputFormat,
    dimensions?: Size
  ): Promise<ConversionResult> {
    this.throwIfCancelled();
    const exists = this.deps.pathExists ? await this.deps.pathExists(path) : true;
    if (!exists) {
      throw ConversionError.engineFailed('Output file was not created.');
    }
    const sizeOnDisk = this.deps.fileSize ? await this.deps.fileSize(path) : 0;
    return { path, outputFormat, sizeOnDisk, dimensions };
  }

  private throwIfCancelled(): void {
    if (this.cancelled) throw ConversionError.cancelled();
  }

  private isCancelCode(returnCode: number): boolean {
    if (this.deps.isCancelReturnCode) return this.deps.isCancelReturnCode(returnCode);
    // FFmpegKit cancel typically surfaces as non-zero; treat only explicit cancel helper as cancel.
    return false;
  }
}

function supportsImageTargetSize(format: OutputFormat): boolean {
  return format === 'jpg' || format === 'heic' || format === 'webpImage';
}

function pathToFileUri(path: string): string {
  if (path.startsWith('file://')) return path;
  return `file://${path}`;
}

function fileUriToPath(uri: string): string {
  if (uri.startsWith('file://')) return uri.slice('file://'.length);
  return uri;
}
