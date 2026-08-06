/** Phone-oriented content column (≈ NativeWind max-w-md). */
export const COMPACT_CONTENT_MAX_WIDTH = 448;

/** Wider column on iPad / large screens (≈ NativeWind max-w-2xl). */
export const REGULAR_CONTENT_MAX_WIDTH = 672;

/** Treat widths at or above this as split-friendly / iPad. */
export const LARGE_SCREEN_BREAKPOINT = 768;

/**
 * Caps readable content width on phones; opens up on large screens
 * without cloning NavigationSplitView.
 */
export function contentMaxWidth(windowWidth: number): number {
  if (!Number.isFinite(windowWidth) || windowWidth <= 0) {
    return COMPACT_CONTENT_MAX_WIDTH;
  }
  return windowWidth >= LARGE_SCREEN_BREAKPOINT
    ? REGULAR_CONTENT_MAX_WIDTH
    : COMPACT_CONTENT_MAX_WIDTH;
}

export function isLargeScreen(windowWidth: number): boolean {
  return Number.isFinite(windowWidth) && windowWidth >= LARGE_SCREEN_BREAKPOINT;
}
