import { FFmpeg } from "@ffmpeg/ffmpeg";
import { fetchFile } from "@ffmpeg/util";
import type { FileData } from "@ffmpeg/ffmpeg";
import {
  FfmpegWorkerRequest,
  FfmpegWorkerResponse,
  FfmpegWorkerResponseByType,
  SerializableMediaFile,
  SerializableWorkerConversionJob,
  WorkerConversionJob,
  workerMediaToMediaFile
} from "./ffmpegMessages";
import { mimeTypeForFormat, outputFilename } from "./formatMatrix";
import { buildConversionPlan } from "./converters";
import { parseFfmpegList } from "./codecCapabilities";
import {
  EncodingDisplayStats,
  parseDurationFromProbe,
  parseProgressLine,
  parseStreamMetadata
} from "./progress";
import { outputFormatDetails } from "./models";

const assetUrl = (path: string) => new URL(`${import.meta.env.BASE_URL}${path}`, self.location.origin).href;

const coreMtUrl = assetUrl("ffmpeg/core-mt/ffmpeg-core.js");
const coreMtWasmUrl = assetUrl("ffmpeg/core-mt/ffmpeg-core.wasm");
const coreMtWorkerUrl = assetUrl("ffmpeg/core-mt/ffmpeg-core.worker.js");
const coreUrl = assetUrl("ffmpeg/core/ffmpeg-core.js");
const coreWasmUrl = assetUrl("ffmpeg/core/ffmpeg-core.wasm");
const classWorkerURL = assetUrl("ffmpeg/worker/worker.js");

let ffmpeg: FFmpeg | null = null;
let activeAbortController: AbortController | null = null;
let loadedThreaded = false;
let lastLogs: string[] = [];

const post = <T extends FfmpegWorkerResponse["type"]>(
  response: FfmpegWorkerResponseByType<T>
) => {
  self.postMessage(response);
};

const captureLog = (message: string) => {
  const line = message.trim();
  if (!line) return;
  lastLogs.push(line);
  if (lastLogs.length > 180) {
    lastLogs = lastLogs.slice(-180);
  }
  post({ type: "log", message: line });
  const stats = parseProgressLine(line);
  if (stats) {
    post({ type: "stats", stats });
  }
};

async function ensureLoaded(preferThreaded = true): Promise<FFmpeg> {
  if (ffmpeg?.loaded) {
    return ffmpeg;
  }

  ffmpeg = new FFmpeg();
  ffmpeg.on("log", ({ message }) => captureLog(message));
  ffmpeg.on("progress", ({ progress, time }) => {
    if (Number.isFinite(progress)) {
      post({ type: "progress", progress: Math.max(0, Math.min(1, progress)), time });
    }
  });

  loadedThreaded = preferThreaded && self.crossOriginIsolated;
  await ffmpeg.load(
    loadedThreaded
      ? { coreURL: coreMtUrl, wasmURL: coreMtWasmUrl, workerURL: coreMtWorkerUrl, classWorkerURL }
      : { coreURL: coreUrl, wasmURL: coreWasmUrl, classWorkerURL }
  );
  return ffmpeg;
}

async function probeRuntime() {
  const instance = await ensureLoaded(true);
  const probes = await Promise.all([
    collectCommandOutput(instance, ["-hide_banner", "-encoders"]),
    collectCommandOutput(instance, ["-hide_banner", "-decoders"]),
    collectCommandOutput(instance, ["-hide_banner", "-muxers"]),
    collectCommandOutput(instance, ["-hide_banner", "-demuxers"]),
    collectCommandOutput(instance, ["-hide_banner", "-version"])
  ]);

  post({
    type: "capabilities",
    capabilities: {
      loaded: true,
      runtimeLabel: `${loadedThreaded ? "ffmpeg.wasm core-mt" : "ffmpeg.wasm core"}${versionLine(
        probes[4]
      )}`,
      encoders: [...parseFfmpegList(probes[0])],
      decoders: [...parseFfmpegList(probes[1])],
      muxers: [...parseFfmpegList(probes[2])],
      demuxers: [...parseFfmpegList(probes[3])]
    }
  });
}

