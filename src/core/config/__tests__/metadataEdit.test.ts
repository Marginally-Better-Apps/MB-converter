import {
  applyTagOverride,
  defaultEditableTags,
  makePolicyFromTags,
  makeStripAllPolicy,
  markTagRemoved,
  type EditableMetadataTag,
} from '@/src/core/config/metadataEdit';

describe('metadataEdit helpers', () => {
  it('builds strip-all policy with stream indices', () => {
    expect(makeStripAllPolicy([1, 0])).toEqual({
      stripAll: true,
      retainedFormatTags: {},
      retainedStreamTags: {},
      sourceStreamIndicesForTagStrip: [0, 1],
    });
  });

  it('builds override policy from editable tags', () => {
    const tags: EditableMetadataTag[] = [
      {
        id: 'format:title',
        key: 'title',
        value: 'Clip',
        kind: 'format',
        isRemoved: false,
      },
      {
        id: 'stream:0:language',
        key: 'language',
        value: 'eng',
        kind: 'stream',
        streamIndex: 0,
        isRemoved: false,
      },
      {
        id: 'format:comment',
        key: 'comment',
        value: 'gone',
        kind: 'format',
        isRemoved: true,
      },
    ];

    const policy = makePolicyFromTags(tags, false);
    expect(policy.stripAll).toBe(false);
    expect(policy.retainedFormatTags).toEqual({ title: 'Clip' });
    expect(policy.retainedStreamTags).toEqual({ 0: { language: 'eng' } });
    expect(policy.sourceStreamIndicesForTagStrip).toEqual([0]);
  });

  it('strip-all ignores retained tag rows', () => {
    const tags = defaultEditableTags();
    const overridden = applyTagOverride(tags, 'format:title', 'Hello');
    expect(makePolicyFromTags(overridden, true).stripAll).toBe(true);
    expect(makePolicyFromTags(overridden, true).retainedFormatTags).toEqual({});
  });

  it('applies overrides and removal flags immutably', () => {
    const tags = defaultEditableTags();
    const next = applyTagOverride(tags, 'format:artist', 'Ada');
    expect(next.find((t) => t.id === 'format:artist')?.value).toBe('Ada');
    expect(tags.find((t) => t.id === 'format:artist')?.value).toBe('');

    const removed = markTagRemoved(next, 'format:artist', true);
    expect(removed.find((t) => t.id === 'format:artist')?.isRemoved).toBe(true);
    expect(next.find((t) => t.id === 'format:artist')?.isRemoved).toBe(false);
  });
});
