import React, {
  createContext,
  useCallback,
  useContext,
  useMemo,
  useRef,
  useState,
} from 'react';

import type { ConversionResult } from '@/src/core/conversion/ConversionService';
import { isConversionError } from '@/src/core/conversion/ConversionError';
import type { ConversionConfig, MediaCategory, MediaFile, OutputFormat } from '@/src/core/models/types';
import { createConversionService } from '@/src/features/conversion/createConversionService';

export type ConversionSessionInput = {
  uri: string;
  filename: string;
  category: MediaCategory;
  byteSize: number;
  duration?: number;
  dimensions?: { width: number; height: number };
  videoCodec?: string;
  audioCodec?: string;
  containerFormat?: string;
};

type ConversionContextValue = {
  input: ConversionSessionInput | null;
  mediaFile: MediaFile | null;
  config: ConversionConfig | null;
  progress: number;
  isConverting: boolean;
  errorMessage: string | null;
  result: ConversionResult | null;
  setSessionInput: (input: ConversionSessionInput) => void;
  setConfig: (config: ConversionConfig) => void;
  updateOutputFormat: (format: OutputFormat) => void;
  startConversion: () => Promise<ConversionResult | null>;
  cancelConversion: () => Promise<void>;
  clearError: () => void;
  resetResult: () => void;
};

const ConversionContext = createContext<ConversionContextValue | null>(null);

function toMediaFile(input: ConversionSessionInput): MediaFile {
  const path = input.uri.startsWith('file://') ? input.uri.slice('file://'.length) : input.uri;
  return {
    path,
    category: input.category,
    sizeOnDisk: input.byteSize,
    duration: input.duration,
    dimensions: input.dimensions,
    videoCodec: input.videoCodec,
    audioCodec: input.audioCodec,
    containerFormat: input.containerFormat ?? guessContainer(input.filename),
  };
}

function guessContainer(filename: string): string {
  const ext = filename.split('.').pop()?.toLowerCase() ?? '';
  return ext;
}

function messageForError(error: unknown): string {
  if (isConversionError(error)) return error.message;
  if (error instanceof Error) return error.message;
  return 'Conversion failed.';
}

export function ConversionProvider({ children }: { children: React.ReactNode }) {
  const serviceRef = useRef<ReturnType<typeof createConversionService> | null>(null);
  const [input, setInput] = useState<ConversionSessionInput | null>(null);
  const [config, setConfigState] = useState<ConversionConfig | null>(null);
  const [progress, setProgress] = useState(0);
  const [isConverting, setIsConverting] = useState(false);
  const [errorMessage, setErrorMessage] = useState<string | null>(null);
  const [result, setResult] = useState<ConversionResult | null>(null);

  const getService = useCallback(() => {
    if (!serviceRef.current) {
      serviceRef.current = createConversionService();
    }
    return serviceRef.current;
  }, []);

  const setSessionInput = useCallback((next: ConversionSessionInput) => {
    setInput(next);
    setResult(null);
    setErrorMessage(null);
    setProgress(0);
  }, []);

  const setConfig = useCallback((next: ConversionConfig) => {
    setConfigState(next);
  }, []);

  const updateOutputFormat = useCallback((format: OutputFormat) => {
    setConfigState((prev) => ({
      ...(prev ?? { outputFormat: format }),
      outputFormat: format,
    }));
  }, []);

  const startConversion = useCallback(async (): Promise<ConversionResult | null> => {
    if (!input || !config) {
      setErrorMessage('Missing conversion input or settings.');
      return null;
    }
    setIsConverting(true);
    setErrorMessage(null);
    setProgress(0);
    setResult(null);
    try {
      serviceRef.current = createConversionService();
      const converted = await serviceRef.current.convert(toMediaFile(input), config, {
        onProgress: setProgress,
      });
      setResult(converted);
      setProgress(1);
      return converted;
    } catch (error) {
      if (isConversionError(error) && error.code === 'cancelled') {
        setErrorMessage(null);
      } else {
        setErrorMessage(messageForError(error));
      }
      return null;
    } finally {
      setIsConverting(false);
    }
  }, [config, input]);

  const cancelConversion = useCallback(async () => {
    await getService().cancel();
  }, [getService]);

  const clearError = useCallback(() => setErrorMessage(null), []);
  const resetResult = useCallback(() => setResult(null), []);

  const mediaFile = useMemo(() => (input ? toMediaFile(input) : null), [input]);

  const value = useMemo<ConversionContextValue>(
    () => ({
      input,
      mediaFile,
      config,
      progress,
      isConverting,
      errorMessage,
      result,
      setSessionInput,
      setConfig,
      updateOutputFormat,
      startConversion,
      cancelConversion,
      clearError,
      resetResult,
    }),
    [
      input,
      mediaFile,
      config,
      progress,
      isConverting,
      errorMessage,
      result,
      setSessionInput,
      setConfig,
      updateOutputFormat,
      startConversion,
      cancelConversion,
      clearError,
      resetResult,
    ]
  );

  return <ConversionContext.Provider value={value}>{children}</ConversionContext.Provider>;
}

export function useConversion(): ConversionContextValue {
  const ctx = useContext(ConversionContext);
  if (!ctx) {
    throw new Error('useConversion must be used within ConversionProvider');
  }
  return ctx;
}
