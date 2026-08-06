import { MAX_IMPORT_BYTES } from '@/src/core/io/importLimits';
import {
  declaredContentLength,
  filenameFromContentDisposition,
  inferredFileExtension,
  normalizeRemoteURL,
  remoteDownloadDisplayFraction,
  shouldRejectDeclaredSize,
} from '@/src/core/io/remoteImportHelpers';

describe('remote import helpers', () => {
  describe('normalizeRemoteURL', () => {
    it('accepts http(s) URLs and prepends https when scheme is missing', () => {
      expect(normalizeRemoteURL('https://cdn.example.com/a.mp4')?.href).toBe(
        'https://cdn.example.com/a.mp4'
      );
      expect(normalizeRemoteURL('http://cdn.example.com/a.mp4')?.href).toBe(
        'http://cdn.example.com/a.mp4'
      );
      expect(normalizeRemoteURL('cdn.example.com/a.mp4')?.href).toBe(
        'https://cdn.example.com/a.mp4'
      );
    });

    it('rejects empty, whitespace-only, and non-http schemes', () => {
      expect(normalizeRemoteURL('')).toBeNull();
      expect(normalizeRemoteURL('   ')).toBeNull();
      expect(normalizeRemoteURL('ftp://cdn.example.com/a.mp4')).toBeNull();
      expect(normalizeRemoteURL('file:///tmp/a.mp4')).toBeNull();
    });
  });

  describe('Content-Disposition / Content-Type / path extension', () => {
    it('parses filename from Content-Disposition', () => {
      expect(filenameFromContentDisposition('attachment; filename="clip.mov"')).toBe(
        'clip.mov'
      );
      expect(
        filenameFromContentDisposition("attachment; filename*=UTF-8''clip%20final.mp4")
      ).toBe('clip final.mp4');
    });

    it('infers extension from disposition, then path, then mime', () => {
      expect(
        inferredFileExtension({
          remoteURL: new URL('https://cdn.example.com/download'),
          contentDisposition: 'attachment; filename="song.flac"',
          contentType: 'audio/mpeg',
        })
      ).toBe('flac');

      expect(
        inferredFileExtension({
          remoteURL: new URL('https://cdn.example.com/clip.webm?token=1'),
          contentType: 'application/octet-stream',
        })
      ).toBe('webm');

      expect(
        inferredFileExtension({
          remoteURL: new URL('https://cdn.example.com/download'),
          contentType: 'video/quicktime',
        })
      ).toBe('mov');

      expect(
        inferredFileExtension({
          remoteURL: new URL('https://cdn.example.com/download'),
          contentType: 'application/octet-stream',
        })
      ).toBeNull();
    });
  });

  describe('declared size check', () => {
    it('reads Content-Length and flags sizes over the import cap', () => {
      expect(declaredContentLength({ contentLength: '1048576' })).toBe(1_048_576);
      expect(declaredContentLength({ expectedContentLength: 2048 })).toBe(2048);
      expect(shouldRejectDeclaredSize(MAX_IMPORT_BYTES)).toBe(false);
      expect(shouldRejectDeclaredSize(MAX_IMPORT_BYTES + 1)).toBe(true);
    });
  });

  describe('download progress display', () => {
    it('uses known totals when present and a log curve when total is unknown', () => {
      expect(
        remoteDownloadDisplayFraction({ bytesReceived: 50, totalBytes: 100 })
      ).toBe(0.5);
      const unknown = remoteDownloadDisplayFraction({
        bytesReceived: 10 * 1024 * 1024,
        totalBytes: null,
      });
      expect(unknown).toBeGreaterThan(0);
      expect(unknown).toBeLessThan(1);
    });
  });
});
