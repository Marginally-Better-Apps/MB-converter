import React, { createContext, useCallback, useContext, useMemo, useState } from 'react';

import {
  importFromFiles,
  importFromPasteboard,
  importFromPhotos,
  importFromRemoteURL,
  pasteboardImportLabel,
  type ImportedMedia,
  type RemoteDownloadProgress,
} from '@/src/core/io/ImportService';
import { isImportError, messageForImportError } from '@/src/core/io/ImportError';

type ImportContextValue = {
  isImporting: boolean;
  errorMessage: string | null;
  clearError: () => void;
  remoteDownloadProgress: RemoteDownloadProgress | null;
  pasteLabel: string | null;
  lastImport: ImportedMedia | null;
  refreshPasteboard: () => Promise<void>;
  pickFromPhotos: () => Promise<ImportedMedia | null>;
  pickFromFiles: () => Promise<ImportedMedia | null>;
  pasteFromClipboard: () => Promise<ImportedMedia | null>;
  importRemoteLink: (url: string) => Promise<ImportedMedia | null>;
};

const ImportContext = createContext<ImportContextValue | null>(null);

function errorToMessage(error: unknown): string {
  if (isImportError(error)) {
    return messageForImportError(error.importError);
  }
  if (error instanceof Error) return error.message;
  return 'Please try again.';
}

export function ImportProvider({ children }: { children: React.ReactNode }) {
  const [isImporting, setIsImporting] = useState(false);
  const [errorMessage, setErrorMessage] = useState<string | null>(null);
  const [remoteDownloadProgress, setRemoteDownloadProgress] =
    useState<RemoteDownloadProgress | null>(null);
  const [pasteLabel, setPasteLabel] = useState<string | null>(null);
  const [lastImport, setLastImport] = useState<ImportedMedia | null>(null);

  const refreshPasteboard = useCallback(async () => {
    try {
      setPasteLabel(await pasteboardImportLabel());
    } catch {
      setPasteLabel(null);
    }
  }, []);

  const runImport = useCallback(
    async (operation: () => Promise<ImportedMedia | null>): Promise<ImportedMedia | null> => {
      setIsImporting(true);
      setErrorMessage(null);
      try {
        const media = await operation();
        if (media) {
          setLastImport(media);
        }
        return media;
      } catch (error) {
        setErrorMessage(errorToMessage(error));
        return null;
      } finally {
        setIsImporting(false);
        setRemoteDownloadProgress(null);
      }
    },
    []
  );

  const pickFromPhotos = useCallback(
    () => runImport(() => importFromPhotos()),
    [runImport]
  );

  const pickFromFiles = useCallback(
    () => runImport(() => importFromFiles()),
    [runImport]
  );

  const pasteFromClipboard = useCallback(
    () => runImport(() => importFromPasteboard()),
    [runImport]
  );

  const importRemoteLink = useCallback(
    (url: string) =>
      runImport(() =>
        importFromRemoteURL(url, (progress) => {
          setRemoteDownloadProgress(progress);
        })
      ),
    [runImport]
  );

  const clearError = useCallback(() => setErrorMessage(null), []);

  const value = useMemo(
    () => ({
      isImporting,
      errorMessage,
      clearError,
      remoteDownloadProgress,
      pasteLabel,
      lastImport,
      refreshPasteboard,
      pickFromPhotos,
      pickFromFiles,
      pasteFromClipboard,
      importRemoteLink,
    }),
    [
      isImporting,
      errorMessage,
      clearError,
      remoteDownloadProgress,
      pasteLabel,
      lastImport,
      refreshPasteboard,
      pickFromPhotos,
      pickFromFiles,
      pasteFromClipboard,
      importRemoteLink,
    ]
  );

  return <ImportContext.Provider value={value}>{children}</ImportContext.Provider>;
}

export function useImport(): ImportContextValue {
  const ctx = useContext(ImportContext);
  if (!ctx) {
    throw new Error('useImport must be used within ImportProvider');
  }
  return ctx;
}
