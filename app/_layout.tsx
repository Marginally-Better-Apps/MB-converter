import '../global.css';

import { useFonts } from 'expo-font';
import { DarkTheme, DefaultTheme, Stack, ThemeProvider } from 'expo-router';
import * as SplashScreen from 'expo-splash-screen';
import { useEffect } from 'react';
import 'react-native-reanimated';

import { theme } from '@/constants/theme';
import { useColorScheme } from '@/components/useColorScheme';
import { ImportProvider } from '@/src/features/home/ImportContext';

export {
  // Catch any errors thrown by the Layout component.
  ErrorBoundary,
} from 'expo-router';

export const unstable_settings = {
  // Ensure that reloading on `/modal` keeps a back button present.
  initialRouteName: '(tabs)',
};

const lightNavigationTheme = {
  ...DefaultTheme,
  colors: {
    ...DefaultTheme.colors,
    primary: theme.light.primary,
    background: theme.light.background,
    card: theme.light.surface,
    text: theme.light.text,
    border: theme.light.secondary,
    notification: theme.light.accent,
  },
};

const darkNavigationTheme = {
  ...DarkTheme,
  colors: {
    ...DarkTheme.colors,
    primary: theme.dark.primary,
    background: theme.dark.background,
    card: theme.dark.surface,
    text: theme.dark.text,
    border: theme.dark.secondary,
    notification: theme.dark.primary,
  },
};

// Prevent the splash screen from auto-hiding before asset loading is complete.
SplashScreen.preventAutoHideAsync();

export default function RootLayout() {
  const [loaded, error] = useFonts({
    SpaceMono: require('../assets/fonts/SpaceMono-Regular.ttf'),
  });

  // Expo Router uses Error Boundaries to catch errors in the navigation tree.
  useEffect(() => {
    if (error) throw error;
  }, [error]);

  useEffect(() => {
    if (loaded) {
      SplashScreen.hideAsync();
    }
  }, [loaded]);

  if (!loaded) {
    return null;
  }

  return <RootLayoutNav />;
}

function RootLayoutNav() {
  const colorScheme = useColorScheme();

  return (
    <ThemeProvider value={colorScheme === 'dark' ? darkNavigationTheme : lightNavigationTheme}>
      <ImportProvider>
        <Stack>
          <Stack.Screen name="(tabs)" options={{ headerShown: false }} />
          <Stack.Screen name="import-detail" options={{ title: 'Import', presentation: 'card' }} />
          <Stack.Screen name="history" options={{ title: 'History', presentation: 'card' }} />
          <Stack.Screen name="modal" options={{ title: 'Settings', presentation: 'modal' }} />
        </Stack>
      </ImportProvider>
    </ThemeProvider>
  );
}
