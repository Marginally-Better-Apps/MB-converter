import { router, useLocalSearchParams } from 'expo-router';
import { Pressable, Text, View } from 'react-native';

/**
 * Epic 2 stub: shows a successful import before conversion (Epic 3).
 */
export default function ImportDetailScreen() {
  const params = useLocalSearchParams<{
    uri?: string;
    filename?: string;
    category?: string;
    byteSize?: string;
  }>();

  const filename = params.filename ?? 'Unknown file';
  const category = params.category ?? 'unknown';
  const byteSize = params.byteSize ? Number(params.byteSize) : null;

  return (
    <View
      testID="import-detail-screen"
      className="flex-1 bg-mb-background-light px-6 pt-6 dark:bg-mb-background-dark"
    >
      <Text className="mb-2 text-2xl font-bold text-mb-text-light dark:text-mb-text-dark">
        Ready to convert
      </Text>
      <Text className="mb-6 text-sm text-mb-textMuted-light dark:text-mb-textMuted-dark">
        Conversion settings arrive in Epic 3. For now this confirms the import succeeded.
      </Text>

      <View className="mb-8 rounded-2xl border border-mb-accent-light/30 bg-mb-surface-light p-4 dark:border-mb-accent-dark/50 dark:bg-mb-surface-dark">
        <Text
          testID="import-detail-filename"
          className="text-base font-semibold text-mb-text-light dark:text-mb-text-dark"
        >
          {filename}
        </Text>
        <Text
          testID="import-detail-format"
          className="mt-2 text-sm text-mb-textMuted-light dark:text-mb-textMuted-dark"
        >
          Detected format: {category}
        </Text>
        {byteSize != null && Number.isFinite(byteSize) ? (
          <Text className="mt-1 text-sm text-mb-textMuted-light dark:text-mb-textMuted-dark">
            Size: {(byteSize / (1024 * 1024)).toFixed(2)} MB
          </Text>
        ) : null}
      </View>

      <Pressable
        testID="import-detail-continue"
        accessibilityRole="button"
        accessibilityLabel="Continue"
        className="items-center rounded-2xl bg-mb-primary-light px-4 py-3.5 dark:bg-mb-primary-dark"
        onPress={() => router.back()}
      >
        <Text className="text-base font-semibold text-mb-background-light dark:text-mb-background-dark">
          Continue
        </Text>
      </Pressable>
    </View>
  );
}
