import { NativeModule } from 'expo';

import type { ImageEncodeParams, ImageEncodeResult } from './ImageEncodeModule.types';

class ImageEncodeModuleWeb extends NativeModule {
  async encode(_params: ImageEncodeParams): Promise<ImageEncodeResult> {
    throw new Error('ImageEncodeModule is iOS-only and unavailable on web.');
  }
}

export default new ImageEncodeModuleWeb();
