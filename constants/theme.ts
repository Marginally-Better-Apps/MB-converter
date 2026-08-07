/**
 * Color tokens mirrored from legacy/swift/DesignSystem/Theme.swift.
 * Light / dark hex values are the source of truth for NativeWind + RN styles.
 */
export const theme = {
  light: {
    text: '#050b0f',
    background: '#eff6fb',
    primary: '#003a5c',
    secondary: '#7fc7f0',
    accent: '#3cb2f6',
    surface: '#ffffff',
    textMuted: '#4a5660',
  },
  dark: {
    text: '#f0f6fa',
    background: '#0B1622',
    primary: '#a3ddff',
    secondary: '#0f5680',
    /** Intentionally darker than background — borders / disabled, not CTAs. */
    accent: '#081d2a',
    surface: '#152233',
    textMuted: '#9aa9b8',
  },
} as const;

export type ThemeScheme = keyof typeof theme;
export type ThemeTokens = (typeof theme)[ThemeScheme];

export function getThemeTokens(scheme: ThemeScheme | null | undefined): ThemeTokens {
  return scheme === 'dark' ? theme.dark : theme.light;
}
