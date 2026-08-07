import { MAX_IMPORT_BYTES } from '@/src/core/io/importLimits';
import { ImportErrorCode, isImportError } from '@/src/core/io/ImportError';
import {
  assertRemoteResponseImportable,
  consumeDownloadWithSizeCap,
} from '@/src/core/io/remoteImportHelpers';

describe('ImportService remote size enforcement', () => {
  it('rejects when Content-Length exceeds the 150 MB cap before download', () => {
    expect(() =>
      assertRemoteResponseImportable({
        status: 200,
        contentLength: MAX_IMPORT_BYTES + 1,
        contentType: 'video/mp4',
        contentDisposition: null,
        remoteURL: new URL('https://cdn.example.com/huge.mp4'),
      })
    ).toThrow(
      expect.objectContaining({
        code: ImportErrorCode.fileTooLarge,
        limitBytes: MAX_IMPORT_BYTES,
      })
    );
  });

  it('rejects unsupported remote responses with no inferable type', () => {
    expect(() =>
      assertRemoteResponseImportable({
        status: 200,
        contentLength: 1024,
        contentType: 'application/octet-stream',
        contentDisposition: null,
        remoteURL: new URL('https://cdn.example.com/download'),
      })
    ).toThrow(
      expect.objectContaining({
        code: ImportErrorCode.couldNotDetermineRemoteFileType,
      })
    );
  });

  it('rejects non-2xx HTTP responses as networkFailed', () => {
    expect(() =>
      assertRemoteResponseImportable({
        status: 404,
        contentLength: null,
        contentType: 'video/mp4',
        contentDisposition: null,
        remoteURL: new URL('https://cdn.example.com/missing.mp4'),
      })
    ).toThrow(
      expect.objectContaining({
        code: ImportErrorCode.networkFailed,
      })
    );
  });

  it('aborts streaming download once bytes exceed the cap', async () => {
    const chunk = new Uint8Array(1024).fill(1);
    async function* oversizedStream() {
      // Stream just over the cap in 1 KB chunks.
      const over = MAX_IMPORT_BYTES + 2048;
      let sent = 0;
      while (sent < over) {
        yield chunk;
        sent += chunk.byteLength;
      }
    }

    const chunks: Uint8Array[] = [];
    try {
      await consumeDownloadWithSizeCap({
        stream: oversizedStream(),
        maxBytes: MAX_IMPORT_BYTES,
        onChunk: (c) => {
          chunks.push(c);
        },
      });
      throw new Error('expected size-cap rejection');
    } catch (error) {
      expect(isImportError(error)).toBe(true);
      if (isImportError(error)) {
        expect(error.code).toBe(ImportErrorCode.fileTooLarge);
      }
    }
    expect(chunks.length).toBeGreaterThan(0);
  });
});
