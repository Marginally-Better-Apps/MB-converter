import React from 'react';
import { render, screen, userEvent } from '@testing-library/react-native';

import ConvertConfigScreen from '../config';
import { ConversionProvider, useConversion } from '@/src/features/conversion/ConversionContext';
import type { ConversionSessionInput } from '@/src/features/conversion/ConversionContext';
import { HistoryProvider } from '@/src/features/history/HistoryContext';
import { SettingsProvider } from '@/src/features/settings/SettingsContext';

jest.mock('expo-router', () => ({
  router: {
    push: jest.fn(),
    replace: jest.fn(),
    back: jest.fn(),
  },
}));

jest.mock('expo-file-system', () => ({
  Directory: class Directory {
    exists = true;
    uri = 'file:///cache/conversions';
    create() {}
  },
  File: class File {
    exists = true;
    size = 100;
  },
  Paths: { cache: 'file:///cache/' },
}));

function Seed({ input }: { input: ConversionSessionInput }) {
  const { setSessionInput, setConfig } = useConversion();
  React.useEffect(() => {
    setSessionInput(input);
    setConfig({
      outputFormat: 'mp4_h264',
      targetSizeBytes: Math.floor(input.byteSize * 0.5),
      usesSinglePassVideoTargetEncode: true,
    });
  }, [input, setConfig, setSessionInput]);
  return <ConvertConfigScreen />;
}

function Providers({ children }: { children: React.ReactNode }) {
  return (
    <SettingsProvider>
      <HistoryProvider>
        <ConversionProvider>{children}</ConversionProvider>
      </HistoryProvider>
    </SettingsProvider>
  );
}

describe('ConvertConfigScreen', () => {
  it(
    'lists allowed formats and can start conversion navigation',
    async () => {
      const user = userEvent.setup();
      await render(
        <Providers>
          <Seed
            input={{
              uri: 'file:///tmp/clip.mp4',
              filename: 'clip.mp4',
              category: 'video',
              byteSize: 5_000_000,
              duration: 12,
              dimensions: { width: 1920, height: 1080 },
              fps: 30,
            }}
          />
        </Providers>
      );

      expect(await screen.findByTestId('convert-config-screen')).toBeOnTheScreen();
      expect(screen.getByTestId('convert-format-mp4_h264')).toBeOnTheScreen();
      expect(screen.getByTestId('convert-format-m4a')).toBeOnTheScreen();
      expect(screen.getByTestId('convert-config-resolution')).toBeOnTheScreen();
      expect(screen.getByTestId('convert-config-fps')).toBeOnTheScreen();
      expect(screen.getByTestId('convert-config-metadata')).toBeOnTheScreen();
      expect(screen.getByTestId('convert-config-start')).toBeOnTheScreen();

      await user.press(screen.getByTestId('convert-format-m4a'));
      await user.press(screen.getByTestId('convert-config-start'));

      const { router } = jest.requireMock('expo-router');
      expect(router.push).toHaveBeenCalledWith('/convert/processing');
    },
    20_000
  );
});
