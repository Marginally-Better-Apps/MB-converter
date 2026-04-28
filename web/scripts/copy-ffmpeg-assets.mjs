import { copyFile, mkdir } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = dirname(fileURLToPath(import.meta.url));
const webRoot = join(root, "..");
const publicDir = join(webRoot, "public", "ffmpeg");
const nodeModules = join(webRoot, "node_modules", "@ffmpeg");

const assets = [
  ["core/dist/esm/ffmpeg-core.js", "core/ffmpeg-core.js"],
  ["core/dist/esm/ffmpeg-core.wasm", "core/ffmpeg-core.wasm"],
  ["core-mt/dist/esm/ffmpeg-core.js", "core-mt/ffmpeg-core.js"],
  ["core-mt/dist/esm/ffmpeg-core.wasm", "core-mt/ffmpeg-core.wasm"],
  ["core-mt/dist/esm/ffmpeg-core.worker.js", "core-mt/ffmpeg-core.worker.js"],
  ["ffmpeg/dist/esm/worker.js", "worker/worker.js"],
  ["ffmpeg/dist/esm/const.js", "worker/const.js"],
  ["ffmpeg/dist/esm/errors.js", "worker/errors.js"]
];

await Promise.all(
  assets.map(async ([source, destination]) => {
    const target = join(publicDir, destination);
    await mkdir(dirname(target), { recursive: true });
    await copyFile(join(nodeModules, source), target);
  })
);
