import { ConversionError } from '@/src/core/conversion/ConversionError';
import { allowedOutputs } from '@/src/core/compatibility/FormatMatrix';
import { categoryOf } from '@/src/core/ffmpeg/outputFormatArgs';
import type { MediaCategory, OutputFormat } from '@/src/core/models/types';

/** Engine path selected by ConversionRouter (mirrors Swift Converter types). */
export type ConversionEnginePath = 'video' | 'audio' | 'animated' | 'image';

/**
 * Chooses the conversion engine from media category + output format.
 * Throws ConversionError.unsupportedConversion when the pair is not allowed.
 */
export function conversionEnginePath(
  category: MediaCategory,
  outputFormat: OutputFormat
): ConversionEnginePath {
  if (!allowedOutputs(category).includes(outputFormat)) {
    throw ConversionError.unsupported();
  }

  const outCategory = categoryOf(outputFormat);

  switch (category) {
    case 'video':
      if (outCategory === 'video') return 'video';
      if (outCategory === 'audio') return 'audio';
      break;
    case 'audio':
      if (outCategory === 'audio') return 'audio';
      break;
    case 'image':
      if (outCategory === 'image') return 'image';
      break;
    case 'animatedImage':
      if (outCategory === 'video' || outCategory === 'image') return 'animated';
      break;
  }

  throw ConversionError.unsupported();
}
