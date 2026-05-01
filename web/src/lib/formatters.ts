export function bytes(value: number): string {
  if (!Number.isFinite(value) || value <= 0) {
    return "0 B";
  }

  const units = ["B", "KB", "MB", "GB"];
  let unitIndex = 0;
  let next = value;
  while (next >= 1024 && unitIndex < units.length - 1) {
    next /= 1024;
    unitIndex += 1;
  }

  const precision = next >= 10 || unitIndex === 0 ? 0 : 1;
  return `${next.toFixed(precision)} ${units[unitIndex]}`;
}

export function bitrateText(bitsPerSecond?: number | null): string {
  if (!bitsPerSecond || bitsPerSecond <= 0) {
    return "Unknown";
  }
  if (bitsPerSecond >= 1_000_000) {
    return `${(bitsPerSecond / 1_000_000).toFixed(bitsPerSecond >= 10_000_000 ? 0 : 1)} Mbps`;
  }
  return `${Math.round(bitsPerSecond / 1000)} kbps`;
}

export function durationText(seconds?: number | null): string {
  if (!seconds || seconds <= 0 || !Number.isFinite(seconds)) {
    return "Unknown";
  }
  const rounded = Math.round(seconds);
  const h = Math.floor(rounded / 3600);
  const m = Math.floor((rounded % 3600) / 60);
  const s = rounded % 60;
  if (h > 0) {
    return `${h}:${m.toString().padStart(2, "0")}:${s.toString().padStart(2, "0")}`;
  }
  return `${m}:${s.toString().padStart(2, "0")}`;
}

export function dimensionsText(dimensions?: { width: number; height: number } | null): string {
  if (!dimensions) {
    return "Unknown";
  }
  return `${Math.round(dimensions.width)} x ${Math.round(dimensions.height)}`;
}

export function fpsText(fps?: number | null): string {
  if (!fps || fps <= 0) {
    return "Unknown";
  }
  return `${Number.isInteger(fps) ? fps.toFixed(0) : fps.toFixed(2)} fps`;
}

export function sanitizeBaseName(name: string): string {
  const trimmed = name.trim().replace(/[/:\\]/g, "-");
  if (!trimmed) {
    return "converted";
  }
  return trimmed.replace(/\.[^.]+$/, "") || "converted";
}

export function fileExtension(name: string): string {
  const match = /\.([^.]+)$/.exec(name.trim().toLowerCase());
  return match?.[1] ?? "";
}

