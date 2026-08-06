import { Text, View } from 'react-native';

export default function HomeScreen() {
  return (
    <View
      testID="home-screen"
      className="flex-1 items-center justify-center bg-mb-background-light dark:bg-mb-background-dark px-6"
    >
      <Text
        testID="home-title"
        className="text-3xl font-bold text-mb-text-light dark:text-mb-text-dark"
      >
        MB Converter
      </Text>
      <Text className="mt-3 text-center text-base text-mb-textMuted-light dark:text-mb-textMuted-dark">
        Convert and compress photos, video, and audio on iPhone and iPad.
      </Text>
    </View>
  );
}
