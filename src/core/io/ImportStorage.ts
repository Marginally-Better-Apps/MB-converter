import { Directory, File, Paths } from 'expo-file-system';

import { ImportErrorCode, throwImportError } from '@/src/core/io/ImportError';

/** Temporary storage for imported source files, kept separate from conversion outputs. */
export const importsDirectoryName = 'imports';

export function importFilename(options: {
  originalName: string | null;
  fallbackExtension: string;
  id: string;
}): string {
  const fromOriginal = options.originalName
    ? options.originalName.split(/[\\/]/).pop()?.split('.').pop()
    : undefined;
  const ext =
    fromOriginal && options.originalName?.includes('.') && fromOriginal.length > 0
      ? fromOriginal
      : options.fallbackExtension;
  return `${options.id}.${ext}`;
}

function importsDirectory(): Directory {
  const dir = new Directory(Paths.cache, importsDirectoryName);
  if (!dir.exists) {
    dir.create();
  }
  return dir;
}

export function makeImportDestination(options: {
  originalName: string | null;
  fallbackExtension: string;
  id?: string;
}): File {
  const id = options.id ?? cryptoRandomId();
  const name = importFilename({
    originalName: options.originalName,
    fallbackExtension: options.fallbackExtension,
    id,
  });
  return new File(importsDirectory(), name);
}

function cryptoRandomId(): string {
  // Prefer crypto.randomUUID when available (Hermes / modern JS); fallback for Jest.
  const c = globalThis.crypto as Crypto | undefined;
  if (c && typeof c.randomUUID === 'function') {
    return c.randomUUID();
  }
  return `import-${Date.now()}-${Math.random().toString(16).slice(2)}`;
}

export async function writeBytesToImportStorage(
  data: Uint8Array,
  options: { originalName: string | null; fallbackExtension: string }
): Promise<string> {
  const dest = makeImportDestination(options);
  try {
    dest.create({ overwrite: true });
    dest.write(data);
    return dest.uri;
  } catch (error) {
    throwImportError({
      code: ImportErrorCode.copyFailed,
      message: error instanceof Error ? error.message : String(error),
    });
  }
}

export async function copyUriToImportStorage(
  sourceUri: string,
  options: { originalName: string | null; fallbackExtension: string }
): Promise<string> {
  const dest = makeImportDestination(options);
  try {
    const source = new File(sourceUri);
    await source.copy(dest, { overwrite: true });
    return dest.uri;
  } catch (error) {
    if (dest.exists) {
      try {
        dest.delete();
      } catch {
        // best-effort cleanup
      }
    }
    throwImportError({
      code: ImportErrorCode.copyFailed,
      message: error instanceof Error ? error.message : String(error),
    });
  }
}

export function cleanAllImports(): void {
  const dir = new Directory(Paths.cache, importsDirectoryName);
  if (!dir.exists) return;
  try {
    dir.delete();
  } catch {
    // best-effort
  }
}
