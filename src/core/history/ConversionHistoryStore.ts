import type { ConversionResult } from '@/src/core/conversion/ConversionService';
import type {
  ConversionConfig,
  MediaCategory,
  OutputFormat,
  Size,
} from '@/src/core/models/types';

export const HISTORY_ENABLED_KEY = 'conversionHistoryEnabled';
export const HISTORY_ENTRIES_KEY = 'conversionHistoryEntries';

export type KeyValueStorage = {
  getItem(key: string): Promise<string | null>;
  setItem(key: string, value: string): Promise<void>;
  removeItem(key: string): Promise<void>;
};

export type ConversionHistoryEntry = {
  id: string;
  createdAt: string;
  inputFilename: string;
  inputCategory: MediaCategory;
  outputFormat: OutputFormat;
  resultPath: string;
  sizeOnDisk: number;
  dimensions?: Size;
  configSummary: {
    targetSizeBytes?: number;
    targetFPS?: number;
    targetDimensions?: Size;
  };
};

export type RecordHistoryInput = {
  inputFilename: string;
  inputCategory: MediaCategory;
  config: ConversionConfig;
  result: ConversionResult;
};

export type ConversionHistoryStore = {
  isEnabled: boolean;
  entries: ConversionHistoryEntry[];
  totalStorageBytes: number;
  storageSummaryTitle: string;
  storageSummaryDescription: string;
  load(): Promise<void>;
  setEnabled(enabled: boolean, options?: { clearPersisted?: boolean }): Promise<void>;
  record(input: RecordHistoryInput): Promise<ConversionHistoryEntry | null>;
  removeEntry(id: string): Promise<void>;
  clear(): Promise<void>;
  refreshForCurrentSettings(): void;
};

function createId(): string {
  return `hist_${Date.now().toString(36)}_${Math.random().toString(36).slice(2, 10)}`;
}

function computeTotal(entries: ConversionHistoryEntry[]): number {
  return entries.reduce((sum, entry) => sum + entry.sizeOnDisk, 0);
}

function parseEntries(raw: string | null): ConversionHistoryEntry[] {
  if (!raw) return [];
  try {
    const parsed = JSON.parse(raw) as ConversionHistoryEntry[];
    return Array.isArray(parsed) ? parsed : [];
  } catch {
    return [];
  }
}

export function createConversionHistoryStore(
  storage: KeyValueStorage
): ConversionHistoryStore {
  let isEnabled = false;
  let persistedEntries: ConversionHistoryEntry[] = [];
  let sessionEntries: ConversionHistoryEntry[] = [];
  let entries: ConversionHistoryEntry[] = [];
  let totalStorageBytes = 0;

  const refreshForCurrentSettings = () => {
    entries = isEnabled ? [...persistedEntries] : [...sessionEntries];
    totalStorageBytes = computeTotal(entries);
  };

  const persistIndex = async () => {
    await storage.setItem(HISTORY_ENTRIES_KEY, JSON.stringify(persistedEntries));
  };

  return {
    get isEnabled() {
      return isEnabled;
    },
    get entries() {
      return entries;
    },
    get totalStorageBytes() {
      return totalStorageBytes;
    },
    get storageSummaryTitle() {
      return isEnabled ? 'Saved history is on' : 'Session history only';
    },
    get storageSummaryDescription() {
      if (isEnabled) {
        return 'New conversions are saved on this device and stay in History until you delete them.';
      }
      return 'New conversions are kept for this app session only. They are removed after you quit and reopen the app.';
    },
    refreshForCurrentSettings,
    async load() {
      const enabledRaw = await storage.getItem(HISTORY_ENABLED_KEY);
      isEnabled = enabledRaw === 'true' || enabledRaw === '1';
      persistedEntries = parseEntries(await storage.getItem(HISTORY_ENTRIES_KEY));
      refreshForCurrentSettings();
    },
    async setEnabled(enabled, options) {
      isEnabled = enabled;
      await storage.setItem(HISTORY_ENABLED_KEY, enabled ? 'true' : 'false');
      if (!enabled && options?.clearPersisted) {
        persistedEntries = [];
        await persistIndex();
      }
      refreshForCurrentSettings();
    },
    async record(input) {
      if (!input.result?.path) return null;

      const entry: ConversionHistoryEntry = {
        id: createId(),
        createdAt: new Date().toISOString(),
        inputFilename: input.inputFilename,
        inputCategory: input.inputCategory,
        outputFormat: input.result.outputFormat,
        resultPath: input.result.path,
        sizeOnDisk: input.result.sizeOnDisk,
        dimensions: input.result.dimensions,
        configSummary: {
          targetSizeBytes: input.config.targetSizeBytes,
          targetFPS: input.config.targetFPS,
          targetDimensions: input.config.targetDimensions,
        },
      };

      if (isEnabled) {
        persistedEntries = [entry, ...persistedEntries];
        await persistIndex();
      } else {
        sessionEntries = [entry, ...sessionEntries];
      }
      refreshForCurrentSettings();
      return entry;
    },
    async removeEntry(id) {
      if (isEnabled) {
        persistedEntries = persistedEntries.filter((entry) => entry.id !== id);
        await persistIndex();
      } else {
        sessionEntries = sessionEntries.filter((entry) => entry.id !== id);
      }
      refreshForCurrentSettings();
    },
    async clear() {
      if (isEnabled) {
        persistedEntries = [];
        await persistIndex();
      } else {
        sessionEntries = [];
      }
      refreshForCurrentSettings();
    },
  };
}
