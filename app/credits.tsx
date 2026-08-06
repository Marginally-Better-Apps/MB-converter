import { StatusBar } from 'expo-status-bar';
import { Linking, Pressable, ScrollView, Text, View } from 'react-native';

import { ScreenContent } from '@/components/ScreenContent';
import {
  FFMPEG_KIT_SPM_URL,
  FFMPEG_SOURCE_URL,
  getCreditsNotice,
} from '@/src/core/credits';
import { useSettings } from '@/src/features/settings/SettingsContext';

export default function CreditsScreen() {
  const { resolvedScheme } = useSettings();
  const notice = getCreditsNotice();

  return (
    <ScrollView
      testID="credits-screen"
      className="flex-1 bg-mb-background-light dark:bg-mb-background-dark"
      contentContainerClassName="pb-10 pt-6"
      accessibilityLabel="Open-source credits and LGPL notice"
    >
      <ScreenContent>
        <Text className="mb-2 text-2xl font-bold text-mb-text-light dark:text-mb-text-dark">
          {notice.title}
        </Text>
        <Text
          testID="credits-summary"
          className="mb-6 text-sm leading-5 text-mb-textMuted-light dark:text-mb-textMuted-dark"
        >
          {notice.summary}
        </Text>

        <View className="mb-6 rounded-2xl border border-mb-accent-light/30 bg-mb-surface-light p-4 dark:border-mb-accent-dark/50 dark:bg-mb-surface-dark">
          <Text className="mb-2 text-sm font-semibold text-mb-text-light dark:text-mb-text-dark">
            FFmpeg package
          </Text>
          <Text
            testID="credits-package"
            className="mb-4 text-sm text-mb-textMuted-light dark:text-mb-textMuted-dark"
          >
            {notice.ffmpegPackage}
          </Text>
          {notice.bullets.map((bullet) => (
            <Text
              key={bullet}
              className="mb-2 text-sm leading-5 text-mb-text-light dark:text-mb-text-dark"
            >
              • {bullet}
            </Text>
          ))}
        </View>

        <Pressable
          testID="credits-ffmpeg-link"
          accessibilityRole="link"
          accessibilityLabel="Open FFmpeg website"
          onPress={() => {
            void Linking.openURL(FFMPEG_SOURCE_URL);
          }}
          className="mb-3"
        >
          <Text className="font-semibold text-mb-primary-light dark:text-mb-primary-dark">
            FFmpeg source (ffmpeg.org)
          </Text>
        </Pressable>

        <Pressable
          testID="credits-spm-link"
          accessibilityRole="link"
          accessibilityLabel="Open FFmpegKit SPM packaging on GitHub"
          onPress={() => {
            void Linking.openURL(FFMPEG_KIT_SPM_URL);
          }}
        >
          <Text className="font-semibold text-mb-primary-light dark:text-mb-primary-dark">
            FFmpegKit SPM packaging
          </Text>
        </Pressable>
      </ScreenContent>

      <StatusBar style={resolvedScheme === 'dark' ? 'light' : 'dark'} />
    </ScrollView>
  );
}
