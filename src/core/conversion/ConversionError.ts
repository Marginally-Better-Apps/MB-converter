export type ConversionErrorCode =
  | 'unsupportedConversion'
  | 'invalidInput'
  | 'engineFailed'
  | 'cancelled'
  | 'targetUnreachable'
  | 'codecUnavailable';

export class ConversionError extends Error {
  readonly code: ConversionErrorCode;
  readonly reason?: string;

  constructor(code: ConversionErrorCode, message?: string, reason?: string) {
    super(message ?? defaultMessage(code, reason));
    this.name = 'ConversionError';
    this.code = code;
    this.reason = reason;
  }

  static unsupported(): ConversionError {
    return new ConversionError('unsupportedConversion');
  }

  static cancelled(): ConversionError {
    return new ConversionError('cancelled');
  }

  static engineFailed(detail: string): ConversionError {
    return new ConversionError('engineFailed', `Conversion failed: ${detail}`);
  }

  static invalidInput(detail: string): ConversionError {
    return new ConversionError('invalidInput', `Invalid input: ${detail}`);
  }

  static codecUnavailable(reason: string): ConversionError {
    return new ConversionError('codecUnavailable', `Codec unavailable: ${reason}`, reason);
  }
}

function defaultMessage(code: ConversionErrorCode, reason?: string): string {
  switch (code) {
    case 'unsupportedConversion':
      return "This conversion isn't supported.";
    case 'invalidInput':
      return 'Invalid input.';
    case 'engineFailed':
      return 'Conversion failed.';
    case 'cancelled':
      return 'Cancelled.';
    case 'targetUnreachable':
      return "Couldn't hit the target size with the chosen settings.";
    case 'codecUnavailable':
      return reason ? `Codec unavailable: ${reason}` : 'Codec unavailable.';
  }
}

export function isConversionError(error: unknown): error is ConversionError {
  return error instanceof ConversionError;
}
