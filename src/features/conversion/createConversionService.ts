import { Directory, File, Paths } from 'expo-file-system';
import FFmpegModule from 'ffmpeg-module';
import ImageEncodeModule from 'image-encode-module';

import { ConversionService } from '@/src/core/conversion/ConversionService';

const conversionsDirectoryName = 'conversions';

export function conversionsTempDirectory(): string {
  const dir = new Directory(Paths.cache, conversionsDirectoryName);
  if (!dir.exists) {
    dir.create();
  }
  return dir.uri.startsWith('file://') ? dir.uri.slice('file://'.length) : dir.uri;
}

export function createConversionService(): ConversionService {
  return new ConversionService({
    ffmpeg: FFmpegModule,
    imageEncode: ImageEncodeModule,
    tempDirectory: conversionsTempDirectory(),
    ensureTempDirectory: async () => {
      conversionsTempDirectory();
    },
    fileSize: async (path) => {
      const file = new File(pathToFileUri(path));
      if (!file.exists) return 0;
      return file.size ?? 0;
    },
    pathExists: async (path) => {
      const file = new File(pathToFileUri(path));
      return file.exists;
    },
    isCancelReturnCode: (code) => code === 255,
  });
}

function pathToFileUri(path: string): string {
  return path.startsWith('file://') ? path : `file://${path}`;
}
