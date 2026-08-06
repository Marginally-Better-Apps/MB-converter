import { router } from 'expo-router';
import { useMemo, useState } from 'react';
import { Pressable, ScrollView, Text, View } from 'react-native';

import { allowedOutputs } from '@/src/core/compatibility/FormatMatrix';
import { categoryOf, displayName } from '@/src/core/ffmpeg/outputFormatArgs';
import type { OutputFormat } from '@/src/core/models/types';
import { useConversion } from '@/src/features/conversion/ConversionContext';

function formatBytes(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(2)} MB`;
}

/**
 * Minimal output config: format picker + target-size presets (Epic 4 will deepen this).
 */
export default function ConvertConfigScreen() {
  const { input, config, setConfig } = useConversion();
  const [selected, setSelected] = useState<OutputFormat | null>(config?.outputFormat ?? null);

  const outputs = useMemo(
    () => (input ? allowedOutputs(input.category) : []),
    [input]
  );

  const activeFormat = selected ?? config?.outputFormat ?? outputs[0] ?? null;
  const targetBytes = config?.targetSizeBytes ?? input?.byteSize ?? 0;
  const showTargetSize =
    activeFormat != null &&
    (categoryOf(activeFormat) === 'video' ||
      categoryOf(activeFormat) === 'audio' ||
      activeFormat === 'jpg' ||
      activeFormat === 'heic' ||
      activeFormat === 'webpImage');

  const applyFormat = (format: OutputFormat) => {
    setSelected(format);
    setConfig({
      ...(config ?? { outputFormat: format }),
      outputFormat: format,
      usesSinglePassVideoTargetEncode: true,
    });
  };

  const applyTargetFraction = (fraction: number) => {
    if (!input || !activeFormat) return;
    const bytes = Math.max(1, Math.floor(input.byteSize * fraction));
    setConfig({
      ...(config ?? { outputFormat: activeFormat }),
      outputFormat: activeFormat,
      targetSizeBytes: bytes,
      videoQuality: fraction,
      imageQuality: fraction,
      prefersRemuxWhenPossible: fraction >= 0.98,
      usesSinglePassVideoTargetEncode: true,
    });
  };

  const onConvert = () => {
    if (!activeFormat) return;
    setConfig({
      ...(config ?? { outputFormat: activeFormat }),
      outputFormat: activeFormat,
      usesSinglePassVideoTargetEncode: true,
    });
    router.push('/convert/processing');
  };

  if (!input) {
    return (
      <View
        testID="convert-config-screen"
        className="flex-1 items-center justify-center bg-mb-background-light px-6 dark:bg-mb-background-dark"
      >
        <Text className="mb-4 text-center text-mb-textMuted-light dark:text-mb-textMuted-dark">
          No media selected. Import a file from Home first.
        </Text>
        <Pressable
          testID="convert-config-go-home"
          onPress={() => router.replace('/')}
          className="rounded-2xl bg-mb-primary-light px-4 py-3 dark:bg-mb-primary-dark"
        >
          <Text className="font-semibold text-mb-background-light dark:text-mb-background-dark">
            Go to Home
          </Text>
        </Pressable>
      </View>
    );
  }

  return (
    <ScrollView
      testID="convert-config-screen"
      className="flex-1 bg-mb-background-light dark:bg-mb-background-dark"
      contentContainerClassName="px-6 pb-10 pt-6"
    >
      <Text className="mb-1 text-2xl font-bold text-mb-text-light dark:text-mb-text-dark">
        Output
      </Text>
      <Text
        testID="convert-config-filename"
        className="mb-6 text-sm text-mb-textMuted-light dark:text-mb-textMuted-dark"
      >
        {input.filename}
      </Text>

      <Text className="mb-3 text-sm font-semibold uppercase tracking-wide text-mb-textMuted-light dark:text-mb-textMuted-dark">
        Format
      </Text>
      <View testID="convert-config-formats" className="mb-8 gap-2">
        {outputs.map((format) => {
          const isActive = format === activeFormat;
          return (
            <Pressable
              key={format}
              testID={`convert-format-${format}`}
              accessibilityRole="button"
              accessibilityState={{ selected: isActive }}
              onPress={() => applyFormat(format)}
              className={`rounded-2xl border px-4 py-3.5 ${
                isActive
                  ? 'border-mb-primary-light bg-mb-primary-light/10 dark:border-mb-primary-dark dark:bg-mb-primary-dark/15'
                  : 'border-mb-accent-light/25 bg-mb-surface-light dark:border-mb-accent-dark/40 dark:bg-mb-surface-dark'
              }`}
            >
              <Text className="text-base font-semibold text-mb-text-light dark:text-mb-text-dark">
                {displayName(format)}
              </Text>
            </Pressable>
          );
        })}
      </View>

      {showTargetSize ? (
        <View className="mb-8">
          <Text className="mb-2 text-sm font-semibold uppercase tracking-wide text-mb-textMuted-light dark:text-mb-textMuted-dark">
            Target size
          </Text>
          <Text
            testID="convert-config-target-size"
            className="mb-3 text-sm text-mb-text-light dark:text-mb-text-dark"
          >
            {formatBytes(targetBytes)}
          </Text>
          <View className="flex-row flex-wrap gap-2">
            {[
              { label: 'Smaller', fraction: 0.25 },
              { label: 'Medium', fraction: 0.5 },
              { label: 'Larger', fraction: 0.75 },
              { label: 'Max / remux', fraction: 1 },
            ].map((preset) => (
              <Pressable
                key={preset.label}
                testID={`convert-target-${preset.label.replace(/\s+/g, '-').toLowerCase()}`}
                onPress={() => applyTargetFraction(preset.fraction)}
                className="rounded-full bg-mb-secondary-light/50 px-3 py-2 dark:bg-mb-secondary-dark/50"
              >
                <Text className="text-sm text-mb-text-light dark:text-mb-text-dark">
                  {preset.label}
                </Text>
              </Pressable>
            ))}
          </View>
        </View>
      ) : (
        <Text className="mb-8 text-sm text-mb-textMuted-light dark:text-mb-textMuted-dark">
          This format is lossless — output size depends on dimensions.
        </Text>
      )}

      <Pressable
        testID="convert-config-start"
        accessibilityRole="button"
        accessibilityLabel="Start conversion"
        disabled={!activeFormat}
        className="items-center rounded-2xl bg-mb-primary-light px-4 py-3.5 dark:bg-mb-primary-dark"
        onPress={onConvert}
      >
        <Text className="text-base font-semibold text-mb-background-light dark:text-mb-background-dark">
          Convert
        </Text>
      </Pressable>
    </ScrollView>
  );
}
