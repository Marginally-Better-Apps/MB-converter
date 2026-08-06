import { StatusBar } from 'expo-status-bar';
import { Linking, Platform, Pressable, Text, View } from 'react-native';

/** Lightweight settings stub (full settings land in Epic 4). */
export default function ModalScreen() {
  return (
    <View
      testID="settings-screen"
      className="flex-1 bg-mb-background-light px-6 pt-8 dark:bg-mb-background-dark"
    >
      <Text className="mb-2 text-2xl font-bold text-mb-text-light dark:text-mb-text-dark">
        Settings
      </Text>
      <Text className="mb-6 text-sm text-mb-textMuted-light dark:text-mb-textMuted-dark">
        Theme and history preferences arrive in Epic 4.
      </Text>

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
          accessibilityRole="link"
          onPress={() => {
            void Linking.openURL('https://github.com/Marginally-Better-Apps/MB-converter');
          }}
        >
          <Text className="font-semibold text-mb-primary-light dark:text-mb-primary-dark">
            GitHub
          </Text>
        </Pressable>
      </View>

      <StatusBar style={Platform.OS === 'ios' ? 'light' : 'auto'} />
    </View>
  );
}
