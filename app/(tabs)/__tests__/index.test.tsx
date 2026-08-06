import React from 'react';
import { render, screen } from '@testing-library/react-native';
import { SafeAreaProvider } from 'react-native-safe-area-context';

import HomeScreen from '../index';
import { ImportProvider } from '@/src/features/home/ImportContext';

jest.mock('expo-router', () => ({
  router: {
    push: jest.fn(),
    back: jest.fn(),
  },
}));

jest.mock('expo-clipboard', () => ({
  hasImageAsync: jest.fn(async () => false),
  getUrlAsync: jest.fn(async () => null),
  getImageAsync: jest.fn(async () => null),
}));

jest.mock('expo-image-picker', () => ({
  requestMediaLibraryPermissionsAsync: jest.fn(async () => ({ granted: true })),
  launchImageLibraryAsync: jest.fn(async () => ({ canceled: true, assets: [] })),
}));

jest.mock('expo-document-picker', () => ({
  getDocumentAsync: jest.fn(async () => ({ canceled: true, assets: [] })),
}));

jest.mock('expo-file-system', () => ({
  Directory: class Directory {},
  File: class File {},
  Paths: { cache: 'file:///cache/' },
}));

describe('HomeScreen', () => {
  it('renders the MB Converter title and primary import actions', async () => {
    await render(
      <SafeAreaProvider
        initialMetrics={{
          frame: { x: 0, y: 0, width: 390, height: 844 },
          insets: { top: 47, left: 0, right: 0, bottom: 34 },
        }}
      >
        <ImportProvider>
          <HomeScreen />
        </ImportProvider>
      </SafeAreaProvider>
    );

    expect(screen.getByTestId('home-screen')).toBeOnTheScreen();
    expect(screen.getByTestId('home-title')).toHaveTextContent('MB Converter');
    expect(screen.getByText('MB Converter')).toBeOnTheScreen();
    expect(screen.getByTestId('import-photos')).toBeOnTheScreen();
    expect(screen.getByTestId('import-files')).toBeOnTheScreen();
    expect(screen.getByTestId('import-link')).toBeOnTheScreen();
    expect(screen.getByTestId('import-paste')).toBeOnTheScreen();
    expect(screen.getByText('Convert & Compress')).toBeOnTheScreen();
  });
});
