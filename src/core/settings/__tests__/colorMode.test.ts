import {
  COLOR_MODE_STORAGE_KEY,
  createColorModeStore,
  parseColorMode,
  resolveColorScheme,
  type KeyValueStorage,
} from '@/src/core/settings/colorMode';

function memoryStorage(seed: Record<string, string> = {}): KeyValueStorage {
  const map = new Map(Object.entries(seed));
  return {
    async getItem(key) {
      return map.has(key) ? map.get(key)! : null;
    },
    async setItem(key, value) {
      map.set(key, value);
    },
    async removeItem(key) {
      map.delete(key);
    },
  };
}

describe('colorMode', () => {
  it('parses known modes and defaults to system', () => {
    expect(parseColorMode('light')).toBe('light');
    expect(parseColorMode('dark')).toBe('dark');
    expect(parseColorMode('system')).toBe('system');
    expect(parseColorMode(null)).toBe('system');
    expect(parseColorMode('nope')).toBe('system');
  });

  it('resolves system against Appearance', () => {
    expect(resolveColorScheme('system', 'dark')).toBe('dark');
    expect(resolveColorScheme('light', 'dark')).toBe('light');
    expect(resolveColorScheme('dark', 'light')).toBe('dark');
  });

  it('persists color mode via storage', async () => {
    const storage = memoryStorage();
    const store = createColorModeStore(storage);
    await store.load();
    expect(store.mode).toBe('system');

    await store.setMode('dark');
    expect(store.mode).toBe('dark');
    expect(await storage.getItem(COLOR_MODE_STORAGE_KEY)).toBe('dark');

    const reloaded = createColorModeStore(storage);
    await reloaded.load();
    expect(reloaded.mode).toBe('dark');
  });
});
