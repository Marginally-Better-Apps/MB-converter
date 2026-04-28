import { useEffect, useMemo, useRef, useState } from "react";
import {
  canEncode,
  defaultCodecCapabilities,
  deserializeCodecCapabilities,
  type CodecCapabilitySnapshot
} from "./lib/codecCapabilities";
import { allowedOutputs, defaultOutput, outputFilename } from "./lib/formatMatrix";
import { bytes, bitrateText, dimensionsText, durationText } from "./lib/formatters";
import { createMediaFile } from "./lib/mediaInspector";
import {
  defaultMetadataPolicy,
  manualLockPolicy,
  outputFormatDetails,
  unlockedAutoPolicy,
  type ConversionConfig,
  type ConversionResult,
  type Dimensions,
  type HistoryEntry,
  type MediaFile,
  type OutputFormat,
  type ThemeMode
} from "./lib/models";
import { ffmpegClient } from "./lib/ffmpegClient";
import { targetBytesForFraction, scaledDimensions } from "./lib/bitrate";
import "./styles/app.css";

type Route =
  | { name: "home" }
  | { name: "detail"; media: MediaFile }
  | { name: "processing"; media: MediaFile; config: ConversionConfig }
  | { name: "result"; media: MediaFile; config: ConversionConfig; result: ConversionResult; fromHistory?: boolean }
  | { name: "history" };

type ProgressState = {
  progress: number;
  label: string;
  logs: string[];
  statsPrimary?: string;
  statsDetail?: string;
  error?: string;
};

const maxImportBytes = 2 * 1024 * 1024 * 1024;

export default function App() {
  const [route, setRoute] = useState<Route>({ name: "home" });
  const [themeMode, setThemeMode] = useState<ThemeMode>(() => (localStorage.getItem("appColorMode") as ThemeMode) ?? "system");
  const [capabilities, setCapabilities] = useState<CodecCapabilitySnapshot>(defaultCodecCapabilities);
  const [history, setHistory] = useState<HistoryEntry[]>(() => loadHistory());
  const [lastRun, setLastRun] = useState<{ mediaId: string; config: ConversionConfig; result: ConversionResult } | null>(null);

  useEffect(() => {
    const root = document.documentElement;
    localStorage.setItem("appColorMode", themeMode);
    if (themeMode === "system") {
      root.removeAttribute("data-theme");
    } else {
      root.dataset.theme = themeMode;
    }
  }, [themeMode]);

  useEffect(() => {
    return ffmpegClient.addListener((event) => {
      if (event.type === "capabilities") {
        setCapabilities(deserializeCodecCapabilities(event.capabilities));
      }
    });
  }, []);

  useEffect(() => {
    if (window.crossOriginIsolated) {
      ffmpegClient.load();
    }
  }, []);

  const navigateHome = () => setRoute({ name: "home" });

  return (
    <div className="app-shell">
      <header className="app-header">
        <div className="app-header-inner">
          <button className="brand plain-button" onClick={navigateHome} aria-label="Go home">
            <span className="brand-mark">MB</span>
            <span className="brand-title">MB Converter</span>
          </button>
          <strong>{titleForRoute(route)}</strong>
          <div className="app-header-actions">
            <select
              className="select compact"
              value={themeMode}
              onChange={(event) => setThemeMode(event.target.value as ThemeMode)}
              aria-label="Color theme"
            >
              <option value="system">System</option>
              <option value="light">Light</option>
              <option value="dark">Dark</option>
            </select>
            <button className="button ghost" onClick={() => setRoute({ name: "history" })}>
              History
            </button>
          </div>
        </div>
      </header>

      {route.name === "home" && (
        <HomeScreen
          capabilities={capabilities}
          onCapabilities={setCapabilities}
          onImport={(media) => setRoute({ name: "detail", media })}
        />
      )}
      {route.name === "detail" && (
        <DetailScreen
          media={route.media}
          capabilities={capabilities}
          lastRun={lastRun}
          onBack={navigateHome}
          onConvert={(config) => setRoute({ name: "processing", media: route.media, config })}
          onReuse={(result, config) => setRoute({ name: "result", media: route.media, config, result })}
        />
      )}
      {route.name === "processing" && (
        <ProcessingScreen
          media={route.media}
          config={route.config}
          onCancel={() => setRoute({ name: "detail", media: route.media })}
          onComplete={(result) => {
            setLastRun({ mediaId: route.media.id, config: route.config, result });
            const entry = historyEntry(route.media, result);
            const nextHistory = [entry, ...history].slice(0, 24);
            setHistory(nextHistory);
            saveHistory(nextHistory);
            setRoute({ name: "result", media: route.media, config: route.config, result });
          }}
        />
      )}
      {route.name === "result" && (
        <ResultScreen
          media={route.media}
          config={route.config}
          result={route.result}
          onBack={() => setRoute({ name: "detail", media: route.media })}
          onHome={navigateHome}
        />
      )}
      {route.name === "history" && <HistoryScreen entries={history} onBack={navigateHome} onClear={() => {
        setHistory([]);
        saveHistory([]);
      }} />}
    </div>
  );
}

