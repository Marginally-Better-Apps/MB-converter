import { ConversionError } from '@/src/core/conversion/ConversionError';
import { ConversionService } from '@/src/core/conversion/ConversionService';
import type { ConversionConfig, MediaFile } from '@/src/core/models/types';

type MockFFmpeg = {
  execute: jest.Mock;
  cancel: jest.Mock;
  addListener: jest.Mock;
};

type MockImageEncode = {
  encode: jest.Mock;
};

function videoInput(overrides: Partial<MediaFile> = {}): MediaFile {
  return {
    path: '/tmp/input.mp4',
    category: 'video',
    sizeOnDisk: 5_000_000,
    duration: 10,
    dimensions: { width: 1280, height: 720 },
    fps: 30,
    bitrate: 2_000_000,
    audioBitrate: 128_000,
    videoCodec: 'h264',
    audioCodec: 'aac',
    containerFormat: 'mp4',
    ...overrides,
  };
}

function imageInput(overrides: Partial<MediaFile> = {}): MediaFile {
  return {
    path: '/tmp/photo.jpg',
    category: 'image',
    sizeOnDisk: 800_000,
    dimensions: { width: 2000, height: 1500 },
    containerFormat: 'jpeg',
    ...overrides,
  };
}

function makeFFmpeg(overrides: Partial<MockFFmpeg> = {}): MockFFmpeg {
  const listeners: Record<string, ((event: unknown) => void)[]> = {};
  return {
    execute: jest.fn(async () => ({ sessionId: '1', returnCode: 0 })),
    cancel: jest.fn(async () => true),
    addListener: jest.fn((event: string, cb: (event: unknown) => void) => {
      listeners[event] = listeners[event] ?? [];
      listeners[event].push(cb);
      return { remove: jest.fn() };
    }),
    ...overrides,
  };
}

describe('ConversionService', () => {
  const outputDir = '/tmp/mb-conversions-test';

  beforeEach(() => {
    jest.clearAllMocks();
  });

  it('runs FFmpeg for video → mp4 and reports progress', async () => {
    const ffmpeg = makeFFmpeg({
      execute: jest.fn(async () => {
        // Simulate a progress event mid-flight via listener registration side-effect
        return { sessionId: '42', returnCode: 0 };
      }),
    });
    const imageEncode: MockImageEncode = { encode: jest.fn() };
    const service = new ConversionService({
      ffmpeg: ffmpeg as never,
      imageEncode: imageEncode as never,
      tempDirectory: outputDir,
      fileSize: async () => 1_234_567,
      pathExists: async () => true,
    });

    const progress = jest.fn();
    const config: ConversionConfig = {
      outputFormat: 'mp4_h264',
      targetSizeBytes: 2_000_000,
      usesSinglePassVideoTargetEncode: true,
    };

    // Emit progress while execute is in-flight (after listener subscription).
    ffmpeg.execute.mockImplementation(async () => {
      const listeners = ffmpeg.addListener.mock.calls
        .filter((call) => call[0] === 'onProgress')
        .map((call) => call[1] as (e: unknown) => void);
      for (const cb of listeners) {
        cb({
          sessionId: '42',
          timeMilliseconds: 5_000,
          videoFrameNumber: 150,
          videoFps: 30,
          size: 500,
          bitrate: 1000,
          speed: 1,
        });
      }
      return { sessionId: '42', returnCode: 0 };
    });

    const result = await service.convert(videoInput(), config, { onProgress: progress });

    expect(ffmpeg.execute).toHaveBeenCalled();
    expect(result.outputFormat).toBe('mp4_h264');
    expect(result.sizeOnDisk).toBe(1_234_567);
    expect(result.path).toContain('.mp4');
    expect(progress).toHaveBeenCalled();
    const fractions = progress.mock.calls.map((c) => c[0] as number);
    expect(fractions.some((f) => f >= 0.4 && f <= 0.6)).toBe(true);
  });

  it('uses ImageEncodeModule for still-image conversion', async () => {
    const ffmpeg = makeFFmpeg();
    const imageEncode: MockImageEncode = {
      encode: jest.fn(async ({ quality, outputUri }: { quality: number; outputUri: string }) => ({
        outputUri,
        byteSize: Math.round(quality * 400_000),
        width: 1000,
        height: 750,
      })),
    };
    const service = new ConversionService({
      ffmpeg: ffmpeg as never,
      imageEncode: imageEncode as never,
      tempDirectory: outputDir,
      fileSize: async () => 200_000,
      pathExists: async () => true,
    });

    const result = await service.convert(imageInput(), {
      outputFormat: 'jpg',
      targetSizeBytes: 250_000,
    });

    expect(ffmpeg.execute).not.toHaveBeenCalled();
    expect(imageEncode.encode).toHaveBeenCalled();
    expect(result.outputFormat).toBe('jpg');
    expect(result.dimensions).toEqual({ width: 1000, height: 750 });
  });

  it('cancel() stops an in-flight FFmpeg conversion', async () => {
    let resolveExecute: ((value: { sessionId: string; returnCode: number }) => void) | null =
      null;
    const ffmpeg = makeFFmpeg({
      execute: jest.fn(
        () =>
          new Promise((resolve) => {
            resolveExecute = resolve;
          })
      ),
      cancel: jest.fn(async () => {
        resolveExecute?.({ sessionId: '9', returnCode: 255 });
        return true;
      }),
    });
    const service = new ConversionService({
      ffmpeg: ffmpeg as never,
      imageEncode: { encode: jest.fn() } as never,
      tempDirectory: outputDir,
      fileSize: async () => 100,
      pathExists: async () => false,
      isCancelReturnCode: (code) => code !== 0,
    });

    const pending = service.convert(videoInput(), { outputFormat: 'mp4_h264' });
    await Promise.resolve();
    await service.cancel();

    await expect(pending).rejects.toThrow(ConversionError);
    expect(ffmpeg.cancel).toHaveBeenCalled();
  });

  it('cancel() is idempotent when idle', async () => {
    const ffmpeg = makeFFmpeg();
    const service = new ConversionService({
      ffmpeg: ffmpeg as never,
      imageEncode: { encode: jest.fn() } as never,
      tempDirectory: outputDir,
    });
    await expect(service.cancel()).resolves.toBeUndefined();
    await expect(service.cancel()).resolves.toBeUndefined();
  });

  it('rejects unsupported conversion pairs before calling engines', async () => {
    const ffmpeg = makeFFmpeg();
    const service = new ConversionService({
      ffmpeg: ffmpeg as never,
      imageEncode: { encode: jest.fn() } as never,
      tempDirectory: outputDir,
    });
    await expect(
      service.convert(videoInput(), { outputFormat: 'jpg' })
    ).rejects.toThrow(ConversionError);
    expect(ffmpeg.execute).not.toHaveBeenCalled();
  });
});
