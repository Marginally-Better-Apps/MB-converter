import React from 'react';
import { render, screen, userEvent, waitFor } from '@testing-library/react-native';

import ModalScreen from '../modal';
import { HistoryProvider } from '@/src/features/history/HistoryContext';
import { SettingsProvider } from '@/src/features/settings/SettingsContext';

jest.mock('expo-router', () => ({
  router: {
    push: jest.fn(),
    back: jest.fn(),
    replace: jest.fn(),
  },
}));

describe('SettingsScreen', () => {
  it('exposes color mode, history toggle, and LGPL credits entry', async () => {
    const user = userEvent.setup();
    await render(
      <SettingsProvider>
        <HistoryProvider>
          <ModalScreen />
        </HistoryProvider>
      </SettingsProvider>
    );

    expect(screen.getByTestId('settings-screen')).toBeOnTheScreen();
    expect(screen.getByTestId('settings-color-mode')).toBeOnTheScreen();
    expect(screen.getByTestId('settings-history-toggle')).toBeOnTheScreen();
    expect(screen.getByTestId('settings-credits-summary')).toHaveTextContent(/LGPL/);
    expect(screen.getByTestId('settings-open-credits')).toBeOnTheScreen();

    await user.press(screen.getByTestId('settings-color-dark'));
    await waitFor(() => {
      expect(screen.getByTestId('settings-color-dark').props.accessibilityState).toEqual({
        selected: true,
      });
    });
  });
});
