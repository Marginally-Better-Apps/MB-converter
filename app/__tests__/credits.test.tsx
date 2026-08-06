import React from 'react';
import { render, screen } from '@testing-library/react-native';

import CreditsScreen from '../credits';
import { SettingsProvider } from '@/src/features/settings/SettingsContext';

describe('CreditsScreen', () => {
  it('shows LGPL summary and outbound links', async () => {
    await render(
      <SettingsProvider>
        <CreditsScreen />
      </SettingsProvider>
    );

    expect(screen.getByTestId('credits-screen')).toBeOnTheScreen();
    expect(screen.getByTestId('credits-summary')).toHaveTextContent(/LGPL/);
    expect(screen.getByTestId('credits-package')).toHaveTextContent(/ffmpeg-kit-spm/);
    expect(screen.getByTestId('credits-ffmpeg-link')).toBeOnTheScreen();
    expect(screen.getByTestId('credits-spm-link')).toBeOnTheScreen();
  });
});
