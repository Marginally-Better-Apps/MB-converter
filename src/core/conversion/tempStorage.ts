import { fileExtension } from '@/src/core/ffmpeg/outputFormatArgs';
import type { OutputFormat } from '@/src/core/models/types';

export function joinTempPath(directory: string, filename: string): string {
  const base = directory.replace(/\/+$/, '');
  return `${base}/${filename}`;
}

export function conversionOutputPath(directory: string, format: OutputFormat, id?: string): string {
  const stem = id ?? randomId();
  return joinTempPath(directory, `${stem}.${fileExtension(format)}`);
}

export function conversionPassLogPath(directory: string, id?: string): string {
  const stem = id ?? randomId();
  return joinTempPath(directory, `${stem}.log`);
}

function randomId(): string {
  return `conv-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 10)}`;
}
