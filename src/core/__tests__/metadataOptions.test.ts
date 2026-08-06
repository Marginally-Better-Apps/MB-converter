import { metadataOutputFlags } from '@/src/core/ffmpeg/metadataOptions';
import { quoteFFmpegPath } from '@/src/core/ffmpeg/quote';

describe('metadataOutputFlags', () => {
  it('strips all metadata by default', () => {
    expect(
      metadataOutputFlags({
        stripAll: true,
        retainedFormatTags: {},
        retainedStreamTags: {},
        sourceStreamIndicesForTagStrip: [],
      })
    ).toBe(' -map_metadata -1 -map_chapters -1');
  });

  it('re-applies retained format tags after clearing metadata', () => {
    const flags = metadataOutputFlags({
      stripAll: false,
      retainedFormatTags: { title: 'Hello', artist: "O'Brien" },
      retainedStreamTags: {},
      sourceStreamIndicesForTagStrip: [0],
    });

    expect(flags).toContain(' -map_metadata:s:0 -1');
    expect(flags).toContain(' -map_metadata -1 -map_chapters -1');
    expect(flags).toContain(` -metadata artist=${quoteFFmpegPath("O'Brien")}`);
    expect(flags).toContain(` -metadata title=${quoteFFmpegPath('Hello')}`);
  });
});
