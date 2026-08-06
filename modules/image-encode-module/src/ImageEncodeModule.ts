import { NativeModule, requireNativeModule } from 'expo';

import type { ImageEncodeParams, ImageEncodeResult } from './ImageEncodeModule.types';

declare class ImageEncodeModuleNative extends NativeModule {
  encode(params: ImageEncodeParams): Promise<ImageEncodeResult>;
}

export default requireNativeModule<ImageEncodeModuleNative>('ImageEncodeModule');