function HomeScreen({
  capabilities,
  onCapabilities,
  onImport
}: {
  capabilities: CodecCapabilitySnapshot;
  onCapabilities: (value: CodecCapabilitySnapshot) => void;
  onImport: (media: MediaFile) => void;
}) {
  const fileInputRef = useRef<HTMLInputElement>(null);
  const [isImporting, setIsImporting] = useState(false);
  const [error, setError] = useState<string>();
  const [link, setLink] = useState("");

  useEffect(() => {
    return ffmpegClient.addListener((event) => {
      if (event.type === "capabilities") {
        onCapabilities(deserializeCodecCapabilities(event.capabilities));
      }
    });
  }, [onCapabilities]);

  const importFile = async (file: File) => {
    setError(undefined);
    if (file.size > maxImportBytes) {
      setError("This browser version accepts files up to 2 GB, depending on available memory.");
      return;
    }
    setIsImporting(true);
    try {
      const media = await createMediaFile(file);
      onImport(media);
      ffmpegClient.inspect(media);
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    } finally {
      setIsImporting(false);
    }
  };

  const importFromLink = async () => {
    if (!link.trim()) return;
    setIsImporting(true);
    setError(undefined);
    try {
      const response = await fetch(link.trim());
      if (!response.ok) throw new Error(`Download failed: ${response.status}`);
      const blob = await response.blob();
      const name = filenameFromUrl(link) || "download";
      await importFile(new File([blob], name, { type: blob.type }));
      setLink("");
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    } finally {
      setIsImporting(false);
    }
  };

  const paste = async () => {
    setError(undefined);
    try {
      const items = await navigator.clipboard.read();
      for (const item of items) {
        const type = item.types.find((value) => value.startsWith("image/") || value.startsWith("video/") || value.startsWith("audio/"));
        if (type) {
          const blob = await item.getType(type);
          await importFile(new File([blob], `clipboard.${type.split("/")[1] || "bin"}`, { type }));
          return;
        }
      }
      setError("No supported media was found on the clipboard.");
    } catch (err) {
      setError(
        err instanceof Error
          ? err.message
          : "Clipboard import requires browser permission and a secure context."
      );
    }
  };

  return (
    <main
      className="screen screen-narrow stack-large"
      onDragOver={(event) => event.preventDefault()}
      onDrop={(event) => {
        event.preventDefault();
        const file = event.dataTransfer.files.item(0);
        if (file) void importFile(file);
      }}
    >
      <section className="hero card card-pad">
        <p className="eyebrow">Browser-only media conversion</p>
        <h2>Convert and compress locally with FFmpeg WebAssembly.</h2>
        <p className="muted">
          Import from Files, drag and drop, paste from the clipboard, or use a direct link. Your media stays in this browser.
        </p>
      </section>

      <section className="import-grid">
        <button className="import-tile" onClick={() => fileInputRef.current?.click()} disabled={isImporting}>
          <strong>Files</strong>
          <span>Choose video, audio, image, or GIF</span>
        </button>
        <button className="import-tile" onClick={paste} disabled={isImporting}>
          <strong>Paste</strong>
          <span>Read media from clipboard</span>
        </button>
      </section>
      <input
        ref={fileInputRef}
        type="file"
        hidden
        onChange={(event) => {
          const file = event.currentTarget.files?.item(0);
          if (file) void importFile(file);
          event.currentTarget.value = "";
        }}
      />

      <section className="card card-pad stack">
        <label className="form-row">
          <span>Import from link</span>
          <input className="input" value={link} onChange={(event) => setLink(event.target.value)} placeholder="https://example.com/video.webm" />
        </label>
        <button className="button" onClick={importFromLink} disabled={!link.trim() || isImporting}>
          Download
        </button>
      </section>

      <section className="card card-pad stack">
        <div className="split-row">
          <div>
            <p className="eyebrow">FFmpeg backend</p>
            <strong>{capabilities.runtimeLabel}</strong>
            <p className="muted">{capabilities.loaded ? `${capabilities.encoders.size} encoders detected` : "Runtime loads on demand."}</p>
          </div>
          <button className="button secondary" onClick={() => ffmpegClient.load()}>
            Probe FFmpeg
          </button>
        </div>
        <div className="pill-list">
          {["mp4_h264", "webm", "mp3", "ogg", "opus", "webpImage"].map((format) => (
            <span key={format} className="pill">
              {outputFormatDetails[format as OutputFormat].displayName}
              {canEncode(format as OutputFormat, capabilities) ? "" : " unavailable"}
            </span>
          ))}
        </div>
      </section>

      {isImporting && <p className="status">Importing...</p>}
      {error && <p className="error-text">{error}</p>}
    </main>
  );
}

