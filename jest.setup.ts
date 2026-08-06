// RNTL v12.4+ registers Jest matchers when `@testing-library/react-native` is imported.

jest.mock('ffmpeg-module', () => ({
  __esModule: true,
  default: {
    execute: jest.fn(async () => ({ sessionId: '0', returnCode: 0 })),
    cancel: jest.fn(async () => true),
    probe: jest.fn(async () => ({})),
    getRuntimeInfo: jest.fn(() => ({
      packageName: 'min',
      ffmpegVersion: 'test',
      ffmpegKitVersion: 'test',
      buildDate: 'test',
      externalLibraries: [],
    })),
    addListener: jest.fn(() => ({ remove: jest.fn() })),
  },
}));

jest.mock('image-encode-module', () => ({
  __esModule: true,
  default: {
    encode: jest.fn(async (params: { outputUri: string }) => ({
      outputUri: params.outputUri,
      byteSize: 1024,
      width: 100,
      height: 100,
    })),
  },
}));
