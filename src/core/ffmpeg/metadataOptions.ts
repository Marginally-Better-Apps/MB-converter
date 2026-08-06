import type { MetadataExportPolicy } from '@/src/core/models/types';
import { quoteFFmpegPath } from '@/src/core/ffmpeg/quote';

/** Mirror of FFmpegMetadataOptions.outputFlags. */
export function metadataOutputFlags(policy: MetadataExportPolicy): string {
  if (policy.stripAll) {
    return stripPrefix(policy) + ' -map_metadata -1 -map_chapters -1';
  }

  let parts = stripPrefix(policy);
  parts += ' -map_metadata -1 -map_chapters -1';

  for (const key of Object.keys(policy.retainedFormatTags).sort()) {
    parts += ` -metadata ${key}=${quoteFFmpegPath(policy.retainedFormatTags[key]!)}`;
  }

  const streamIndices = Object.keys(policy.retainedStreamTags)
    .map(Number)
    .sort((a, b) => a - b);
  for (const streamIndex of streamIndices) {
    const dict = policy.retainedStreamTags[streamIndex] ?? {};
    for (const key of Object.keys(dict).sort()) {
      parts += ` -metadata:s:${streamIndex}:${key}=${quoteFFmpegPath(dict[key]!)}`;
    }
  }

  return parts;
}

function stripPrefix(policy: MetadataExportPolicy): string {
  let parts = '';
  for (const idx of [...policy.sourceStreamIndicesForTagStrip].sort((a, b) => a - b)) {
    parts += ` -map_metadata:s:${idx} -1`;
  }
  return parts;
}