function DetailScreen({
  media,
  capabilities,
  lastResult,
  onBack,
  onConvert,
  onReuse
}: {
  media: MediaFile;
  capabilities: CodecCapabilitySnapshot;
  lastResult: ConversionResult | null;
  onBack: () => void;
  onConvert: (config: ConversionConfig) => void;
  onReuse: (result: ConversionResult, config: ConversionConfig) => void;
}) {
  const formats = useMemo(
    () => allowedOutputs(media.category, { canEncode: (format) => canEncode(format, capabilities) }),
    [media.category, capabilities]
  );
  const [format, setFormat] = useState<OutputFormat>(() => defaultOutput(media.category, { canEncode: (value) => canEncode(value, capabilities) }));
  const [mode, setMode] = useState<"autoTarget" | "manual">("autoTarget");
  const [targetFraction, setTargetFraction] = useState(0.78);
  const [resolution, setResolution] = useState("original");
  const [fps, setFps] = useState("");
  const [singlePass, setSinglePass] = useState(false);
  const [audioKbps, setAudioKbps] = useState("");
  const [webpQuality, setWebpQuality] = useState(0.82);
  const [stripMetadata, setStripMetadata] = useState(true);
  const [crop, setCrop] = useState(false);
  const [cropRegion, setCropRegion] = useState(() =>
    media.dimensions ? { x: 0, y: 0, width: media.dimensions.width, height: media.dimensions.height } : undefined
  );

  useEffect(() => {
    if (!formats.includes(format) && formats[0]) {
      setFormat(formats[0]);
    }
  }, [formats, format]);

  const config = useMemo<ConversionConfig>(() => {
    const targetDimensions = resolveDimensions(media.dimensions, resolution);
    const detail = outputFormatDetails[format];
    return {
      outputFormat: format,
      targetDimensions,
      targetFPS: fps ? Number(fps) : undefined,
      targetSizeBytes:
        detail.supportsTargetSize && mode === "autoTarget"
          ? targetBytesForFraction(media.sizeOnDisk, targetFraction)
          : undefined,
      cropRegion: crop ? cropRegion : undefined,
      imageQuality: format === "webpImage" || format === "jpg" ? webpQuality : undefined,
      videoQuality: detail.category === "video" ? targetFraction : undefined,
      usesSinglePassVideoTargetEncode: singlePass,
      frameTimeForExtraction: frameTime ? Number(frameTime) : undefined,
      preferredAudioBitrateKbps: audioKbps ? Number(audioKbps) : undefined,
      operationMode: mode,
      autoTargetLockPolicy: mode === "autoTarget" ? unlockedAutoPolicy : manualLockPolicy,
      prefersRemuxWhenPossible: targetFraction >= 0.999,
      metadata: { ...defaultMetadataPolicy, stripAll: stripMetadata }
    };
  }, [audioKbps, crop, cropRegion, format, fps, frameTime, media.dimensions, media.sizeOnDisk, mode, resolution, singlePass, stripMetadata, targetFraction, webpQuality]);

  const matchingCachedResult = lastResult?.outputFormat === config.outputFormat;
  const currentOutputName = outputFilename(media.originalFilename, format);

  return (
    <main className="screen stack-large">
      <button className="button ghost fit" onClick={onBack}>Back</button>
      <section className="two-column">
        <div className="card card-pad stack">
          <MediaPreview media={media} />
          <MetadataSummary media={media} />
        </div>
        <div className="card card-pad stack">
          <p className="eyebrow">Output</p>
          <label className="form-row">
            <span>Format</span>
            <select className="select" value={format} onChange={(event) => setFormat(event.target.value as OutputFormat)}>
              {formats.map((value) => (
                <option key={value} value={value}>{outputFormatDetails[value].displayName}</option>
              ))}
            </select>
          </label>
          <label className="form-row">
            <span>Mode</span>
            <select className="select" value={mode} onChange={(event) => setMode(event.target.value as "autoTarget" | "manual")}>
              <option value="autoTarget">Auto</option>
              <option value="manual">Manual</option>
            </select>
          </label>
          {outputFormatDetails[format].supportsTargetSize && (
            <label className="form-row">
              <span>Target size: {bytes(targetBytesForFraction(media.sizeOnDisk, targetFraction))}</span>
              <input className="range" type="range" min="0.05" max="1" step="0.01" value={targetFraction} onChange={(event) => setTargetFraction(Number(event.target.value))} />
            </label>
          )}
          {media.dimensions && outputFormatDetails[format].category !== "audio" && (
            <label className="form-row">
              <span>Resolution</span>
              <select className="select" value={resolution} onChange={(event) => setResolution(event.target.value)}>
                <option value="original">Original</option>
                <option value="1080">1080p</option>
                <option value="720">720p</option>
                <option value="480">480p</option>
                <option value="360">360p</option>
              </select>
            </label>
          )}
          {outputFormatDetails[format].category === "video" && (
            <>
              <label className="form-row">
                <span>Frame rate</span>
                <select className="select" value={fps} onChange={(event) => setFps(event.target.value)}>
                  <option value="">Original</option>
                  <option value="60">60 fps</option>
                  <option value="30">30 fps</option>
                  <option value="24">24 fps</option>
                  <option value="15">15 fps</option>
                </select>
              </label>
              <label className="check-row">
                <input type="checkbox" checked={singlePass} onChange={(event) => setSinglePass(event.target.checked)} />
                Single-pass target encode
              </label>
            </>
          )}
          {media.category === "video" && outputFormatDetails[format].category === "image" && (
            <label className="form-row">
              <span>Frame time (seconds)</span>
              <input
                className="input"
                type="number"
                min="0"
                max={media.duration ?? undefined}
                step="0.1"
                value={frameTime}
                onChange={(event) => setFrameTime(event.target.value)}
                placeholder="0"
              />
            </label>
          )}
          {media.category === "video" && outputFormatDetails[format].category === "video" && (
            <label className="form-row">
              <span>Audio quality</span>
              <select className="select" value={audioKbps} onChange={(event) => setAudioKbps(event.target.value)}>
                <option value="">Original / auto</option>
                <option value="192">192 kbps</option>
                <option value="160">160 kbps</option>
                <option value="128">128 kbps</option>
                <option value="96">96 kbps</option>
                <option value="64">64 kbps</option>
              </select>
            </label>
          )}
          {(format === "webpImage" || format === "jpg") && (
            <label className="form-row">
              <span>Image quality: {Math.round(webpQuality * 100)}%</span>
              <input className="range" type="range" min="0.2" max="1" step="0.01" value={webpQuality} onChange={(event) => setWebpQuality(Number(event.target.value))} />
            </label>
          )}
          {media.dimensions && outputFormatDetails[format].category !== "audio" && (
            <label className="check-row">
              <input type="checkbox" checked={crop} onChange={(event) => setCrop(event.target.checked)} />
              Enable crop controls (full-frame default)
            </label>
          )}
          {crop && cropRegion && media.dimensions && (
            <fieldset className="crop-controls">
              <legend>Crop rectangle</legend>
              {(["x", "y", "width", "height"] as const).map((key) => (
                <label key={key} className="form-row">
                  <span>{key.toUpperCase()}</span>
                  <input
                    className="input"
                    type="number"
                    min="0"
                    max={key === "x" || key === "width" ? media.dimensions?.width : media.dimensions?.height}
                    value={Math.round(cropRegion[key])}
                    onChange={(event) => {
                      const value = Math.max(0, Number(event.target.value));
                      setCropRegion((current) => current ? { ...current, [key]: value } : current);
                    }}
                  />
                </label>
              ))}
              <button
                type="button"
                className="button ghost fit"
                onClick={() => {
                  setCropRegion(
                    media.dimensions
                      ? { x: 0, y: 0, width: media.dimensions.width, height: media.dimensions.height }
                      : undefined
                  );
                }}
              >
                Reset crop
              </button>
            </fieldset>
          )}
          <section className="metadata-card">
            <div className="split-row">
              <div>
                <strong>Output metadata</strong>
                <p className="muted">Container, stream, and image tags can be stripped before the output is written.</p>
              </div>
            </div>
          </section>
          <label className="check-row">
            <input type="checkbox" checked={stripMetadata} onChange={(event) => setStripMetadata(event.target.checked)} />
            Strip metadata
          </label>
          <p className="muted">Output: {currentOutputName}</p>
          <div className="split-row">
            <button className="button" onClick={() => onConvert(config)}>Convert</button>
            {matchingCachedResult && lastResult && (
              <button className="button secondary" onClick={() => onReuse(lastResult, config)}>Use cached result</button>
            )}
          </div>
        </div>
      </section>
    </main>
  );
}

