import fs from 'fs';
import path from 'path';

describe('fixtures/media/tiny.mp4', () => {
  it('is a real ISO BMFF MP4 with an ftyp box', () => {
    const fixturePath = path.join(__dirname, '../../../../fixtures/media/tiny.mp4');
    const buf = fs.readFileSync(fixturePath);

    expect(buf.byteLength).toBeGreaterThan(1000);
    expect(buf.subarray(4, 8).toString('ascii')).toBe('ftyp');
  });
});
