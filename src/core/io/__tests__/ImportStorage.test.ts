import {
  importFilename,
  importsDirectoryName,
} from '@/src/core/io/ImportStorage';

describe('ImportStorage helpers', () => {
  it('uses a dedicated imports directory name', () => {
    expect(importsDirectoryName).toBe('imports');
  });

  it('builds a unique filename from original name or fallback extension', () => {
    const withOriginal = importFilename({
      originalName: 'Vacation.MOV',
      fallbackExtension: 'dat',
      id: 'abc-123',
    });
    expect(withOriginal).toBe('abc-123.MOV');

    const withFallback = importFilename({
      originalName: null,
      fallbackExtension: 'png',
      id: 'xyz',
    });
    expect(withFallback).toBe('xyz.png');

    const emptyExt = importFilename({
      originalName: 'noext',
      fallbackExtension: 'mp4',
      id: 'id1',
    });
    expect(emptyExt).toBe('id1.mp4');
  });
});