function ProcessingScreen({
  media,
  config,
  onCancel,
  onComplete
}: {
  media: MediaFile;
  config: ConversionConfig;
  onCancel: () => void;
  onComplete: (result: ConversionResult) => void;
}) {
  const [state, setState] = useState<ProgressState>({ progress: 0, label: "Preparing...", logs: [] });

  useEffect(() => {
    const remove = ffmpegClient.addListener((event) => {
      if (event.type === "progress") {
        setState((prev) => ({ ...prev, progress: Math.max(prev.progress, event.progress), label: progressLabel(event.progress, config), statsPrimary: event.stats ? statsPrimary(event.stats) : prev.statsPrimary, statsDetail: event.stats ? statsDetail(event.stats) : prev.statsDetail }));
      } else if (event.type === "stats") {
        setState((prev) => ({ ...prev, statsPrimary: statsPrimary(event.stats), statsDetail: statsDetail(event.stats) }));
      } else if (event.type === "log") {
        setState((prev) => ({ ...prev, logs: [...prev.logs.slice(-80), event.message] }));
      } else if (event.type === "converted") {
        onComplete({ ...event.result, objectUrl: URL.createObjectURL(event.result.blob) });
      } else if (event.type === "error") {
        setState((prev) => ({ ...prev, error: event.message, label: "Conversion failed" }));
      } else if (event.type === "cancelled") {
        onCancel();
      }
    });
    ffmpegClient.convert(media, config);
    return remove;
  }, [config, media, onCancel, onComplete]);

  return (
    <main className="screen screen-narrow stack-large">
      <section className="card card-pad stack">
        <p className="eyebrow">Processing</p>
        <h2>{state.label}</h2>
        <div className="progress-track" style={{ "--progress": state.progress } as React.CSSProperties}>
          <div className="progress-fill" />
        </div>
        <strong>{Math.round(state.progress * 100)}%</strong>
        {state.statsPrimary && <p>{state.statsPrimary}</p>}
        {state.statsDetail && <p className="muted">{state.statsDetail}</p>}
        {state.error ? (
          <>
            <p className="error-text">{state.error}</p>
            <button className="button secondary" onClick={() => ffmpegClient.convert(media, config)}>Retry</button>
          </>
        ) : (
          <button className="button danger" onClick={() => ffmpegClient.cancel()}>Cancel</button>
        )}
        <pre className="log-box">{state.logs.join("\n") || "FFmpeg logs will appear here."}</pre>
      </section>
    </main>
  );
}

