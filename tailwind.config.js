/** @type {import('tailwindcss').Config} */
module.exports = {
  content: [
    './app/**/*.{js,jsx,ts,tsx}',
    './components/**/*.{js,jsx,ts,tsx}',
    './src/**/*.{js,jsx,ts,tsx}',
  ],
  presets: [require('nativewind/preset')],
  darkMode: 'class',
  theme: {
    extend: {
      colors: {
        text: {
          DEFAULT: 'var(--color-text)',
          muted: 'var(--color-text-muted)',
        },
        background: 'var(--color-background)',
        primary: 'var(--color-primary)',
        secondary: 'var(--color-secondary)',
        accent: 'var(--color-accent)',
        surface: 'var(--color-surface)',
        // Static palette from legacy Swift Theme.swift (light / dark)
        mb: {
          text: {
            light: '#050b0f',
            dark: '#f0f6fa',
          },
          background: {
            light: '#eff6fb',
            dark: '#0B1622',
          },
          primary: {
            light: '#003a5c',
            dark: '#a3ddff',
          },
          secondary: {
            light: '#7fc7f0',
            dark: '#0f5680',
          },
          accent: {
            light: '#3cb2f6',
            dark: '#081d2a',
          },
          surface: {
            light: '#ffffff',
            dark: '#152233',
          },
          textMuted: {
            light: '#4a5660',
            dark: '#9aa9b8',
          },
        },
      },
    },
  },
  plugins: [],
};
