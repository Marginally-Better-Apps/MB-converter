// RNTL v12.4+ registers Jest matchers when `@testing-library/react-native` is imported.

const mockAsyncStorageMap = new Map<string, string>();

jest.mock('@react-native-async-storage/async-storage', () => ({
  __esModule: true,
  default: {
    getItem: jest.fn(async (key: string) =>
      mockAsyncStorageMap.has(key) ? mockAsyncStorageMap.get(key)! : null
    ),
    setItem: jest.fn(async (key: string, value: string) => {
      mockAsyncStorageMap.set(key, value);
    }),
    removeItem: jest.fn(async (key: string) => {
      mockAsyncStorageMap.delete(key);
    }),
    clear: jest.fn(async () => {
      mockAsyncStorageMap.clear();
    }),
  },
}));

beforeEach(() => {
  mockAsyncStorageMap.clear();
});

jest.mock('nativewind', () => ({
  colorScheme: {
    set: jest.fn(),
    get: jest.fn(() => 'system'),
  },
  useColorScheme: jest.fn(() => ({
    colorScheme: 'light',
    setColorScheme: jest.fn(),
    toggleColorScheme: jest.fn(),
  })),
}));

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
