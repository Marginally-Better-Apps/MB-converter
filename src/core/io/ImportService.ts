import * as Clipboard from 'expo-clipboard';
import * as DocumentPicker from 'expo-document-picker';
import { File } from 'expo-file-system';
import * as ImagePicker from 'expo-image-picker';

import {
  detectCategory,
  detectCategoryFromMime,
  extensionForMime,
} from '@/src/core/compatibility/FormatMatrix';
import type { MediaCategory } from '@/src/core/models/types';
import { ImportErrorCode, isImportError, throwImportError } from '@/src/core/io/ImportError';
import { enforceImportSizeLimit, MAX_IMPORT_BYTES } from '@/src/core/io/importLimits';
import {
  copyUriToImportStorage,
  makeImportDestination,
  writeBytesToImportStorage,
} from '@/src/core/io/ImportStorage';
import {
  assertRemoteResponseImportable,
  consumeDownloadWithSizeCap,
  declaredContentLength,
  normalizeRemoteURL,
  type RemoteDownloadProgress,
} from '@/src/core/io/remoteImportHelpers';

export type ImportedMedia = {
  uri: string;
  filename: string;
  category: MediaCategory;
  byteSize: number;
};

export type { RemoteDownloadProgress };

function filenameFromUri(uri: string, fallback: string): string {
  try {
    const path = uri.split('?')[0] ?? uri;
    const base = path.split(/[\\/]/).pop();
    if (base && base.includes('.')) return decodeURIComponent(base);
  } catch {
    // ignore
  }
  return fallback;
}

function extensionFromNameOrMime(
  name: string | null | undefined,
  mime: string | null | undefined,
  fallback = 'dat'
): string {
  if (name) {
    const base = name.split(/[\\/]/).pop() ?? name;
    const dot = base.lastIndexOf('.');
    if (dot >= 0) {
      const ext = base.slice(dot + 1);
      if (ext) return ext;
    }
  }
  if (mime) {
    const fromMime = extensionForMime(mime);
    if (fromMime) return fromMime;
  }
  return fallback;
}

function finalizeImported(uri: string, preferredName: string): ImportedMedia {
  const file = new File(uri);
  const byteSize = file.size ?? 0;
  enforceImportSizeLimit(byteSize);

  const filename = preferredName || file.name || filenameFromUri(uri, 'import.dat');
  const category = detectCategory(filename) ?? detectCategory(uri);
  if (!category) {
    try {
      file.delete();
    } catch {
      // best-effort
    }
    throwImportError({ code: ImportErrorCode.unsupportedType });
  }

  return { uri, filename, category, byteSize };
}

export async function pasteboardImportLabel(): Promise<string | null> {
  if (await Clipboard.hasImageAsync()) {
    return 'PNG';
  }
  const url = await Clipboard.getUrlAsync();
  if (url) {
    const category = detectCategory(url);
    if (category) {
      const ext = url.split('.').pop()?.toUpperCase();
      return ext && ext.length <= 5 ? ext : 'File';
    }
  }
  return null;
}

export async function importFromPhotos(): Promise<ImportedMedia | null> {
  const permission = await ImagePicker.requestMediaLibraryPermissionsAsync();
  if (!permission.granted) {
    throwImportError({
      code: ImportErrorCode.copyFailed,
      message: 'Photo library access was denied.',
    });
  }

  const result = await ImagePicker.launchImageLibraryAsync({
    mediaTypes: ['images', 'videos'],
    quality: 1,
    allowsMultipleSelection: false,
    exif: false,
  });

  if (result.canceled || !result.assets[0]) {
    return null;
  }

  const asset = result.assets[0];
  const originalName = asset.fileName ?? filenameFromUri(asset.uri, 'photo.jpg');
  const fallbackExtension = extensionFromNameOrMime(
    originalName,
    asset.mimeType,
    asset.type === 'video' ? 'mp4' : 'jpg'
  );

  if (typeof asset.fileSize === 'number') {
    enforceImportSizeLimit(asset.fileSize);
  }

  const categoryHint =
    detectCategory(originalName) ??
    (asset.mimeType ? detectCategoryFromMime(asset.mimeType) : null) ??
    (asset.type === 'video' ? 'video' : detectCategory(`x.${fallbackExtension}`));

  if (!categoryHint) {
    throwImportError({ code: ImportErrorCode.unsupportedType });
  }

  const uri = await copyUriToImportStorage(asset.uri, {
    originalName,
    fallbackExtension,
  });

  return finalizeImported(uri, originalName);
}

export async function importFromFiles(): Promise<ImportedMedia | null> {
  const result = await DocumentPicker.getDocumentAsync({
    type: [
      'image/*',
      'video/*',
      'audio/*',
      'public.movie',
      'public.audio',
      'public.image',
    ],
    copyToCacheDirectory: true,
    multiple: false,
  });

  if (result.canceled || !result.assets[0]) {
    return null;
  }

  const asset = result.assets[0];
  return importFromFileUri(asset.uri, {
    originalName: asset.name,
    mimeType: asset.mimeType,
    byteSize: asset.size ?? null,
  });
}

