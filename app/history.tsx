import { Text, View } from 'react-native';

/** Stub for Epic 4 conversion history. */
export default function HistoryScreen() {
  return (
    <View
      testID="history-screen"
      className="flex-1 items-center justify-center bg-mb-background-light px-6 dark:bg-mb-background-dark"
    >
      <Text className="text-xl font-semibold text-mb-text-light dark:text-mb-text-dark">
        History
      </Text>
      <Text className="mt-2 text-center text-sm text-mb-textMuted-light dark:text-mb-textMuted-dark">
        Conversion history will land in Epic 4.
      </Text>
    </View>
  );
}
