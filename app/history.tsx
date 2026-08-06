import { Text, Pressable, ScrollView, View } from 'react-native';

import { displayName } from '@/src/core/ffmpeg/outputFormatArgs';
import { useHistory } from '@/src/features/history/HistoryContext';

function formatBytes(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(2)} MB`;
}

function formatDate(iso: string): string {
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) return iso;
  return date.toLocaleString();
}

export default function HistoryScreen() {
  const {
    entries,
    totalStorageBytes,
    storageSummaryTitle,
    storageSummaryDescription,
    removeEntry,
    clear,
  } = useHistory();

  return (
    <ScrollView
      testID="history-screen"
      className="flex-1 bg-mb-background-light dark:bg-mb-background-dark"
      contentContainerClassName="px-6 pb-10 pt-6"
    >
      <Text className="mb-1 text-2xl font-bold text-mb-text-light dark:text-mb-text-dark">
        History
      </Text>
      <Text
        testID="history-summary-title"
        className="mb-1 text-sm font-semibold text-mb-text-light dark:text-mb-text-dark"
      >
        {storageSummaryTitle}
      </Text>
      <Text
        testID="history-summary-description"
        className="mb-4 text-sm text-mb-textMuted-light dark:text-mb-textMuted-dark"
      >
        {storageSummaryDescription}
      </Text>

      <View className="mb-6 flex-row items-center justify-between rounded-2xl border border-mb-accent-light/30 bg-mb-surface-light p-4 dark:border-mb-accent-dark/50 dark:bg-mb-surface-dark">
        <View>
          <Text className="text-xs font-semibold uppercase text-mb-textMuted-light dark:text-mb-textMuted-dark">
            Storage used
          </Text>
          <Text
            testID="history-storage-bytes"
            className="mt-1 text-lg font-bold text-mb-primary-light dark:text-mb-primary-dark"
          >
            {formatBytes(totalStorageBytes)}
          </Text>
        </View>
        {entries.length > 0 ? (
          <Pressable
            testID="history-clear-all"
            accessibilityRole="button"
            accessibilityLabel="Clear all history"
            onPress={() => void clear()}
            className="rounded-full bg-red-500/15 px-3 py-2"
          >
            <Text className="text-sm font-semibold text-red-600 dark:text-red-400">Clear all</Text>
          </Pressable>
        ) : null}
      </View>

      {entries.length === 0 ? (
        <View
          testID="history-empty"
          className="items-center rounded-2xl border border-dashed border-mb-accent-light/40 px-4 py-10 dark:border-mb-accent-dark/50"
        >
          <Text className="text-base font-semibold text-mb-text-light dark:text-mb-text-dark">
            No conversions yet
          </Text>
          <Text className="mt-2 text-center text-sm text-mb-textMuted-light dark:text-mb-textMuted-dark">
            Successful conversions will show up here.
          </Text>
        </View>
      ) : (
        <View testID="history-list" className="gap-3">
          {entries.map((entry) => (
            <View
              key={entry.id}
              testID={`history-entry-${entry.id}`}
              className="rounded-2xl border border-mb-accent-light/30 bg-mb-surface-light p-4 dark:border-mb-accent-dark/50 dark:bg-mb-surface-dark"
            >
              <View className="flex-row items-start justify-between gap-3">
                <View className="flex-1">
                  <Text
                    testID={`history-entry-filename-${entry.id}`}
                    className="text-base font-semibold text-mb-text-light dark:text-mb-text-dark"
                  >
                    {entry.inputFilename}
                  </Text>
                  <Text className="mt-1 text-sm text-mb-textMuted-light dark:text-mb-textMuted-dark">
                    {displayName(entry.outputFormat)} · {formatBytes(entry.sizeOnDisk)}
                  </Text>
                  <Text className="mt-1 text-xs text-mb-textMuted-light dark:text-mb-textMuted-dark">
                    {formatDate(entry.createdAt)}
                  </Text>
                </View>
                <Pressable
                  testID={`history-delete-${entry.id}`}
                  accessibilityRole="button"
                  accessibilityLabel="Remove from history"
                  onPress={() => void removeEntry(entry.id)}
                  className="rounded-full px-3 py-2"
                >
                  <Text className="text-sm font-semibold text-mb-textMuted-light dark:text-mb-textMuted-dark">
                    Delete
                  </Text>
                </Pressable>
              </View>
            </View>
          ))}
        </View>
      )}
    </ScrollView>
  );
}
