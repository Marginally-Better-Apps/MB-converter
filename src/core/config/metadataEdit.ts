import type { MetadataExportPolicy } from '@/src/core/models/types';

export type EditableMetadataTag = {
  id: string;
  key: string;
  value: string;
  kind: 'format' | 'stream';
  streamIndex?: number;
  isRemoved: boolean;
};

/** Practical default rows for a lightweight metadata editor. */
export function defaultEditableTags(): EditableMetadataTag[] {
  return [
    { id: 'format:title', key: 'title', value: '', kind: 'format', isRemoved: false },
    { id: 'format:artist', key: 'artist', value: '', kind: 'format', isRemoved: false },
    { id: 'format:comment', key: 'comment', value: '', kind: 'format', isRemoved: false },
  ];
}

export function makeStripAllPolicy(streamIndices: number[] = []): MetadataExportPolicy {
  return {
    stripAll: true,
    retainedFormatTags: {},
    retainedStreamTags: {},
    sourceStreamIndicesForTagStrip: [...streamIndices].sort((a, b) => a - b),
  };
}

export function makePolicyFromTags(
  tags: EditableMetadataTag[],
  stripAll: boolean
): MetadataExportPolicy {
  const streamIndices = [
    ...new Set(
      tags
        .filter((t) => t.kind === 'stream' && typeof t.streamIndex === 'number')
        .map((t) => t.streamIndex as number)
    ),
  ].sort((a, b) => a - b);

  if (stripAll) {
    return makeStripAllPolicy(streamIndices);
  }

  const retainedFormatTags: Record<string, string> = {};
  const retainedStreamTags: Record<number, Record<string, string>> = {};

  for (const tag of tags) {
    if (tag.isRemoved) continue;
    const value = tag.value.trim();
    if (!value) continue;
    if (tag.kind === 'format') {
      retainedFormatTags[tag.key] = value;
    } else if (tag.kind === 'stream' && typeof tag.streamIndex === 'number') {
      const bucket = retainedStreamTags[tag.streamIndex] ?? {};
      bucket[tag.key] = value;
      retainedStreamTags[tag.streamIndex] = bucket;
    }
  }

  return {
    stripAll: false,
    retainedFormatTags,
    retainedStreamTags,
    sourceStreamIndicesForTagStrip: streamIndices,
  };
}

export function applyTagOverride(
  tags: EditableMetadataTag[],
  id: string,
  value: string
): EditableMetadataTag[] {
  return tags.map((tag) => (tag.id === id ? { ...tag, value } : tag));
}

export function markTagRemoved(
  tags: EditableMetadataTag[],
  id: string,
  isRemoved: boolean
): EditableMetadataTag[] {
  return tags.map((tag) => (tag.id === id ? { ...tag, isRemoved } : tag));
}