function ResultScreen({
  media,
  result,
  onBack,
  onHome
}: {
  media: MediaFile;
  config: ConversionConfig;
  result: ConversionResult;
  onBack: () => void;
  onHome: () => void;
}) {
  const [name, setName] = useState(result.filename.replace(/\.[^.]+$/, ""));
  const filename = `${sanitizeBaseName(name)}.${outputFormatDetails[result.outputFormat].fileExtension}`;

  const share = async () => {
    const file = new File([result.blob], filename, { type: result.blob.type });
    if (navigator.canShare?.({ files: [file] })) {
      await navigator.share({ files: [file], title: filename });
    } else {
      await navigator.clipboard.writeText(result.objectUrl);
    }
  };

  return (
    <main className="screen stack-large">
      <button className="button ghost fit" onClick={onBack}>Back to config</button>
      <section className="two-column">
        <div className="card card-pad stack">
          <ResultPreview result={result} />
        </div>
        <div className="card card-pad stack">
          <p className="eyebrow">Result</p>
          <h2>{bytes(media.sizeOnDisk)} → {bytes(result.sizeOnDisk)}</h2>
          <label className="form-row">
            <span>Filename</span>
            <input className="input" value={name} onChange={(event) => setName(event.target.value)} />
          </label>
          <MetadataSummary media={{ ...media, ...result, sizeOnDisk: result.sizeOnDisk, originalFilename: filename }} />
          <div className="split-row">
            <a className="button" href={result.objectUrl} download={filename}>Download</a>
            <button className="button secondary" onClick={() => void share()}>Share / copy</button>
            <button className="button ghost" onClick={onHome}>Convert another</button>
          </div>
        </div>
      </section>
    </main>
  );
}

