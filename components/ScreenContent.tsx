import type { ReactNode } from 'react';
import { useWindowDimensions, View, type ViewProps } from 'react-native';

import { contentMaxWidth } from '@/src/core/layout/contentWidth';

type ScreenContentProps = ViewProps & {
  children: ReactNode;
  /** Extra NativeWind / className on the outer column. */
  className?: string;
};

/**
 * Centers content with a phone-friendly max width that widens on iPad.
 */
export function ScreenContent({ children, className, style, ...rest }: ScreenContentProps) {
  const { width } = useWindowDimensions();
  const maxWidth = contentMaxWidth(width);

  return (
    <View
      className={`mx-auto w-full px-6 ${className ?? ''}`}
      style={[{ maxWidth }, style]}
      {...rest}
    >
      {children}
    </View>
  );
}
