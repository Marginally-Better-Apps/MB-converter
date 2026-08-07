import { ImportErrorCode, throwImportError } from '@/src/core/io/ImportError';

/** Maximum size for any single import (bytes). Mirrors Swift ImportService.maxImportBytes. */
export const MAX_IMPORT_BYTES = 150 * 1024 * 1024;

export function formatImportSizeLimitMb(limitBytes: number): number {
  return Math.floor(limitBytes / (1024 * 1024));
}

export function enforceImportSizeLimit(byteCount: number): void {
  if (byteCount > MAX_IMPORT_BYTES) {
    throwImportError({
      code: ImportErrorCode.fileTooLarge,
      limitBytes: MAX_IMPORT_BYTES,
    });
  }
}
