import AsyncStorage from '@react-native-async-storage/async-storage';
import React, {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useState,
} from 'react';

import type { ConversionResult } from '@/src/core/conversion/ConversionService';
import {
  createConversionHistoryStore,
  type ConversionHistoryEntry,
} from '@/src/core/history/ConversionHistoryStore';
import type { ConversionConfig, MediaCategory } from '@/src/core/models/types';

type HistoryContextValue = {
  isEnabled: boolean;
  entries: ConversionHistoryEntry[];
  totalStorageBytes: number;
  storageSummaryTitle: string;
  storageSummaryDescription: string;
  isReady: boolean;
  setEnabled: (enabled: boolean, options?: { clearPersisted?: boolean }) => Promise<void>;
  recordSuccess: (input: {
    inputFilename: string;
    inputCategory: MediaCategory;
    config: ConversionConfig;
    result: ConversionResult;
  }) => Promise<void>;
  removeEntry: (id: string) => Promise<void>;
  clear: () => Promise<void>;
};

const HistoryContext = createContext<HistoryContextValue | null>(null);

export function HistoryProvider({ children }: { children: React.ReactNode }) {
  const store = useMemo(() => createConversionHistoryStore(AsyncStorage), []);
  const [isReady, setIsReady] = useState(false);
  const [isEnabled, setIsEnabled] = useState(false);
  const [entries, setEntries] = useState<ConversionHistoryEntry[]>([]);
  const [totalStorageBytes, setTotalStorageBytes] = useState(0);
  const [storageSummaryTitle, setStorageSummaryTitle] = useState('Session history only');
  const [storageSummaryDescription, setStorageSummaryDescription] = useState('');

  const syncFromStore = useCallback(() => {
    store.refreshForCurrentSettings();
    setIsEnabled(store.isEnabled);
    setEntries([...store.entries]);
    setTotalStorageBytes(store.totalStorageBytes);
    setStorageSummaryTitle(store.storageSummaryTitle);
    setStorageSummaryDescription(store.storageSummaryDescription);
  }, [store]);

  useEffect(() => {
    let cancelled = false;
    void (async () => {
      await store.load();
      if (cancelled) return;
      syncFromStore();
      setIsReady(true);
    })();
    return () => {
      cancelled = true;
    };
  }, [store, syncFromStore]);

  const setEnabled = useCallback(
    async (enabled: boolean, options?: { clearPersisted?: boolean }) => {
      await store.setEnabled(enabled, options);
      syncFromStore();
    },
    [store, syncFromStore]
  );

  const recordSuccess = useCallback(
    async (input: {
      inputFilename: string;
      inputCategory: MediaCategory;
      config: ConversionConfig;
      result: ConversionResult;
    }) => {
      await store.record(input);
      syncFromStore();
    },
    [store, syncFromStore]
  );

  const removeEntry = useCallback(
    async (id: string) => {
      await store.removeEntry(id);
      syncFromStore();
    },
    [store, syncFromStore]
  );

  const clear = useCallback(async () => {
    await store.clear();
    syncFromStore();
  }, [store, syncFromStore]);

  const value = useMemo<HistoryContextValue>(
    () => ({
      isEnabled,
      entries,
      totalStorageBytes,
      storageSummaryTitle,
      storageSummaryDescription,
      isReady,
      setEnabled,
      recordSuccess,
      removeEntry,
      clear,
    }),
    [
      isEnabled,
      entries,
      totalStorageBytes,
      storageSummaryTitle,
      storageSummaryDescription,
      isReady,
      setEnabled,
      recordSuccess,
      removeEntry,
      clear,
    ]
  );

  return <HistoryContext.Provider value={value}>{children}</HistoryContext.Provider>;
}

export function useHistory(): HistoryContextValue {
  const ctx = useContext(HistoryContext);
  if (!ctx) {
    throw new Error('useHistory must be used within HistoryProvider');
  }
  return ctx;
}
