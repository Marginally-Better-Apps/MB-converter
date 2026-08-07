import { extensionForMime } from '@/src/core/compatibility/FormatMatrix';
import { ImportErrorCode, throwImportError } from '@/src/core/io/ImportError';
import { MAX_IMPORT_BYTES } from '@/src/core/io/importLimits';

export type RemoteDownloadProgress = {
  bytesReceived: number;
  totalBytes: number | null;
};

export function normalizeRemoteURL(raw: string): URL | null {
  const trimmed = raw.trim();
  if (!trimmed) return null;

  const tryParse = (value: string): URL | null => {
    try {
      return new URL(value);
    } catch {
      return null;
    }
  };

  let url = tryParse(trimmed);
  if (!url?.protocol) {
    url = tryParse(`https://${trimmed}`);
  }
  if (!url?.host) return null;

  const scheme = url.protocol.replace(':', '').toLowerCase();
  if (scheme !== 'http' && scheme !== 'https') return null;
  return url;
}

export function filenameFromContentDisposition(value: string): string | null {
  const segments = value.split(';').map((s) => s.trim());
  for (const segment of segments) {
    if (segment.toLowerCase().startsWith('filename*=')) {
      let rest = segment.slice('filename*='.length).trim();
      const sep = rest.indexOf("''");
      if (sep >= 0) {
        rest = rest.slice(sep + 2);
      }
      const token = rest.split(';')[0] ?? rest;
      const decoded = decodeURIComponent(token);
      if (decoded) return decoded;
    }
  }
  for (const segment of segments) {
    if (segment.toLowerCase().startsWith('filename=')) {
      let name = segment.slice('filename='.length).trim();
      if (name.startsWith('"') && name.endsWith('"') && name.length >= 2) {
        name = name.slice(1, -1);
      } else {
        name = name.split(';')[0] ?? name;
      }
      if (name) return name;
    }
  }
  return null;
}

export function inferredFileExtension(options: {
  remoteURL: URL;
  contentDisposition?: string | null;
  contentType?: string | null;
}): string | null {
  if (options.contentDisposition) {
    const name = filenameFromContentDisposition(options.contentDisposition);
    if (name) {
      const ext = name.split(/[\\/]/).pop()?.split('.').pop()?.toLowerCase() ?? '';
      if (ext && name.includes('.')) return ext;
    }
  }

  const pathBase = options.remoteURL.pathname.split('/').pop() ?? '';
  const dot = pathBase.lastIndexOf('.');
  if (dot >= 0) {
    const pathExt = pathBase.slice(dot + 1).toLowerCase();
    if (pathExt) return pathExt;
  }

  if (options.contentType) {
    return extensionForMime(options.contentType);
  }
  return null;
}

export function declaredContentLength(headers: {
  contentLength?: string | null;
  expectedContentLength?: number | null;
}): number | null {
  if (
    typeof headers.expectedContentLength === 'number' &&
    headers.expectedContentLength > 0
  ) {
    return headers.expectedContentLength;
  }
  if (headers.contentLength) {
    const firstToken = headers.contentLength
      .split(',')[0]
      ?.trim();
    if (firstToken) {
      const declared = Number.parseInt(firstToken, 10);
      if (Number.isFinite(declared) && declared > 0) return declared;
    }
  }
  return null;
}

export function shouldRejectDeclaredSize(declaredBytes: number): boolean {
  return declaredBytes > MAX_IMPORT_BYTES;
}

export function remoteDownloadDisplayFraction(progress: RemoteDownloadProgress): number {
  if (progress.totalBytes != null && progress.totalBytes > 0) {
    return Math.min(1, progress.bytesReceived / progress.totalBytes);
  }
  const b = Math.max(0, progress.bytesReceived);
  const cap = MAX_IMPORT_BYTES;
  if (cap <= 0) return 0;
  return Math.min(0.99, Math.log(1 + b) / Math.log(1 + cap));
}

export function assertRemoteResponseImportable(options: {
  status: number;
  contentLength: number | null;
  contentType: string | null;
  contentDisposition: string | null;
  remoteURL: URL;
}): { ext: string; declaredContentLength: number | null } {
  if (options.status < 200 || options.status > 299) {
    throwImportError({
      code: ImportErrorCode.networkFailed,
      message: `Server returned status ${options.status}.`,
    });
  }

  if (options.contentLength != null && shouldRejectDeclaredSize(options.contentLength)) {
    throwImportError({
      code: ImportErrorCode.fileTooLarge,
      limitBytes: MAX_IMPORT_BYTES,
    });
  }

  const ext = inferredFileExtension({
    remoteURL: options.remoteURL,
    contentDisposition: options.contentDisposition,
    contentType: options.contentType,
  });
  if (!ext) {
    throwImportError({ code: ImportErrorCode.couldNotDetermineRemoteFileType });
  }

  return { ext, declaredContentLength: options.contentLength };
}

export async function consumeDownloadWithSizeCap(options: {
  stream: AsyncIterable<Uint8Array>;
  maxBytes?: number;
  onChunk: (chunk: Uint8Array) => void | Promise<void>;
  onProgress?: (progress: RemoteDownloadProgress) => void | Promise<void>;
  totalBytes?: number | null;
}): Promise<number> {
  const maxBytes = options.maxBytes ?? MAX_IMPORT_BYTES;
  let total = 0;
  await options.onProgress?.({
    bytesReceived: 0,
    totalBytes: options.totalBytes ?? null,
  });

  for await (const chunk of options.stream) {
    total += chunk.byteLength;
    if (total > maxBytes) {
      throwImportError({
        code: ImportErrorCode.fileTooLarge,
        limitBytes: maxBytes,
      });
    }
    await options.onChunk(chunk);
    await options.onProgress?.({
      bytesReceived: total,
      totalBytes: options.totalBytes ?? null,
    });
  }

  if (options.totalBytes == null && total > 0) {
    await options.onProgress?.({ bytesReceived: total, totalBytes: total });
  }

  return total;
}
