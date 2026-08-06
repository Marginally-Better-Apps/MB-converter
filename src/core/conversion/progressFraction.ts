/**
 * Maps FFmpeg statistics time to a 0…1 progress fraction.
 * Returns null when duration is unknown (raw/elementary streams).
 */
export function progressFractionFromFFmpegStats(
  timeMilliseconds: number,
  durationSec: number | null | undefined
): number | null {
  if (durationSec == null || !(durationSec > 0)) return null;
  const fraction = timeMilliseconds / (durationSec * 1000);
  return Math.min(1, Math.max(0, fraction));
}
