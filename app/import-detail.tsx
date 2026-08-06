import { router, useLocalSearchParams } from 'expo-router';
import { useEffect, useMemo } from 'react';
import { Pressable, ScrollView, Text, View } from 'react-native';

import { allowedOutputs, defaultOutput } from '@/src/core/compatibility/FormatMatrix';
import { displayName } from '@/src/core/ffmpeg/outputFormatArgs';
import type { MediaCategory } from '@/src/core/models/types';
import { useConversion } from '@/src/features/conversion/ConversionContext';

function isMediaCategory(value: string | undefined): value is MediaCategory {
  return (
    value === 'video' || value === 'audio' || value === 'image' || value === 'animatedImage'
  );
}

function categoryLabel(category: MediaCategory): string {
  switch (category) {
    case 'video':
      return 'Video';
    case 'audio':
      return 'Audio';
    case 'image':
      return 'Image';
    case 'animatedImage':
      return 'Animated image';
  }
}

/**
 * Import confirmation: shows detected category + allowed outputs, then continues to config.
 */
export default function ImportDetailScreen() {
  const params = useLocalSearchParams<{
    uri?: string;
    filename?: string;
    category?: string;
    byteSize?: string;
    duration?: string;
  }>();
  const { setSessionInput, setConfig } = useConversion();

  const filename = params.filename ?? 'Unknown file';
  const category = isMediaCategory(params.category) ? params.category : null;
  const byteSize = params.byteSize ? Number(params.byteSize) : null;
  const uri = params.uri ?? '';
  const duration = params.duration ? Number(params.duration) : undefined;

  const outputs = useMemo(
    () => (category ? allowedOutputs(category) : []),
    [category]
  );

  useEffect(() => {
    if (!category || !uri) return;
    setSessionInput({
      uri,
      filename,
      category,
      byteSize: byteSize != null && Number.isFinite(byteSize) ? byteSize : 0,
      duration: duration != null && Number.isFinite(duration) ? duration : undefined,
    });
    setConfig({
      outputFormat: defaultOutput(category),
      targetSizeBytes:
        byteSize != null && Number.isFinite(byteSize) ? Math.max(1, Math.floor(byteSize * 0.5)) : undefined,
      usesSinglePassVideoTargetEncode: true,
    });
  }, [byteSize, category, duration, filename, setConfig, setSessionInput, uri]);

  const onContinue = () => {
    if (!category || !uri) return;
    router.push('/convert/config');
  };

  return (
    <ScrollView
      testID="import-detail-screen"
      className="flex-1 bg-mb-background-light dark:bg-mb-background-dark"
      contentContainerClassName="px-6 pb-10 pt-6"
    >
      <Text className="mb-2 text-2xl font-bold text-mb-text-light dark:text-mb-text-dark">
        Ready to convert
      </Text>
      <Text className="mb-6 text-sm text-mb-textMuted-light dark:text-mb-textMuted-dark">
        Review the detected format, then choose an output format and quality.
      </Text>

      <View className="mb-6 rounded-2xl border border-mb-accent-light/30 bg-mb-surface-light p-4 dark:border-mb-accent-dark/50 dark:bg-mb-surface-dark">
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
          Detected: {category ? categoryLabel(category) : 'Unknown'}
        </Text>
        {byteSize != null && Number.isFinite(byteSize) ? (
          <Text
            testID="import-detail-size"
            className="mt-1 text-sm text-mb-textMuted-light dark:text-mb-textMuted-dark"
          >
            Size: {(byteSize / (1024 * 1024)).toFixed(2)} MB
          </Text>
        ) : null}
      </View>

      <Text className="mb-2 text-sm font-semibold uppercase tracking-wide text-mb-textMuted-light dark:text-mb-textMuted-dark">
        Allowed outputs
      </Text>
      <View testID="import-detail-outputs" className="mb-8 flex-row flex-wrap gap-2">
        {outputs.map((format) => (
          <View
            key={format}
            className="rounded-full bg-mb-secondary-light/40 px-3 py-1.5 dark:bg-mb-secondary-dark/50"
          >
            <Text className="text-sm text-mb-text-light dark:text-mb-text-dark">
              {displayName(format)}
            </Text>
          </View>
        ))}
        {outputs.length === 0 ? (
          <Text className="text-sm text-mb-textMuted-light dark:text-mb-textMuted-dark">
            No outputs available for this file type.
          </Text>
        ) : null}
      </View>

      <Pressable
        testID="import-detail-continue"
        accessibilityRole="button"
        accessibilityLabel="Continue to conversion settings"
        disabled={!category || !uri}
        className="items-center rounded-2xl bg-mb-primary-light px-4 py-3.5 dark:bg-mb-primary-dark"
        onPress={onContinue}
      >
        <Text className="text-base font-semibold text-mb-background-light dark:text-mb-background-dark">
          Continue
        </Text>
      </Pressable>
    </ScrollView>
  );
}
