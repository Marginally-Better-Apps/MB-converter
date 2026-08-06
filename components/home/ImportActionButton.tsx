import FontAwesome from '@expo/vector-icons/FontAwesome';
import type { ComponentProps } from 'react';
import { Pressable, Text, View } from 'react-native';

import Colors from '@/constants/Colors';
import { useColorScheme } from '@/components/useColorScheme';

type Props = {
  title: string;
  icon: ComponentProps<typeof FontAwesome>['name'];
  onPress: () => void;
  disabled?: boolean;
  accessibilityLabel: string;
  testID?: string;
};

export function ImportActionButton({
  title,
  icon,
  onPress,
  disabled,
  accessibilityLabel,
  testID,
}: Props) {
  const scheme = useColorScheme() ?? 'light';
  const tint = Colors[scheme].primary;

  return (
    <Pressable
      testID={testID}
      accessibilityRole="button"
      accessibilityLabel={accessibilityLabel}
      disabled={disabled}
      onPress={onPress}
      className={`min-h-[88px] flex-1 items-center justify-center rounded-2xl border border-mb-accent-light/30 bg-mb-secondary-light/30 px-3 py-3 dark:border-mb-accent-dark/55 dark:bg-mb-secondary-dark/35 ${
        disabled ? 'opacity-45' : 'opacity-100'
      }`}
    >
      <View className="items-center gap-2.5">
        <FontAwesome name={icon} size={22} color={tint} />
        <Text className="text-center text-base font-semibold text-mb-primary-light dark:text-mb-primary-dark">
          {title}
        </Text>
      </View>
    </Pressable>
  );
}
