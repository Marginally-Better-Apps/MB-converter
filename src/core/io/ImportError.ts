export enum ImportErrorCode {
  noSupportedMediaInPasteboard = 'noSupportedMediaInPasteboard',
  unsupportedType = 'unsupportedType',
  copyFailed = 'copyFailed',
  fileTooLarge = 'fileTooLarge',
  invalidRemoteURL = 'invalidRemoteURL',
  couldNotDetermineRemoteFileType = 'couldNotDetermineRemoteFileType',
  networkFailed = 'networkFailed',
  codecNotDecodable = 'codecNotDecodable',
}

export type ImportError =
  | { code: ImportErrorCode.noSupportedMediaInPasteboard }
  | { code: ImportErrorCode.unsupportedType }
  | { code: ImportErrorCode.copyFailed; message: string }
  | { code: ImportErrorCode.fileTooLarge; limitBytes: number }
  | { code: ImportErrorCode.invalidRemoteURL }
  | { code: ImportErrorCode.couldNotDetermineRemoteFileType }
  | { code: ImportErrorCode.networkFailed; message: string }
  | { code: ImportErrorCode.codecNotDecodable; codecLabel: string; reason: string };

export class ImportErrorException extends Error {
  readonly code: ImportErrorCode;
  readonly importError: ImportError;
  readonly limitBytes?: number;
  readonly codecLabel?: string;
  readonly reason?: string;
  /** Detail payload for copyFailed / networkFailed (Error.message is the full user string). */
  readonly detail?: string;

  constructor(importError: ImportError) {
    super(messageForImportError(importError));
    this.name = 'ImportErrorException';
    this.importError = importError;
    this.code = importError.code;

    if (importError.code === ImportErrorCode.fileTooLarge) {
      this.limitBytes = importError.limitBytes;
    }
    if (importError.code === ImportErrorCode.copyFailed || importError.code === ImportErrorCode.networkFailed) {
      this.detail = importError.message;
    }
    if (importError.code === ImportErrorCode.codecNotDecodable) {
      this.codecLabel = importError.codecLabel;
      this.reason = importError.reason;
    }
  }
}

export function isImportError(error: unknown): error is ImportErrorException {
  return error instanceof ImportErrorException;
}

export function throwImportError(error: ImportError): never {
  throw new ImportErrorException(error);
}

export function messageForImportError(error: ImportError): string {
  switch (error.code) {
    case ImportErrorCode.noSupportedMediaInPasteboard:
      return 'There is no supported media in the clipboard. Copy a file in Files or copy an image.';
    case ImportErrorCode.unsupportedType:
      return 'This file type is not supported.';
    case ImportErrorCode.copyFailed:
      return `Import failed: ${error.message}`;
    case ImportErrorCode.fileTooLarge:
      return `The file is larger than ${Math.floor(error.limitBytes / (1024 * 1024))} MB.`;
    case ImportErrorCode.invalidRemoteURL:
      return 'Enter a valid http or https link.';
    case ImportErrorCode.couldNotDetermineRemoteFileType:
      return 'Could not tell the file type from the link or server response. Try a URL whose path ends with a supported extension (for example .mp4).';
    case ImportErrorCode.networkFailed:
      return `Download failed: ${error.message}`;
    case ImportErrorCode.codecNotDecodable:
      return `This file uses ${error.codecLabel}, which the bundled FFmpeg can't decode. ${error.reason}`;
  }
}
