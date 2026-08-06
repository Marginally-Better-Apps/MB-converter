import { Text, View } from 'react-native';

export default function AboutScreen() {
  return (
    <View className="flex-1 items-center justify-center bg-mb-background-light dark:bg-mb-background-dark px-6">
      <Text className="text-2xl font-bold text-mb-text-light dark:text-mb-text-dark">
        About
      </Text>
      <Text className="mt-3 text-center text-base text-mb-textMuted-light dark:text-mb-textMuted-dark">
        Expo / React Native port of MB Converter. Native FFmpeg requires a custom Dev Client — Expo
        Go is not supported for conversion.
      </Text>
    </View>
  );
}
