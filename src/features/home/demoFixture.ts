import { Asset } from 'expo-asset';
import { Directory, File, Paths } from 'expo-file-system';

import type { ImportedMedia } from '@/src/core/io/ImportService';

/**
 * Copies the bundled tiny.mp4 fixture into cache so Maestro / Simulator demos
 * can reach import-detail → convert/config without photo-library permissions.
 * tiny.mp4 is a small real H.264/AAC MP4 (ISO BMFF with ftyp) suitable for path
 * smoke and light encode demos.
 */
export async function loadDemoFixtureMedia(): Promise<ImportedMedia> {
  const asset = Asset.fromModule(require('../../../fixtures/media/tiny.mp4'));
  await asset.downloadAsync();
  const localUri = asset.localUri ?? asset.uri;
  if (!localUri) {
    throw new Error('Demo fixture asset is unavailable.');
  }

  const dir = new Directory(Paths.cache, 'imports');
  if (!dir.exists) {
    dir.create();
  }
  const dest = new File(dir, 'demo-sample.mp4');
  const source = new File(localUri);
  await source.copy(dest, { overwrite: true });

  return {
    uri: dest.uri,
    filename: 'demo-sample.mp4',
    category: 'video',
    byteSize: dest.size ?? 40,
  };
}
