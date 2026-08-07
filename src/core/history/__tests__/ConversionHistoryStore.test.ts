import {
  HISTORY_ENABLED_KEY,
  HISTORY_ENTRIES_KEY,
  createConversionHistoryStore,
  type KeyValueStorage,
} from '@/src/core/history/ConversionHistoryStore';
import type { ConversionConfig } from '@/src/core/models/types';

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

const config: ConversionConfig = {
  outputFormat: 'mp4_h264',
  targetSizeBytes: 1_000_000,
  prefersRemuxWhenPossible: true,
};

describe('ConversionHistoryStore', () => {
  it('defaults history disabled and empty', async () => {
    const store = createConversionHistoryStore(memoryStorage());
    await store.load();
    expect(store.isEnabled).toBe(false);
    expect(store.entries).toEqual([]);
    expect(store.storageSummaryTitle).toMatch(/session/i);
  });

  it('enables persistence and records successful conversions', async () => {
    const storage = memoryStorage();
    const store = createConversionHistoryStore(storage);
    await store.load();
    await store.setEnabled(true);

    await store.record({
      inputFilename: 'clip.mp4',
      inputCategory: 'video',
      config,
      result: {
        path: '/tmp/out.mp4',
        outputFormat: 'mp4_h264',
        sizeOnDisk: 900_000,
        dimensions: { width: 1280, height: 720 },
      },
    });

    expect(store.entries).toHaveLength(1);
    expect(store.entries[0]?.inputFilename).toBe('clip.mp4');
    expect(store.totalStorageBytes).toBe(900_000);
    expect(await storage.getItem(HISTORY_ENABLED_KEY)).toBe('true');
    expect(await storage.getItem(HISTORY_ENTRIES_KEY)).toContain('clip.mp4');
  });

  it('keeps session-only entries when disabled', async () => {
    const storage = memoryStorage();
    const store = createConversionHistoryStore(storage);
    await store.load();
    expect(store.isEnabled).toBe(false);

    await store.record({
      inputFilename: 'temp.mp4',
      inputCategory: 'video',
      config,
      result: { path: '/tmp/a.mp4', outputFormat: 'mp4_h264', sizeOnDisk: 100 },
    });

    expect(store.entries).toHaveLength(1);
    expect(await storage.getItem(HISTORY_ENTRIES_KEY)).toBeNull();

    const reloaded = createConversionHistoryStore(storage);
    await reloaded.load();
    expect(reloaded.entries).toEqual([]);
  });

  it('lists newest first, removes one, and clears all', async () => {
    const store = createConversionHistoryStore(memoryStorage());
    await store.load();
    await store.setEnabled(true);

    await store.record({
      inputFilename: 'first.mp4',
      inputCategory: 'video',
      config,
      result: { path: '/tmp/1.mp4', outputFormat: 'mp4_h264', sizeOnDisk: 10 },
    });
    await store.record({
      inputFilename: 'second.mp4',
      inputCategory: 'video',
      config,
      result: { path: '/tmp/2.mp4', outputFormat: 'mp4_h264', sizeOnDisk: 20 },
    });

    expect(store.entries.map((e) => e.inputFilename)).toEqual(['second.mp4', 'first.mp4']);

    const id = store.entries[0]!.id;
    await store.removeEntry(id);
    expect(store.entries).toHaveLength(1);
    expect(store.entries[0]?.inputFilename).toBe('first.mp4');

    await store.clear();
    expect(store.entries).toEqual([]);
    expect(store.totalStorageBytes).toBe(0);
  });

  it('clears persisted history when disabling saved history', async () => {
    const storage = memoryStorage();
    const store = createConversionHistoryStore(storage);
    await store.load();
    await store.setEnabled(true);
    await store.record({
      inputFilename: 'keep.mp4',
      inputCategory: 'video',
      config,
      result: { path: '/tmp/k.mp4', outputFormat: 'mp4_h264', sizeOnDisk: 50 },
    });

    await store.setEnabled(false, { clearPersisted: true });
    expect(store.isEnabled).toBe(false);
    expect(store.entries).toEqual([]);
    expect(await storage.getItem(HISTORY_ENTRIES_KEY)).toBe('[]');
  });
});