async function loadOnly(preferThreaded = true) {
  await ensureLoaded(preferThreaded);
  post({
    type: "capabilities",
    capabilities: {
      loaded: true,
      runtimeLabel: loadedThreaded ? "ffmpeg.wasm core-mt" : "ffmpeg.wasm core",
      encoders: [],
      decoders: [],
      muxers: [],
      demuxers: []
    }
  });
}

async function collectCommandOutput(instance: FFmpeg, args: string[]): Promise<string> {
  const lines: string[] = [];
  const handler = ({ message }: { message: string }) => {
    lines.push(message);
  };
  instance.on("log", handler);
  try {
    await instance.exec(args, undefined, { signal: activeAbortController?.signal });
  } catch {
    // Listing commands can return non-zero on some builds while still emitting useful text.
  } finally {
    instance.off("log", handler);
  }
  return lines.join("\n");
}

function versionLine(output: string): string {
  const line = output.split(/\r?\n/).find((value) => value.toLowerCase().startsWith("ffmpeg version"));
  return line ? ` (${line.replace(/^ffmpeg version\s+/i, "").split(/\s+/)[0]})` : "";
}

async function inspectMedia(media: SerializableMediaFile) {
  const instance = await ensureLoaded(true);
  const inputPath = `/input-${media.id}.${media.containerFormat || "bin"}`;
  const outputPath = `/probe-${media.id}.json`;
  lastLogs = [];
  await instance.writeFile(inputPath, await fetchFile(media.file));
  const args = [
    "-v",
    "quiet",
    "-print_format",
    "json",
    "-show_format",
    "-show_streams",
    inputPath,
    "-o",
    outputPath
  ];
  const code = await instance.ffprobe(args, undefined, { signal: activeAbortController?.signal });
  if (code !== 0) {
    throw new Error("FFprobe could not inspect this file.");
  }
  const data = await instance.readFile(outputPath, "utf8");
  const probeText = typeof data === "string" ? data : new TextDecoder().decode(data as Uint8Array);
  await cleanupFiles(instance, [inputPath, outputPath]);
  const parsed = JSON.parse(probeText) as unknown;
  const metadata = parseStreamMetadata(parsed);
  post({
    type: "inspected",
    media: {
      ...media,
      ...metadata
    }
  });
}

async function convert(job: SerializableWorkerConversionJob) {
  const instance = await ensureLoaded(true);
  const media = workerMediaToMediaFile(job.input);
  const fullJob: WorkerConversionJob = {
    input: media,
    config: job.config
  };
  const plan = buildConversionPlan(fullJob);
  const inputPath = `/input-${media.id}.${media.containerFormat || "bin"}`;
  const outputPath = `/output-${media.id}.${outputFormatDetails[job.config.outputFormat].fileExtension}`;
  const cleanup = [inputPath, outputPath, ...plan.cleanupPaths];

  await instance.writeFile(inputPath, await fetchFile(job.input.file));
  const startedAt = performance.now();
  const duration = media.duration;

  const runStep = async (stepIndex: number, args: string[], weightStart: number, weight: number) => {
    const handler = ({ message }: { message: string }) => {
      const stats = parseProgressLine(message);
      if (stats) {
        reportStepProgress(stats, duration, weightStart, weight);
      }
    };
    instance.on("log", handler);
    try {
      const code = await instance.exec(argsWithThreadHint(args), undefined, {
        signal: activeAbortController?.signal
      });
      if (code !== 0) {
        throw new Error(`FFmpeg exited with code ${code}`);
      }
      post({ type: "progress", progress: Math.min(1, weightStart + weight) });
    } finally {
      instance.off("log", handler);
      post({ type: "log", message: `Finished ${plan.steps[stepIndex]?.label ?? "step"}.` });
    }
  };

  try {
    post({ type: "log", message: `Using ${loadedThreaded ? "multi-thread" : "single-thread"} FFmpeg core.` });
    for (let index = 0; index < plan.steps.length; index += 1) {
      const step = plan.steps[index];
      post({ type: "log", message: step.label });
      await runStep(index, step.args(inputPath, outputPath), step.progressStart, step.progressWeight);
    }
    const output = await instance.readFile(outputPath);
    const bytes = toUint8Array(output);
    const outputBuffer = new ArrayBuffer(bytes.byteLength);
    new Uint8Array(outputBuffer).set(bytes);
    const blob = new Blob([outputBuffer], {
      type: mimeTypeForFormat(job.config.outputFormat)
    });
    const resultMetadata = await inspectResult(instance, outputPath);
    post({
      type: "converted",
      result: {
        id: crypto.randomUUID(),
        blob,
        outputFormat: job.config.outputFormat,
        filename: outputFilename(media.originalFilename, job.config.outputFormat),
        sizeOnDisk: blob.size,
        completedAt: Date.now(),
        ...resultMetadata
      }
    });
    post({ type: "log", message: `Completed in ${Math.round((performance.now() - startedAt) / 1000)}s.` });
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    post({ type: "error", message: `${message}${lastUsefulLogSuffix()}` });
  } finally {
    await cleanupFiles(instance, cleanup);
    activeAbortController = null;
  }
}

