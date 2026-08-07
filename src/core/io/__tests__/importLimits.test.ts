import {
  MAX_IMPORT_BYTES,
  enforceImportSizeLimit,
  formatImportSizeLimitMb,
} from '@/src/core/io/importLimits';
import { ImportErrorCode, messageForImportError } from '@/src/core/io/ImportError';

describe('import size cap', () => {
  it('is 150 MB in bytes', () => {
    expect(MAX_IMPORT_BYTES).toBe(150 * 1024 * 1024);
    expect(formatImportSizeLimitMb(MAX_IMPORT_BYTES)).toBe(150);
  });

  it('allows files at or under the cap', () => {
    expect(() => enforceImportSizeLimit(0)).not.toThrow();
    expect(() => enforceImportSizeLimit(MAX_IMPORT_BYTES)).not.toThrow();
  });

  it('rejects files over the 150 MB cap', () => {
    expect(() => enforceImportSizeLimit(MAX_IMPORT_BYTES + 1)).toThrow(
      expect.objectContaining({
        code: ImportErrorCode.fileTooLarge,
        limitBytes: MAX_IMPORT_BYTES,
      })
    );
  });

  it('maps fileTooLarge to a human-readable message with MB limit', () => {
    expect(
      messageForImportError({
        code: ImportErrorCode.fileTooLarge,
        limitBytes: MAX_IMPORT_BYTES,
      })
    ).toBe('The file is larger than 150 MB.');
  });
});