export async function importFromFileUri(
  sourceUri: string,
  options?: {
    originalName?: string | null;
    mimeType?: string | null;
    byteSize?: number | null;
  }
): Promise<ImportedMedia> {
  const originalName =
    options?.originalName ?? filenameFromUri(sourceUri, 'import.dat');
  const fallbackExtension = extensionFromNameOrMime(
    originalName,
    options?.mimeType ?? null
  );

  const category =
    detectCategory(originalName) ??
    detectCategory(sourceUri) ??
    (options?.mimeType ? detectCategoryFromMime(options.mimeType) : null);

  if (!category) {
    throwImportError({ code: ImportErrorCode.unsupportedType });
  }

  if (typeof options?.byteSize === 'number') {
    enforceImportSizeLimit(options.byteSize);
  }

  const uri = await copyUriToImportStorage(sourceUri, {
    originalName,
    fallbackExtension,
  });

  return finalizeImported(uri, originalName);
}

export async function importFromPasteboard(): Promise<ImportedMedia> {
  if (await Clipboard.hasImageAsync()) {
    const image = await Clipboard.getImageAsync({ format: 'png' });
    if (!image?.data) {
      throwImportError({ code: ImportErrorCode.noSupportedMediaInPasteboard });
    }
    const bytes = decodeDataUriOrBase64(image.data);
    enforceImportSizeLimit(bytes.byteLength);
    const uri = await writeBytesToImportStorage(bytes, {
      originalName: 'clipboard.png',
      fallbackExtension: 'png',
    });
    return finalizeImported(uri, 'clipboard.png');
  }

  const url = await Clipboard.getUrlAsync();
  if (url) {
    if (url.startsWith('file://') || url.startsWith('/')) {
      return importFromFileUri(url);
    }
    // Remote URL on clipboard — treat as link import.
    return importFromRemoteURL(url);
  }

  throwImportError({ code: ImportErrorCode.noSupportedMediaInPasteboard });
}

function decodeDataUriOrBase64(value: string): Uint8Array {
  const comma = value.indexOf(',');
  const base64 = value.startsWith('data:') && comma >= 0 ? value.slice(comma + 1) : value;
  const binary = globalThis.atob(base64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i += 1) {
    bytes[i] = binary.charCodeAt(i);
  }
  return bytes;
}

export async function importFromRemoteURL(
  raw: string,
  progress?: (p: RemoteDownloadProgress) => void | Promise<void>
): Promise<ImportedMedia> {
  const url = normalizeRemoteURL(raw);
  if (!url) {
    throwImportError({ code: ImportErrorCode.invalidRemoteURL });
  }

  let response: Response;
  try {
    response = await fetch(url.href, {
      method: 'GET',
      headers: { 'Accept-Encoding': 'identity' },
    });
  } catch (error) {
    throwImportError({
      code: ImportErrorCode.networkFailed,
      message: error instanceof Error ? error.message : String(error),
    });
  }

  const contentType = response.headers.get('content-type');
  const contentDisposition = response.headers.get('content-disposition');
  const length = declaredContentLength({
    contentLength: response.headers.get('content-length'),
  });

  const { ext } = assertRemoteResponseImportable({
    status: response.status,
    contentLength: length,
    contentType,
    contentDisposition,
    remoteURL: url,
  });

  const dest = makeImportDestination({
    originalName: `download.${ext}`,
    fallbackExtension: ext,
  });

  try {
    dest.create({ overwrite: true });
    const writer = dest.writableStream().getWriter();
    const body = response.body;
    if (!body) {
      const buffer = new Uint8Array(await response.arrayBuffer());
      enforceImportSizeLimit(buffer.byteLength);
      await writer.write(buffer);
      await writer.close();
      await progress?.({ bytesReceived: buffer.byteLength, totalBytes: buffer.byteLength });
    } else {
      async function* chunkStream(): AsyncGenerator<Uint8Array> {
        const reader = body!.getReader();
        try {
          while (true) {
            const { done, value } = await reader.read();
            if (done) break;
            if (value) yield value;
          }
        } finally {
          reader.releaseLock();
        }
      }

      try {
        await consumeDownloadWithSizeCap({
          stream: chunkStream(),
          maxBytes: MAX_IMPORT_BYTES,
          totalBytes: length,
          onChunk: async (chunk) => {
            await writer.write(chunk);
          },
          onProgress: progress,
        });
        await writer.close();
      } catch (error) {
        try {
          await writer.abort();
        } catch {
          // ignore
        }
        throw error;
      }
    }
  } catch (error) {
    if (dest.exists) {
      try {
        dest.delete();
      } catch {
        // best-effort
      }
    }
    if (isImportError(error)) throw error;
    throwImportError({
      code: ImportErrorCode.networkFailed,
      message: error instanceof Error ? error.message : String(error),
    });
  }

  const preferredName =
    contentDisposition && contentDisposition.toLowerCase().includes('filename')
      ? `download.${ext}`
      : filenameFromUri(url.pathname, `download.${ext}`);

  return finalizeImported(dest.uri, preferredName.includes('.') ? preferredName : `download.${ext}`);
}
