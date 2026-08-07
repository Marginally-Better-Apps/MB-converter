export type AppColorMode = 'system' | 'light' | 'dark';

export const COLOR_MODE_STORAGE_KEY = 'appColorMode';

export type KeyValueStorage = {
  getItem(key: string): Promise<string | null>;
  setItem(key: string, value: string): Promise<void>;
  removeItem(key: string): Promise<void>;
};

export function parseColorMode(raw: string | null | undefined): AppColorMode {
  if (raw === 'light' || raw === 'dark' || raw === 'system') return raw;
  return 'system';
}

export function resolveColorScheme(
  mode: AppColorMode,
  systemScheme: 'light' | 'dark'
): 'light' | 'dark' {
  if (mode === 'system') return systemScheme;
  return mode;
}

export type ColorModeStore = {
  mode: AppColorMode;
  load(): Promise<void>;
  setMode(mode: AppColorMode): Promise<void>;
};

export function createColorModeStore(storage: KeyValueStorage): ColorModeStore {
  let mode: AppColorMode = 'system';

  return {
    get mode() {
      return mode;
    },
    async load() {
      mode = parseColorMode(await storage.getItem(COLOR_MODE_STORAGE_KEY));
    },
    async setMode(next) {
      mode = next;
      await storage.setItem(COLOR_MODE_STORAGE_KEY, next);
    },
  };
}