function HistoryScreen({ entries, onBack, onClear }: { entries: HistoryEntry[]; onBack: () => void; onClear: () => void }) {
  return (
    <main className="screen screen-narrow stack">
      <div className="split-row">
        <button className="button ghost" onClick={onBack}>Back</button>
        <button className="button danger" onClick={onClear} disabled={!entries.length}>Clear</button>
      </div>
      <section className="card card-pad stack">
        <p className="eyebrow">Conversion history</p>
        {entries.length === 0 ? (
          <p className="muted">History is stored locally in this browser after conversions complete.</p>
        ) : (
          entries.map((entry) => (
            <div className="history-row surface" key={entry.id}>
              <strong>{entry.outputName}</strong>
              <span className="muted">{entry.inputName} · {bytes(entry.inputSize)} → {bytes(entry.outputSize)}</span>
              <span>{new Date(entry.completedAt).toLocaleString()}</span>
            </div>
          ))
        )}
      </section>
    </main>
  );
}

function MediaPreview({ media }: { media: MediaFile }) {
  if (media.category === "image") {
    return <div className="preview-box"><img src={media.objectUrl} alt={media.originalFilename} /></div>;
  }
  if (media.category === "animatedImage") {
    return <div className="preview-box"><video src={media.objectUrl} controls loop muted /></div>;
  }
  if (media.category === "audio") {
    return <div className="preview-box"><audio src={media.objectUrl} controls /></div>;
  }
  return <div className="preview-box"><video src={media.objectUrl} controls /></div>;
}

