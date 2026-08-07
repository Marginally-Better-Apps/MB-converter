import { router } from 'expo-router';
import { StatusBar } from 'expo-status-bar';
import { useState } from 'react';
import { Alert, Linking, Pressable, ScrollView, Switch, Text, View } from 'react-native';

import { ScreenContent } from '@/components/ScreenContent';
import { getCreditsNotice } from '@/src/core/credits';
import type { AppColorMode } from '@/src/core/settings/colorMode';
import { useHistory } from '@/src/features/history/HistoryContext';
import { useSettings } from '@/src/features/settings/SettingsContext';

const COLOR_MODES: Array<{ id: AppColorMode; label: string }> = [
  { id: 'system', label: 'System' },
  { id: 'light', label: 'Light' },
  { id: 'dark', label: 'Dark' },
];

export default function ModalScreen() {
  const { colorMode, setColorMode, resolvedScheme } = useSettings();
  const { isEnabled, setEnabled } = useHistory();
  const [busy, setBusy] = useState(false);
  const credits = getCreditsNotice();

  const onToggleHistory = (next: boolean) => {
    if (isEnabled && !next) {
      Alert.alert(
        'Switch to session-only history?',
        'Turning off saved history removes every saved conversion from this device. Afterward, History only keeps items from this session.',
        [
          { text: 'Cancel', style: 'cancel' },
          {
            text: 'Switch',
            style: 'destructive',
            onPress: () => {
              setBusy(true);
              void setEnabled(false, { clearPersisted: true }).finally(() => setBusy(false));
            },
          },
        ]
      );
      return;
    }
    setBusy(true);
    void setEnabled(next).finally(() => setBusy(false));
  };

  return (
    <ScrollView
      testID="settings-screen"
      className="flex-1 bg-mb-background-light dark:bg-mb-background-dark"
      contentContainerClassName="pb-10 pt-8"
      accessibilityLabel="Settings"
    >
      <ScreenContent>
        <Text className="mb-2 text-2xl font-bold text-mb-text-light dark:text-mb-text-dark">
          Settings
        </Text>
        <Text className="mb-6 text-sm text-mb-textMuted-light dark:text-mb-textMuted-dark">
          Appearance and conversion history preferences.
        </Text>

        <Text className="mb-3 text-sm font-semibold uppercase tracking-wide text-mb-textMuted-light dark:text-mb-textMuted-dark">
          Appearance
        </Text>
        <View
          testID="settings-color-mode"
          className="mb-6 flex-row flex-wrap gap-2 rounded-2xl border border-mb-accent-light/30 bg-mb-surface-light p-3 dark:border-mb-accent-dark/50 dark:bg-mb-surface-dark"
        >
          {COLOR_MODES.map((mode) => {
            const active = colorMode === mode.id;
            return (
              <Pressable
                key={mode.id}
                testID={`settings-color-${mode.id}`}
                accessibilityRole="button"
                accessibilityLabel={`${mode.label} appearance`}
                accessibilityState={{ selected: active }}
                onPress={() => void setColorMode(mode.id)}
                className={`rounded-full px-4 py-2 ${
                  active
                    ? 'bg-mb-primary-light dark:bg-mb-primary-dark'
                    : 'bg-mb-secondary-light/40 dark:bg-mb-secondary-dark/40'
                }`}
              >
                <Text
                  className={`text-sm ${
                    active
                      ? 'font-semibold text-mb-background-light dark:text-mb-background-dark'
                      : 'text-mb-text-light dark:text-mb-text-dark'
                  }`}
                >
                  {mode.label}
                </Text>
              </Pressable>
            );
          })}
        </View>

        <Text className="mb-3 text-sm font-semibold uppercase tracking-wide text-mb-textMuted-light dark:text-mb-textMuted-dark">
          History
        </Text>
        <View className="mb-6 flex-row items-center justify-between rounded-2xl border border-mb-accent-light/30 bg-mb-surface-light p-4 dark:border-mb-accent-dark/50 dark:bg-mb-surface-dark">
          <View className="mr-3 flex-1">
            <Text className="text-base font-semibold text-mb-text-light dark:text-mb-text-dark">
              Save conversion history
            </Text>
            <Text className="mt-1 text-sm text-mb-textMuted-light dark:text-mb-textMuted-dark">
              Persist successful conversions across launches.
            </Text>
          </View>
          <Switch
            testID="settings-history-toggle"
            accessibilityLabel="Save conversion history"
            disabled={busy}
            value={isEnabled}
            onValueChange={onToggleHistory}
          />
        </View>

        <Text className="mb-3 text-sm font-semibold uppercase tracking-wide text-mb-textMuted-light dark:text-mb-textMuted-dark">
          Legal
        </Text>
        <View className="mb-6 rounded-2xl border border-mb-accent-light/30 bg-mb-surface-light p-4 dark:border-mb-accent-dark/50 dark:bg-mb-surface-dark">
          <Text
            testID="settings-credits-summary"
            className="mb-3 text-sm leading-5 text-mb-textMuted-light dark:text-mb-textMuted-dark"
          >
            {credits.summary}
          </Text>
          <Pressable
            testID="settings-open-credits"
            accessibilityRole="button"
            accessibilityLabel="Open open-source credits and LGPL notice"
            onPress={() => router.push('/credits')}
          >
            <Text className="font-semibold text-mb-primary-light dark:text-mb-primary-dark">
              Credits & LGPL notice
            </Text>
          </Pressable>
        </View>

        <View className="rounded-2xl border border-mb-accent-light/30 bg-mb-surface-light p-4 dark:border-mb-accent-dark/50 dark:bg-mb-surface-dark">
          <View className="mb-3 flex-row justify-between">
            <Text className="text-mb-text-light dark:text-mb-text-dark">Name</Text>
            <Text className="text-mb-textMuted-light dark:text-mb-textMuted-dark">
              Marginally Better Converter
            </Text>
          </View>
          <View className="mb-3 flex-row justify-between">
            <Text className="text-mb-text-light dark:text-mb-text-dark">Version</Text>
            <Text className="text-mb-textMuted-light dark:text-mb-textMuted-dark">1.0</Text>
          </View>
          <Pressable
            testID="settings-github-link"
            accessibilityRole="link"
            accessibilityLabel="Open MB Converter on GitHub"
            onPress={() => {
              void Linking.openURL('https://github.com/Marginally-Better-Apps/MB-converter');
            }}
          >
            <Text className="font-semibold text-mb-primary-light dark:text-mb-primary-dark">
              GitHub
            </Text>
          </Pressable>
        </View>
      </ScreenContent>

      <StatusBar style={resolvedScheme === 'dark' ? 'light' : 'dark'} />
    </ScrollView>
  );
}
