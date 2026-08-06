import { router } from 'expo-router';
import { useEffect, useRef } from 'react';
import { ActivityIndicator, Pressable, Text, View } from 'react-native';

import { useConversion } from '@/src/features/conversion/ConversionContext';

export default function ProcessingScreen() {
  const {
    input,
    config,
    progress,
    isConverting,
    errorMessage,
    startConversion,
    cancelConversion,
    clearError,
  } = useConversion();
  const started = useRef(false);

  useEffect(() => {
    if (started.current) return;
    if (!input || !config) {
      router.replace('/');
      return;
    }
    started.current = true;
    void (async () => {
      const result = await startConversion();
      if (result) {
        router.replace('/convert/result');
      }
    })();
  }, [config, input, startConversion]);

  const percent = Math.round(Math.min(1, Math.max(0, progress)) * 100);

  const onCancel = async () => {
    await cancelConversion();
    router.back();
  };

  const onRetry = () => {
    clearError();
    started.current = false;
    router.replace('/convert/processing');
  };

  return (
    <View
      testID="processing-screen"
      className="flex-1 items-center justify-center bg-mb-background-light px-6 dark:bg-mb-background-dark"
    >
      <View className="pointer-events-none absolute inset-0 overflow-hidden">
        <View className="absolute -left-10 top-24 h-64 w-64 rounded-full bg-mb-secondary-light/30 dark:bg-mb-secondary-dark/40" />
        <View className="absolute -right-8 bottom-32 h-72 w-72 rounded-full bg-mb-primary-light/10 dark:bg-mb-primary-dark/15" />
      </View>

      {errorMessage ? (
        <>
          <Text
            testID="processing-error"
            className="mb-4 text-center text-lg font-semibold text-mb-text-light dark:text-mb-text-dark"
          >
            Conversion failed
          </Text>
          <Text className="mb-8 text-center text-sm text-mb-textMuted-light dark:text-mb-textMuted-dark">
            {errorMessage}
          </Text>
          <Pressable
            testID="processing-retry"
            onPress={onRetry}
            className="mb-3 w-full max-w-sm items-center rounded-2xl bg-mb-primary-light px-4 py-3.5 dark:bg-mb-primary-dark"
          >
            <Text className="font-semibold text-mb-background-light dark:text-mb-background-dark">
              Try again
            </Text>
          </Pressable>
          <Pressable
            testID="processing-back"
            onPress={() => router.back()}
            className="w-full max-w-sm items-center rounded-2xl border border-mb-accent-light/40 px-4 py-3.5 dark:border-mb-accent-dark/50"
          >
            <Text className="font-semibold text-mb-text-light dark:text-mb-text-dark">
              Back to settings
            </Text>
          </Pressable>
        </>
      ) : (
        <>
          <ActivityIndicator size="large" />
          <Text
            testID="processing-title"
            className="mt-6 text-xl font-semibold text-mb-text-light dark:text-mb-text-dark"
          >
            Converting…
          </Text>
          <Text
            testID="processing-progress"
            className="mt-3 text-3xl font-bold text-mb-primary-light dark:text-mb-primary-dark"
          >
            {percent}%
          </Text>
          <View className="mt-6 h-2 w-full max-w-sm overflow-hidden rounded-full bg-mb-secondary-light/40 dark:bg-mb-secondary-dark/50">
            <View
              className="h-full rounded-full bg-mb-primary-light dark:bg-mb-primary-dark"
              style={{ width: `${percent}%` }}
            />
          </View>
          <Pressable
            testID="processing-cancel"
            accessibilityRole="button"
            accessibilityLabel="Cancel conversion"
            disabled={!isConverting && progress <= 0}
            onPress={() => void onCancel()}
            className="mt-10 items-center rounded-2xl border border-mb-accent-light/40 px-6 py-3 dark:border-mb-accent-dark/50"
          >
            <Text className="font-semibold text-mb-text-light dark:text-mb-text-dark">Cancel</Text>
          </Pressable>
        </>
      )}
    </View>
  );
}
