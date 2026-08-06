import * as MediaLibrary from 'expo-media-library';
import * as Sharing from 'expo-sharing';
import { router } from 'expo-router';
import { useState } from 'react';
import { Alert, Pressable, Text, View } from 'react-native';

import { displayName, fileExtension } from '@/src/core/ffmpeg/outputFormatArgs';
import { useConversion } from '@/src/features/conversion/ConversionContext';

function formatBytes(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(2)} MB`;
}

function toFileUri(path: string): string {
  return path.startsWith('file://') ? path : `file://${path}`;
}

export default function ResultScreen() {
  const { input, result, resetResult } = useConversion();
  const [busy, setBusy] = useState(false);

  if (!result) {
    return (
      <View
        testID="result-screen"
        className="flex-1 items-center justify-center bg-mb-background-light px-6 dark:bg-mb-background-dark"
      >
        <Text className="mb-4 text-center text-mb-textMuted-light dark:text-mb-textMuted-dark">
          No conversion result yet.
        </Text>
        <Pressable
          testID="result-go-home"
          onPress={() => router.replace('/')}
          className="rounded-2xl bg-mb-primary-light px-4 py-3 dark:bg-mb-primary-dark"
        >
          <Text className="font-semibold text-mb-background-light dark:text-mb-background-dark">
            Go to Home
          </Text>
        </Pressable>
      </View>
    );
  }

  const uri = toFileUri(result.path);
  const outputName = `${(input?.filename ?? 'output').replace(/\.[^.]+$/, '')}.${fileExtension(result.outputFormat)}`;

  const onShare = async () => {
    setBusy(true);
    try {
      const available = await Sharing.isAvailableAsync();
      if (!available) {
        Alert.alert('Sharing unavailable', 'Sharing is not available on this device.');
        return;
      }
      await Sharing.shareAsync(uri, {
        mimeType: undefined,
        dialogTitle: 'Share converted file',
      });
    } catch (error) {
      Alert.alert('Share failed', error instanceof Error ? error.message : 'Please try again.');
    } finally {
      setBusy(false);
    }
  };

  const onSave = async () => {
    setBusy(true);
    try {
      const permission = await MediaLibrary.requestPermissionsAsync(true);
      if (!permission.granted) {
        Alert.alert('Permission needed', 'Allow photo library access to save the file.');
        return;
      }
      await MediaLibrary.saveToLibraryAsync(uri);
      Alert.alert('Saved', 'The converted file was saved to your photo library.');
    } catch (error) {
      Alert.alert(
        'Save failed',
        error instanceof Error
          ? `${error.message}\n\nTip: share the file instead for formats Photos may not accept.`
          : 'Please try again.'
      );
    } finally {
      setBusy(false);
    }
  };

  const onDone = () => {
    resetResult();
    router.replace('/');
  };

  return (
    <View
      testID="result-screen"
      className="flex-1 bg-mb-background-light px-6 pt-6 dark:bg-mb-background-dark"
    >
      <Text className="mb-2 text-2xl font-bold text-mb-text-light dark:text-mb-text-dark">
        Done
      </Text>
      <Text className="mb-6 text-sm text-mb-textMuted-light dark:text-mb-textMuted-dark">
        Your file is ready to share or save.
      </Text>

      <View className="mb-8 rounded-2xl border border-mb-accent-light/30 bg-mb-surface-light p-4 dark:border-mb-accent-dark/50 dark:bg-mb-surface-dark">
        <Text
          testID="result-filename"
          className="text-base font-semibold text-mb-text-light dark:text-mb-text-dark"
        >
          {outputName}
        </Text>
        <Text
          testID="result-format"
          className="mt-2 text-sm text-mb-textMuted-light dark:text-mb-textMuted-dark"
        >
          Format: {displayName(result.outputFormat)}
        </Text>
        <Text
          testID="result-size"
          className="mt-1 text-sm text-mb-textMuted-light dark:text-mb-textMuted-dark"
        >
          Size: {formatBytes(result.sizeOnDisk)}
        </Text>
        {result.dimensions ? (
          <Text className="mt-1 text-sm text-mb-textMuted-light dark:text-mb-textMuted-dark">
            Dimensions: {Math.round(result.dimensions.width)}×{Math.round(result.dimensions.height)}
          </Text>
        ) : null}
      </View>

      <Pressable
        testID="result-share"
        disabled={busy}
        onPress={() => void onShare()}
        className="mb-3 items-center rounded-2xl bg-mb-primary-light px-4 py-3.5 dark:bg-mb-primary-dark"
      >
        <Text className="text-base font-semibold text-mb-background-light dark:text-mb-background-dark">
          Share
        </Text>
      </Pressable>

      <Pressable
        testID="result-save"
        disabled={busy}
        onPress={() => void onSave()}
        className="mb-3 items-center rounded-2xl border border-mb-accent-light/40 px-4 py-3.5 dark:border-mb-accent-dark/50"
      >
        <Text className="text-base font-semibold text-mb-text-light dark:text-mb-text-dark">
          Save to Photos
        </Text>
      </Pressable>

      <Pressable
        testID="result-done"
        onPress={onDone}
        className="items-center px-4 py-3"
      >
        <Text className="text-base font-semibold text-mb-primary-light dark:text-mb-primary-dark">
          Done
        </Text>
      </Pressable>
    </View>
  );
}
