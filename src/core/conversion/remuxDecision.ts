import { canRemuxStandaloneAudioCodec, categoryOf } from '@/src/core/ffmpeg/outputFormatArgs';
import { shouldRemuxVideo } from '@/src/core/ffmpeg/videoCommandBuilder';
import type { ConversionConfig, MediaFile } from '@/src/core/models/types';

export { shouldRemuxVideo };

/** Mirrors AudioConverter.shouldRemux — remux when preferred and codecs/container allow stream copy. */
export function shouldRemuxAudio(input: MediaFile, config: ConversionConfig): boolean {
  if (!config.prefersRemuxWhenPossible) return false;
  if (categoryOf(config.outputFormat) !== 'audio') return false;
  return canRemuxStandaloneAudioCodec(
    config.outputFormat,
    input.audioCodec,
    input.containerFormat
  );
}
