export type ImageEncodeFormat = 'jpg' | 'png' | 'heic' | 'tiff' | 'webpImage';

export type ImageEncodeCrop = {
  x: number;
  y: number;
  width: number;
  height: number;
};

export type ImageEncodeMetadata = {
  stripAll?: boolean;
};

export type ImageEncodeParams = {
  uri: string;
  format: ImageEncodeFormat | string;
  quality: number;
  outputUri: string;
  crop?: ImageEncodeCrop;
  maxPixel?: number;
  metadata?: ImageEncodeMetadata;
};

export type ImageEncodeResult = {
  outputUri: string;
  byteSize: number;
  width: number;
  height: number;
};
