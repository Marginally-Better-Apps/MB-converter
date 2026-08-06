import { getThemeTokens, theme } from '@/constants/theme';

describe('theme tokens', () => {
  it('matches legacy Swift Theme.swift light/dark hex values', () => {
    expect(theme.light).toEqual({
      text: '#050b0f',
      background: '#eff6fb',
      primary: '#003a5c',
      secondary: '#7fc7f0',
      accent: '#3cb2f6',
      surface: '#ffffff',
      textMuted: '#4a5660',
    });

    expect(theme.dark).toEqual({
      text: '#f0f6fa',
      background: '#0B1622',
      primary: '#a3ddff',
      secondary: '#0f5680',
      accent: '#081d2a',
      surface: '#152233',
      textMuted: '#9aa9b8',
    });
  });

  it('resolves light tokens by default', () => {
    expect(getThemeTokens(undefined).background).toBe('#eff6fb');
    expect(getThemeTokens('dark').background).toBe('#0B1622');
  });
});
