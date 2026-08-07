import { useColorScheme as useSystemColorScheme } from 'react-native';

import { useOptionalSettings } from '@/src/features/settings/SettingsContext';

/** Resolved light/dark for themed components, respecting Settings color mode when present. */
export function useColorScheme(): 'light' | 'dark' {
  const settings = useOptionalSettings();
  const system = useSystemColorScheme();
  if (settings) return settings.resolvedScheme;
  return system === 'dark' ? 'dark' : 'light';
}
