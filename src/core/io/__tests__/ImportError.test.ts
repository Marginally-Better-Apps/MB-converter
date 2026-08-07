import { ImportErrorCode, messageForImportError } from '@/src/core/io/ImportError';

describe('ImportError mapping', () => {
  it('maps unsupportedType', () => {
    expect(messageForImportError({ code: ImportErrorCode.unsupportedType })).toBe(
      'This file type is not supported.'
    );
  });

  it('maps noSupportedMediaInPasteboard', () => {
    expect(
      messageForImportError({ code: ImportErrorCode.noSupportedMediaInPasteboard })
    ).toBe(
      'There is no supported media in the clipboard. Copy a file in Files or copy an image.'
    );
  });

  it('maps copyFailed with detail', () => {
    expect(
      messageForImportError({ code: ImportErrorCode.copyFailed, message: 'disk full' })
    ).toBe('Import failed: disk full');
  });

  it('maps invalidRemoteURL', () => {
    expect(messageForImportError({ code: ImportErrorCode.invalidRemoteURL })).toBe(
      'Enter a valid http or https link.'
    );
  });

  it('maps couldNotDetermineRemoteFileType', () => {
    expect(
      messageForImportError({ code: ImportErrorCode.couldNotDetermineRemoteFileType })
    ).toContain('Could not tell the file type');
  });

  it('maps networkFailed with detail', () => {
    expect(
      messageForImportError({ code: ImportErrorCode.networkFailed, message: 'timeout' })
    ).toBe('Download failed: timeout');
  });

  it('maps codecNotDecodable', () => {
    expect(
      messageForImportError({
        code: ImportErrorCode.codecNotDecodable,
        codecLabel: 'AV1',
        reason: 'Not in this FFmpeg build.',
      })
    ).toBe(
      "This file uses AV1, which the bundled FFmpeg can't decode. Not in this FFmpeg build."
    );
  });
});