function ResultPreview({ result }: { result: ConversionResult }) {
  const category = outputFormatDetails[result.outputFormat].category;
  if (category === "image" || category === "animatedImage") return <div className="preview-box"><img src={result.objectUrl} alt={result.filename} /></div>;
  if (category === "audio") return <div className="preview-box"><audio src={result.objectUrl} controls /></div>;
  return <div className="preview-box"><video src={result.objectUrl} controls /></div>;
}

function MetadataSummary({ media }: { media: Partial<MediaFile | ConversionResult> & { originalFilename?: string; sizeOnDisk: number } }) {
  return (
    <dl className="stat-grid">
      <div className="stat surface"><dt>Name</dt><dd>{media.originalFilename ?? "Converted"}</dd></div>
      <div className="stat surface"><dt>Size</dt><dd>{bytes(media.sizeOnDisk)}</dd></div>
      <div className="stat surface"><dt>Dimensions</dt><dd>{dimensionsText(media.dimensions as Dimensions | undefined)}</dd></div>
      <div className="stat surface"><dt>Duration</dt><dd>{durationText(media.duration)}</dd></div>
      <div className="stat surface"><dt>Bitrate</dt><dd>{bitrateText(media.bitrate)}</dd></div>
      <div className="stat surface"><dt>Codecs</dt><dd>{[media.videoCodec, media.audioCodec].filter(Boolean).join(" / ") || "Unknown"}</dd></div>
    </dl>
  );
}

function resolveDimensions(source: Dimensions | undefined, preset: string): Dimensions | undefined {
  if (!source || preset === "original") return undefined;
  return scaledDimensions(source, Number(preset));
}

function progressLabel(progress: number, config: ConversionConfig): string {
  if (progress >= 1) return "Finishing...";
  if (outputFormatDetails[config.outputFormat].category === "video" && !config.usesSinglePassVideoTargetEncode) {
    return progress < 0.45 ? "Analyzing..." : "Encoding...";
  }
  return "Converting...";
}

function statsPrimary(stats: { frame?: number; fps?: number; speed?: string }): string {
  return [
    stats.frame ? `Frame ${stats.frame}` : undefined,
    stats.fps ? `FFmpeg ${stats.fps.toFixed(1)} fps` : undefined,
    stats.speed ? `Speed ${stats.speed}` : undefined
  ].filter(Boolean).join(" · ");
}

function statsDetail(stats: { time?: string; encodedSize?: string; throughputBitrate?: string }): string {
  return [
    stats.time ? `Time ${stats.time}` : undefined,
    stats.encodedSize ? `Output ${stats.encodedSize}` : undefined,
    stats.throughputBitrate ? `Bitrate ${stats.throughputBitrate}` : undefined
  ].filter(Boolean).join(" · ");
}

function historyEntry(input: MediaFile, result: ConversionResult): HistoryEntry {
  return {
    id: result.id,
    inputName: input.originalFilename,
    outputName: result.filename,
    inputSize: input.sizeOnDisk,
    outputSize: result.sizeOnDisk,
    outputFormat: result.outputFormat,
    completedAt: result.completedAt
  };
}

function loadHistory(): HistoryEntry[] {
  try {
    const value = localStorage.getItem("conversionHistory");
    return value ? JSON.parse(value) as HistoryEntry[] : [];
  } catch {
    return [];
  }
}

function saveHistory(entries: HistoryEntry[]) {
  localStorage.setItem("conversionHistory", JSON.stringify(entries));
}

function titleForRoute(route: Route): string {
  switch (route.name) {
    case "home":
      return "Import";
    case "detail":
      return "Convert";
    case "processing":
      return "Processing";
    case "result":
      return "Result";
    case "history":
      return "History";
  }
}

function filenameFromUrl(value: string): string | undefined {
  try {
    const url = new URL(value);
    return decodeURIComponent(url.pathname.split("/").filter(Boolean).pop() ?? "");
  } catch {
    return undefined;
  }
}

function sanitizeBaseName(value: string): string {
  return value.trim().replace(/[/:]/g, "-") || "converted";
}