async function inspectResult(instance: FFmpeg, outputPath: string) {
  const probePath = `${outputPath}.json`;
  try {
    const code = await instance.ffprobe(
      [
        "-v",
        "quiet",
        "-print_format",
        "json",
        "-show_format",
        "-show_streams",
        outputPath,
        "-o",
        probePath
      ],
      undefined,
      { signal: activeAbortController?.signal }
    );
    if (code !== 0) return {};
    const data = await instance.readFile(probePath, "utf8");
    const probeText = typeof data === "string" ? data : new TextDecoder().decode(data as Uint8Array);
    return parseStreamMetadata(JSON.parse(probeText) as unknown);
  } catch {
    return {};
  } finally {
    await cleanupFiles(instance, [probePath]);
  }
}

function reportStepProgress(
  stats: EncodingDisplayStats,
  duration: number | undefined,
  weightStart: number,
  weight: number
) {
  const statDuration = stats.timeMilliseconds ? stats.timeMilliseconds / 1000 : undefined;
  const knownDuration = duration ?? parseDurationFromProbe(lastLogs.join("\n"));
  if (!knownDuration || !statDuration) return;
  const local = Math.min(1, Math.max(0, statDuration / knownDuration));
  post({ type: "progress", progress: weightStart + local * weight, stats });
}

function toUint8Array(data: FileData): Uint8Array {
  if (typeof data === "string") {
    return new TextEncoder().encode(data);
  }
  return data;
}

function argsWithThreadHint(args: string[]): string[] {
  if (!loadedThreaded || args.includes("-threads")) {
    return args;
  }
  const inputIndex = args.indexOf("-i");
  if (inputIndex < 0) {
    return ["-threads", "2", ...args];
  }
  return [...args.slice(0, inputIndex), "-threads", "2", ...args.slice(inputIndex)];
}

async function cleanupFiles(instance: FFmpeg, paths: string[]) {
  await Promise.allSettled(paths.map((path) => instance.deleteFile(path)));
}

function lastUsefulLogSuffix(): string {
  const useful = [...lastLogs]
    .reverse()
    .find((line) => /error|failed|unknown|invalid|could not|not found/i.test(line));
  return useful ? `: ${useful}` : "";
}

self.addEventListener("message", (event: MessageEvent<FfmpegWorkerRequest>) => {
  void (async () => {
    try {
      const request = event.data;
      switch (request.type) {
        case "load":
          activeAbortController = new AbortController();
          await probeRuntime();
          activeAbortController = null;
          break;
        case "inspect":
          activeAbortController = new AbortController();
          await inspectMedia(request.media);
          activeAbortController = null;
          break;
        case "convert":
          activeAbortController = new AbortController();
          await convert(request.job);
          break;
        case "cancel":
          activeAbortController?.abort();
          ffmpeg?.terminate();
          ffmpeg = null;
          activeAbortController = null;
          post({ type: "cancelled" });
          break;
      }
    } catch (error) {
      activeAbortController = null;
      post({ type: "error", message: error instanceof Error ? error.message : String(error) });
    }
  })();
});
