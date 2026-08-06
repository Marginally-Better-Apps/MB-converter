import { router } from 'expo-router';
import { useEffect, useMemo, useState } from 'react';
import { Pressable, ScrollView, Switch, Text, TextInput, View } from 'react-native';

import { allowedOutputs } from '@/src/core/compatibility/FormatMatrix';
import {
  applyTagOverride,
  defaultEditableTags,
  makePolicyFromTags,
  markTagRemoved,
  type EditableMetadataTag,
} from '@/src/core/config/metadataEdit';
import {
  defaultConversionConfig,
  fpsOptions,
  remuxHintLabel,
  resolutionOptions,
  shouldShowFps,
  shouldShowResolution,
  supportsTargetSize,
  targetSizeBytesFromFraction,
  validateFps,
  validateResolution,
  validateTargetSizeBytes,
} from '@/src/core/config/outputConfig';
import { shouldRemuxAudio, shouldRemuxVideo } from '@/src/core/conversion/remuxDecision';
import { categoryOf, displayName } from '@/src/core/ffmpeg/outputFormatArgs';
import type { ConversionConfig, OutputFormat, Size } from '@/src/core/models/types';
import { useConversion } from '@/src/features/conversion/ConversionContext';

function formatBytes(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(2)} MB`;
}

const TARGET_PRESETS = [
  { label: 'Smaller', fraction: 0.25 },
  { label: 'Medium', fraction: 0.5 },
  { label: 'Larger', fraction: 0.75 },
  { label: 'Max / remux', fraction: 1 },
] as const;

export default function ConvertConfigScreen() {
  const { input, mediaFile, config, setConfig } = useConversion();
  const [selected, setSelected] = useState<OutputFormat | null>(config?.outputFormat ?? null);
  const [resolutionId, setResolutionId] = useState('original');
  const [customWidth, setCustomWidth] = useState('');
  const [customHeight, setCustomHeight] = useState('');
  const [selectedFps, setSelectedFps] = useState<number | undefined>(config?.targetFPS);
  const [stripAllMetadata, setStripAllMetadata] = useState(config?.metadata?.stripAll ?? true);
  const [metadataTags, setMetadataTags] = useState<EditableMetadataTag[]>(() => defaultEditableTags());
  const [validationMessage, setValidationMessage] = useState<string | null>(null);

  const outputs = useMemo(
    () => (input ? allowedOutputs(input.category) : []),
    [input]
  );

  const activeFormat = selected ?? config?.outputFormat ?? outputs[0] ?? null;

  useEffect(() => {
    if (!mediaFile?.dimensions) return;
    setCustomWidth(String(Math.round(mediaFile.dimensions.width)));
    setCustomHeight(String(Math.round(mediaFile.dimensions.height)));
  }, [mediaFile?.dimensions?.height, mediaFile?.dimensions?.width]);

  const resOptions = useMemo(
    () => (mediaFile ? resolutionOptions(mediaFile.dimensions) : []),
    [mediaFile]
  );
  const fpsOpts = useMemo(() => (mediaFile ? fpsOptions(mediaFile.fps) : []), [mediaFile]);

  const showResolution = mediaFile && activeFormat ? shouldShowResolution(mediaFile, activeFormat) : false;
  const showFps = mediaFile && activeFormat ? shouldShowFps(mediaFile, activeFormat) : false;
  const showTargetSize = activeFormat != null && supportsTargetSize(activeFormat);

  const targetBytes = config?.targetSizeBytes ?? input?.byteSize ?? 0;

  const resolvedDimensions: Size | undefined = useMemo(() => {
    if (!showResolution || !mediaFile?.dimensions) return undefined;
    if (resolutionId === 'original') return undefined;
    if (resolutionId === 'custom') {
      const width = Number(customWidth);
      const height = Number(customHeight);
      if (!(width > 0) || !(height > 0)) return undefined;
      return { width, height };
    }
    return resOptions.find((o) => o.id === resolutionId)?.dimensions;
  }, [customHeight, customWidth, mediaFile?.dimensions, resOptions, resolutionId, showResolution]);

  const draftConfig: ConversionConfig | null = useMemo(() => {
    if (!activeFormat) return null;
    const base = config ?? (mediaFile ? defaultConversionConfig(mediaFile, activeFormat) : { outputFormat: activeFormat });
    return {
      ...base,
      outputFormat: activeFormat,
      targetDimensions: resolvedDimensions,
      targetFPS: showFps ? selectedFps : undefined,
      metadata: makePolicyFromTags(metadataTags, stripAllMetadata),
      usesSinglePassVideoTargetEncode: categoryOf(activeFormat) === 'video',
    };
  }, [
    activeFormat,
    config,
    mediaFile,
    metadataTags,
    resolvedDimensions,
    selectedFps,
    showFps,
    stripAllMetadata,
  ]);

  const remuxHint = useMemo(() => {
    if (!mediaFile || !draftConfig) return null;
    const prefers = draftConfig.prefersRemuxWhenPossible === true;
    const can =
      categoryOf(draftConfig.outputFormat) === 'video'
        ? shouldRemuxVideo(mediaFile, draftConfig)
        : shouldRemuxAudio(mediaFile, draftConfig);
    return remuxHintLabel(prefers, can);
  }, [draftConfig, mediaFile]);

  const applyFormat = (format: OutputFormat) => {
    if (!mediaFile) return;
    setSelected(format);
    setResolutionId('original');
    setSelectedFps(undefined);
    setValidationMessage(null);
    setConfig(defaultConversionConfig(mediaFile, format));
  };

  const applyTargetFraction = (fraction: number) => {
    if (!input || !activeFormat || !mediaFile) return;
    const bytes = targetSizeBytesFromFraction(input.byteSize, fraction);
    setConfig({
      ...(draftConfig ?? defaultConversionConfig(mediaFile, activeFormat)),
      outputFormat: activeFormat,
      targetSizeBytes: bytes,
      videoQuality: fraction,
      imageQuality: fraction,
      prefersRemuxWhenPossible: fraction >= 0.98,
      targetDimensions: resolvedDimensions,
      targetFPS: selectedFps,
      metadata: makePolicyFromTags(metadataTags, stripAllMetadata),
      usesSinglePassVideoTargetEncode: true,
    });
  };

  const onConvert = () => {
    if (!activeFormat || !mediaFile || !input || !draftConfig) return;

    if (showResolution && resolvedDimensions) {
      const check = validateResolution(resolvedDimensions, mediaFile.dimensions!);
      if (!check.ok) {
        setValidationMessage(check.message);
        return;
      }
    }
    if (showFps && selectedFps != null && mediaFile.fps != null) {
      const check = validateFps(selectedFps, mediaFile.fps);
      if (!check.ok) {
        setValidationMessage(check.message);
        return;
      }
    }
    if (showTargetSize) {
      const check = validateTargetSizeBytes(draftConfig.targetSizeBytes, input.byteSize);
      if (!check.ok) {
        setValidationMessage(check.message);
        return;
      }
    }

    setValidationMessage(null);
    setConfig(draftConfig);
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
      <View testID="convert-config-formats" className="mb-6 gap-2">
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

      {showResolution ? (
        <View testID="convert-config-resolution" className="mb-6">
          <Text className="mb-3 text-sm font-semibold uppercase tracking-wide text-mb-textMuted-light dark:text-mb-textMuted-dark">
            Resolution
          </Text>
          <View className="mb-3 flex-row flex-wrap gap-2">
            {resOptions.map((option) => {
              const active = option.id === resolutionId;
              return (
                <Pressable
                  key={option.id}
                  testID={`convert-resolution-${option.id}`}
                  onPress={() => setResolutionId(option.id)}
                  className={`rounded-full px-3 py-2 ${
                    active
                      ? 'bg-mb-primary-light dark:bg-mb-primary-dark'
                      : 'bg-mb-secondary-light/50 dark:bg-mb-secondary-dark/50'
                  }`}
                >
                  <Text
                    className={`text-sm ${
                      active
                        ? 'font-semibold text-mb-background-light dark:text-mb-background-dark'
                        : 'text-mb-text-light dark:text-mb-text-dark'
                    }`}
                  >
                    {option.label}
                  </Text>
                </Pressable>
              );
            })}
          </View>
          {resolutionId === 'custom' ? (
            <View className="flex-row items-center gap-2">
              <TextInput
                testID="convert-resolution-width"
                keyboardType="number-pad"
                value={customWidth}
                onChangeText={(text) => {
                  setCustomWidth(text);
                  const width = Number(text);
                  if (mediaFile?.dimensions && width > 0) {
                    const ratio = mediaFile.dimensions.height / mediaFile.dimensions.width;
                    setCustomHeight(String(Math.max(1, Math.round(width * ratio))));
                  }
                }}
                className="flex-1 rounded-xl border border-mb-accent-light/30 bg-mb-surface-light px-3 py-2 text-mb-text-light dark:border-mb-accent-dark/50 dark:bg-mb-surface-dark dark:text-mb-text-dark"
              />
              <Text className="text-mb-textMuted-light dark:text-mb-textMuted-dark">×</Text>
              <TextInput
                testID="convert-resolution-height"
                keyboardType="number-pad"
                value={customHeight}
                onChangeText={(text) => {
                  setCustomHeight(text);
                  const height = Number(text);
                  if (mediaFile?.dimensions && height > 0) {
                    const ratio = mediaFile.dimensions.width / mediaFile.dimensions.height;
                    setCustomWidth(String(Math.max(1, Math.round(height * ratio))));
                  }
                }}
                className="flex-1 rounded-xl border border-mb-accent-light/30 bg-mb-surface-light px-3 py-2 text-mb-text-light dark:border-mb-accent-dark/50 dark:bg-mb-surface-dark dark:text-mb-text-dark"
              />
            </View>
          ) : null}
        </View>
      ) : null}

      {showFps ? (
        <View testID="convert-config-fps" className="mb-6">
          <Text className="mb-3 text-sm font-semibold uppercase tracking-wide text-mb-textMuted-light dark:text-mb-textMuted-dark">
            FPS
          </Text>
          <View className="flex-row flex-wrap gap-2">
            {fpsOpts.map((option) => {
              const active = selectedFps === option.value;
              return (
                <Pressable
                  key={option.id}
                  testID={`convert-fps-${option.id}`}
                  onPress={() => setSelectedFps(option.value)}
                  className={`rounded-full px-3 py-2 ${
                    active
                      ? 'bg-mb-primary-light dark:bg-mb-primary-dark'
                      : 'bg-mb-secondary-light/50 dark:bg-mb-secondary-dark/50'
                  }`}
                >
                  <Text
                    className={`text-sm ${
                      active
                        ? 'font-semibold text-mb-background-light dark:text-mb-background-dark'
                        : 'text-mb-text-light dark:text-mb-text-dark'
                    }`}
                  >
                    {option.label}
                  </Text>
                </Pressable>
              );
            })}
          </View>
        </View>
      ) : null}

      {showTargetSize ? (
        <View className="mb-6">
          <Text className="mb-2 text-sm font-semibold uppercase tracking-wide text-mb-textMuted-light dark:text-mb-textMuted-dark">
            Target size
          </Text>
          <Text
            testID="convert-config-target-size"
            className="mb-3 text-sm text-mb-text-light dark:text-mb-text-dark"
          >
            {formatBytes(targetBytes)}
          </Text>
          <View className="mb-2 flex-row flex-wrap gap-2">
            {TARGET_PRESETS.map((preset) => (
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
          {remuxHint ? (
            <Text
              testID="convert-config-remux-hint"
              className="text-sm text-mb-textMuted-light dark:text-mb-textMuted-dark"
            >
              {remuxHint}
            </Text>
          ) : null}
        </View>
      ) : (
        <Text className="mb-6 text-sm text-mb-textMuted-light dark:text-mb-textMuted-dark">
          This format is lossless — output size depends on dimensions.
        </Text>
      )}

      <View
        testID="convert-config-metadata"
        className="mb-6 rounded-2xl border border-mb-accent-light/30 bg-mb-surface-light p-4 dark:border-mb-accent-dark/50 dark:bg-mb-surface-dark"
      >
        <View className="mb-3 flex-row items-center justify-between">
          <Text className="text-base font-semibold text-mb-text-light dark:text-mb-text-dark">
            Metadata
          </Text>
          <View className="flex-row items-center gap-2">
            <Text className="text-sm text-mb-textMuted-light dark:text-mb-textMuted-dark">
              Remove all
            </Text>
            <Switch
              testID="convert-metadata-strip-all"
              value={stripAllMetadata}
              onValueChange={setStripAllMetadata}
            />
          </View>
        </View>

        {!stripAllMetadata ? (
          <View className="gap-3">
            {metadataTags.map((tag) => (
              <View key={tag.id} className="gap-1">
                <View className="flex-row items-center justify-between">
                  <Text className="text-sm font-medium capitalize text-mb-text-light dark:text-mb-text-dark">
                    {tag.key}
                  </Text>
                  <Pressable
                    testID={`convert-metadata-remove-${tag.key}`}
                    onPress={() => setMetadataTags((prev) => markTagRemoved(prev, tag.id, !tag.isRemoved))}
                  >
                    <Text className="text-xs text-mb-primary-light dark:text-mb-primary-dark">
                      {tag.isRemoved ? 'Keep' : 'Strip'}
                    </Text>
                  </Pressable>
                </View>
                <TextInput
                  testID={`convert-metadata-${tag.key}`}
                  editable={!tag.isRemoved}
                  value={tag.value}
                  onChangeText={(text) =>
                    setMetadataTags((prev) => applyTagOverride(prev, tag.id, text))
                  }
                  placeholder={`Optional ${tag.key}`}
                  placeholderTextColor="#9aa9b8"
                  className={`rounded-xl border px-3 py-2 text-mb-text-light dark:text-mb-text-dark ${
                    tag.isRemoved
                      ? 'border-mb-accent-light/15 bg-mb-background-light/50 opacity-50 dark:border-mb-accent-dark/30 dark:bg-mb-background-dark/50'
                      : 'border-mb-accent-light/30 bg-mb-background-light dark:border-mb-accent-dark/50 dark:bg-mb-background-dark'
                  }`}
                />
              </View>
            ))}
          </View>
        ) : (
          <Text className="text-sm text-mb-textMuted-light dark:text-mb-textMuted-dark">
            EXIF and container tags will be stripped from the output.
          </Text>
        )}
      </View>

      {validationMessage ? (
        <Text
          testID="convert-config-validation"
          className="mb-4 text-sm text-red-600 dark:text-red-400"
        >
          {validationMessage}
        </Text>
      ) : null}

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
