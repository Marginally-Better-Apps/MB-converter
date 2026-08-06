import {
  COMPACT_CONTENT_MAX_WIDTH,
  LARGE_SCREEN_BREAKPOINT,
  REGULAR_CONTENT_MAX_WIDTH,
  contentMaxWidth,
  isLargeScreen,
} from '../contentWidth';

describe('contentMaxWidth', () => {
  it('uses compact width on phones', () => {
    expect(contentMaxWidth(390)).toBe(COMPACT_CONTENT_MAX_WIDTH);
    expect(contentMaxWidth(LARGE_SCREEN_BREAKPOINT - 1)).toBe(COMPACT_CONTENT_MAX_WIDTH);
  });

  it('uses regular width on iPad-sized screens', () => {
    expect(contentMaxWidth(LARGE_SCREEN_BREAKPOINT)).toBe(REGULAR_CONTENT_MAX_WIDTH);
    expect(contentMaxWidth(1024)).toBe(REGULAR_CONTENT_MAX_WIDTH);
  });

  it('falls back to compact for invalid widths', () => {
    expect(contentMaxWidth(0)).toBe(COMPACT_CONTENT_MAX_WIDTH);
    expect(contentMaxWidth(-10)).toBe(COMPACT_CONTENT_MAX_WIDTH);
    expect(contentMaxWidth(Number.NaN)).toBe(COMPACT_CONTENT_MAX_WIDTH);
  });
});

describe('isLargeScreen', () => {
  it('detects the large-screen breakpoint', () => {
    expect(isLargeScreen(767)).toBe(false);
    expect(isLargeScreen(768)).toBe(true);
  });
});
