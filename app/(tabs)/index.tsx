import FontAwesome from '@expo/vector-icons/FontAwesome';
import { router } from 'expo-router';
import { useCallback, useEffect, useState } from 'react';
import {
  ActivityIndicator,
  Alert,
  Modal,
  Pressable,
  Text,
  TextInput,
  View,
} from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { ImportActionButton } from '@/components/home/ImportActionButton';
import { useColorScheme } from '@/components/useColorScheme';
import Colors from '@/constants/Colors';
import type { ImportedMedia } from '@/src/core/io/ImportService';
import { remoteDownloadDisplayFraction } from '@/src/core/io/remoteImportHelpers';
import { loadDemoFixtureMedia } from '@/src/features/home/demoFixture';
import { useImport } from '@/src/features/home/ImportContext';

function navigateToImportDetail(media: ImportedMedia) {
  router.push({
    pathname: '/import-detail',
    params: {
      uri: media.uri,
      filename: media.filename,
      category: media.category,
      byteSize: String(media.byteSize),
    },
  });
}

export default function HomeScreen() {
  const insets = useSafeAreaInsets();
  const scheme = useColorScheme() ?? 'light';
  const colors = Colors[scheme];
  const {
    isImporting,
    errorMessage,
    clearError,
    remoteDownloadProgress,
    pasteLabel,
    refreshPasteboard,
    pickFromPhotos,
    pickFromFiles,
    pasteFromClipboard,
    importRemoteLink,
  } = useImport();

  const [linkModalVisible, setLinkModalVisible] = useState(false);
  const [linkText, setLinkText] = useState('');

  useEffect(() => {
    void refreshPasteboard();
  }, [refreshPasteboard]);

  useEffect(() => {
    if (!errorMessage) return;
    Alert.alert('Import Failed', errorMessage, [
      {
        text: 'OK',
        onPress: clearError,
      },
    ]);
  }, [errorMessage, clearError]);

  const onPhotos = useCallback(async () => {
    const media = await pickFromPhotos();
    if (media) navigateToImportDetail(media);
  }, [pickFromPhotos]);

  const onFiles = useCallback(async () => {
    const media = await pickFromFiles();
    if (media) navigateToImportDetail(media);
  }, [pickFromFiles]);

  const onPaste = useCallback(async () => {
    const media = await pasteFromClipboard();
    if (media) navigateToImportDetail(media);
  }, [pasteFromClipboard]);

  const onDownloadLink = useCallback(async () => {
    const text = linkText;
    setLinkModalVisible(false);
    setLinkText('');
    const media = await importRemoteLink(text);
    if (media) navigateToImportDetail(media);
  }, [importRemoteLink, linkText]);

  const onDemoFixture = useCallback(async () => {
    try {
      const media = await loadDemoFixtureMedia();
      navigateToImportDetail(media);
    } catch (error) {
      Alert.alert(
        'Demo fixture unavailable',
        error instanceof Error ? error.message : 'Could not load the sample file.'
      );
    }
  }, []);

  const progressFraction = remoteDownloadProgress
    ? remoteDownloadDisplayFraction(remoteDownloadProgress)
    : null;

  return (
    <View
      testID="home-screen"
      className="flex-1 bg-mb-background-light dark:bg-mb-background-dark"
      style={{ paddingTop: insets.top + 12 }}
    >
      <View className="pointer-events-none absolute inset-0 overflow-hidden">
        <View className="absolute -right-10 -top-16 h-80 w-80 rounded-full bg-mb-primary-light/10 dark:bg-mb-primary-dark/15" />
        <View className="absolute -left-16 top-56 h-56 w-56 rounded-full bg-mb-secondary-light/40 dark:bg-mb-secondary-dark/50" />
      </View>

      <View className="mx-auto w-full max-w-md flex-1 px-6">
        <View className="mb-6 flex-row items-center justify-between">
          <Pressable
            accessibilityRole="button"
            accessibilityLabel="Open settings"
            onPress={() => router.push('/modal')}
            hitSlop={12}
          >
            <FontAwesome name="cog" size={20} color={colors.primary} />
          </Pressable>
          <Text
            testID="home-title"
            className="text-lg font-semibold text-mb-text-light dark:text-mb-text-dark"
          >
            MB Converter
          </Text>
          <Pressable
            accessibilityRole="button"
            accessibilityLabel="Conversion history"
            onPress={() => router.push('/history')}
            hitSlop={12}
          >
            <FontAwesome name="history" size={20} color={colors.primary} />
          </Pressable>
        </View>

        <View className="mb-8 items-center gap-3">
          <View className="h-[72px] w-[72px] items-center justify-center rounded-full bg-mb-secondary-light/45 dark:bg-mb-secondary-dark/60">
            <FontAwesome name="exchange" size={28} color={colors.primary} />
          </View>
          <Text className="text-center text-[28px] font-bold text-mb-text-light dark:text-mb-text-dark">
            Convert & Compress
          </Text>
          <Text className="text-center text-sm leading-5 text-mb-textMuted-light dark:text-mb-textMuted-dark">
            Photos, video, audio, and clipboard — all in one flow.
          </Text>
          <View className="mt-1 h-0.5 w-48 rounded-full bg-mb-primary-light/70 dark:bg-mb-primary-dark/70" />
        </View>

        <View className="gap-3.5">
          <View className="flex-row gap-3.5">
            <ImportActionButton
              testID="import-photos"
              title="Photo Album"
              icon="photo"
              accessibilityLabel="Import from Photos"
              disabled={isImporting}
              onPress={() => void onPhotos()}
            />
            <ImportActionButton
              testID="import-files"
              title="Files"
              icon="folder"
              accessibilityLabel="Import from Files"
              disabled={isImporting}
              onPress={() => void onFiles()}
            />
          </View>
          <View className="flex-row gap-3.5">
            <ImportActionButton
              testID="import-link"
              title="From link"
              icon="link"
              accessibilityLabel="Import file from web link"
              disabled={isImporting}
              onPress={() => {
                setLinkText('');
                setLinkModalVisible(true);
              }}
            />
            <ImportActionButton
              testID="import-paste"
              title={pasteLabel ? `Paste\n(${pasteLabel})` : 'Paste from clipboard'}
              icon="clipboard"
              accessibilityLabel={
                pasteLabel ? `Paste ${pasteLabel} from clipboard` : 'Paste from clipboard'
              }
              disabled={isImporting || !pasteLabel}
              onPress={() => void onPaste()}
            />
          </View>
        </View>

        <Pressable
          testID="import-demo-fixture"
          accessibilityRole="button"
          accessibilityLabel="Try sample file"
          disabled={isImporting}
          onPress={() => void onDemoFixture()}
          className="mt-5 items-center py-2"
        >
          <Text className="text-sm font-semibold text-mb-primary-light dark:text-mb-primary-dark">
            Try sample file
          </Text>
        </Pressable>

        {isImporting ? (
          <View
            testID="import-status"
            className="mt-6 rounded-2xl border border-mb-accent-light/35 bg-mb-surface-light p-4 dark:border-mb-accent-dark/55 dark:bg-mb-surface-dark"
          >
            {remoteDownloadProgress ? (
              <>
                <Text className="mb-2 text-base font-semibold text-mb-text-light dark:text-mb-text-dark">
                  Downloading from link
                </Text>
                <View className="h-2 overflow-hidden rounded-full bg-mb-secondary-light/40 dark:bg-mb-secondary-dark/50">
                  <View
                    className="h-full rounded-full bg-mb-primary-light dark:bg-mb-primary-dark"
                    style={{ width: `${Math.round((progressFraction ?? 0) * 100)}%` }}
                  />
                </View>
                <Text className="mt-2 text-xs text-mb-textMuted-light dark:text-mb-textMuted-dark">
                  {remoteDownloadProgress.bytesReceived.toLocaleString()} bytes
                  {remoteDownloadProgress.totalBytes
                    ? ` of ${remoteDownloadProgress.totalBytes.toLocaleString()}`
                    : ' downloaded'}
                </Text>
              </>
            ) : (
              <View className="flex-row items-center gap-3">
                <ActivityIndicator color={colors.primary} />
                <Text className="text-base text-mb-text-light dark:text-mb-text-dark">
                  Importing...
                </Text>
              </View>
            )}
          </View>
        ) : null}
      </View>

      <Modal
        visible={linkModalVisible}
        animationType="fade"
        transparent
        onRequestClose={() => setLinkModalVisible(false)}
      >
        <View className="flex-1 items-center justify-center bg-black/40 px-6">
          <View className="w-full max-w-md rounded-2xl bg-mb-surface-light p-5 dark:bg-mb-surface-dark">
            <Text className="mb-2 text-lg font-semibold text-mb-text-light dark:text-mb-text-dark">
              Import from link
            </Text>
            <Text className="mb-4 text-sm text-mb-textMuted-light dark:text-mb-textMuted-dark">
              The file must be a supported format and 150 MB or smaller. Use a direct link when
              possible.
            </Text>
            <TextInput
              testID="link-url-input"
              value={linkText}
              onChangeText={setLinkText}
              autoCapitalize="none"
              autoCorrect={false}
              keyboardType="url"
              placeholder="https://example.com/clip.mp4"
              placeholderTextColor={colors.textMuted}
              className="mb-4 rounded-xl border border-mb-secondary-light px-3 py-3 text-base text-mb-text-light dark:border-mb-secondary-dark dark:text-mb-text-dark"
            />
            <View className="flex-row justify-end gap-4">
              <Pressable
                accessibilityRole="button"
                onPress={() => {
                  setLinkModalVisible(false);
                  setLinkText('');
                }}
              >
                <Text className="text-base font-semibold text-mb-textMuted-light dark:text-mb-textMuted-dark">
                  Cancel
                </Text>
              </Pressable>
              <Pressable
                testID="link-download"
                accessibilityRole="button"
                onPress={() => void onDownloadLink()}
              >
                <Text className="text-base font-semibold text-mb-primary-light dark:text-mb-primary-dark">
                  Download
                </Text>
              </Pressable>
            </View>
          </View>
        </View>
      </Modal>
    </View>
  );
}
