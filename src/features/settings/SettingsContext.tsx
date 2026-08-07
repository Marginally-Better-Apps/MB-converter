import AsyncStorage from '@react-native-async-storage/async-storage';
import { colorScheme as nativewindColorScheme } from 'nativewind';
import React, {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useState,
} from 'react';
import { Appearance, useColorScheme as useSystemColorScheme } from 'react-native';

import {
  createColorModeStore,
  resolveColorScheme,
  type AppColorMode,
} from '@/src/core/settings/colorMode';

type SettingsContextValue = {
  colorMode: AppColorMode;
  resolvedScheme: 'light' | 'dark';
  setColorMode: (mode: AppColorMode) => Promise<void>;
  isReady: boolean;
};

const SettingsContext = createContext<SettingsContextValue | null>(null);

function applyAppearance(mode: AppColorMode) {
  // NativeWind class dark mode + RN Appearance for StatusBar / navigation.
  nativewindColorScheme.set(mode);
  const setScheme = Appearance.setColorScheme as (scheme: 'light' | 'dark' | null) => void;
  if (mode === 'system') {
    setScheme(null);
  } else {
    setScheme(mode);
  }
}

export function SettingsProvider({ children }: { children: React.ReactNode }) {
  const systemScheme = useSystemColorScheme();
  const system: 'light' | 'dark' =
    systemScheme === 'dark' ? 'dark' : 'light';

  const store = useMemo(() => createColorModeStore(AsyncStorage), []);
  const [colorMode, setColorModeState] = useState<AppColorMode>('system');
  const [isReady, setIsReady] = useState(false);

  useEffect(() => {
    let cancelled = false;
    void (async () => {
      await store.load();
      if (cancelled) return;
      setColorModeState(store.mode);
      applyAppearance(store.mode);
      setIsReady(true);
    })();
    return () => {
      cancelled = true;
    };
  }, [store]);

  const setColorMode = useCallback(
    async (mode: AppColorMode) => {
      await store.setMode(mode);
      setColorModeState(mode);
      applyAppearance(mode);
    },
    [store]
  );

  const resolvedScheme = resolveColorScheme(colorMode, system);

  const value = useMemo<SettingsContextValue>(
    () => ({
      colorMode,
      resolvedScheme,
      setColorMode,
      isReady,
    }),
    [colorMode, resolvedScheme, setColorMode, isReady]
  );

  return <SettingsContext.Provider value={value}>{children}</SettingsContext.Provider>;
}

export function useSettings(): SettingsContextValue {
  const ctx = useContext(SettingsContext);
  if (!ctx) {
    throw new Error('useSettings must be used within SettingsProvider');
  }
  return ctx;
}

export function useOptionalSettings(): SettingsContextValue | null {
  return useContext(SettingsContext);
}
