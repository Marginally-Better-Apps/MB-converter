import React from 'react';
import { render, screen, userEvent, waitFor } from '@testing-library/react-native';

import HistoryScreen from '../history';
import { HistoryProvider, useHistory } from '@/src/features/history/HistoryContext';
import { SettingsProvider } from '@/src/features/settings/SettingsContext';

function SeedHistory() {
  const { setEnabled, recordSuccess } = useHistory();
  React.useEffect(() => {
    void (async () => {
      await setEnabled(true);
      await recordSuccess({
        inputFilename: 'demo.mp4',
        inputCategory: 'video',
        config: { outputFormat: 'mp4_h264', targetSizeBytes: 1000 },
        result: {
          path: '/tmp/out.mp4',
          outputFormat: 'mp4_h264',
          sizeOnDisk: 1234,
        },
      });
    })();
  }, [recordSuccess, setEnabled]);
  return <HistoryScreen />;
}

describe('HistoryScreen', () => {
  it('shows empty state by default', async () => {
    await render(
      <SettingsProvider>
        <HistoryProvider>
          <HistoryScreen />
        </HistoryProvider>
      </SettingsProvider>
    );

    expect(screen.getByTestId('history-screen')).toBeOnTheScreen();
    expect(screen.getByTestId('history-empty')).toBeOnTheScreen();
  });

  it('lists recorded entries and can clear them', async () => {
    const user = userEvent.setup();
    await render(
      <SettingsProvider>
        <HistoryProvider>
          <SeedHistory />
        </HistoryProvider>
      </SettingsProvider>
    );

    await waitFor(() => {
      expect(screen.getByTestId('history-list')).toBeOnTheScreen();
    });
    expect(screen.getByText('demo.mp4')).toBeOnTheScreen();

    await user.press(screen.getByTestId('history-clear-all'));
    await waitFor(() => {
      expect(screen.getByTestId('history-empty')).toBeOnTheScreen();
    });
  });
});
