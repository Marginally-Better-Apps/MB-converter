import { describe, expect, it } from "vitest";
import { allowedOutputs, detectCategory, outputFilename } from "./formatMatrix";
import { canEncode, defaultCodecCapabilities, parseFfmpegList } from "./codecCapabilities";

describe("format matrix", () => {
  it("detects broad browser input categories", () => {
    expect(detectCategory("clip.mkv")).toBe("video");
    expect(detectCategory("voice.opus")).toBe("audio");
    expect(detectCategory("photo.avif")).toBe("image");
    expect(detectCategory("loop.gif")).toBe("animatedImage");
  });

  it("exposes expanded browser outputs through codec capabilities", () => {
    const outputs = allowedOutputs("video", {
      canEncode: (format) => canEncode(format, defaultCodecCapabilities)
    });
    expect(outputs).toContain("webm");
    expect(outputs).toContain("mp3");
    expect(outputs).toContain("opus");
  });

  it("sanitizes generated output filenames", () => {
    expect(outputFilename("folder:bad/name.mov", "mp4_h264")).toBe("name.mp4");
  });
});

describe("ffmpeg list parsing", () => {
  it("parses codec names from ffmpeg -encoders output", () => {
    const output = [
      " V..... libx264              libx264 H.264 / AVC / MPEG-4 AVC",
      " A..... libmp3lame           libmp3lame MP3",
      " ------"
    ].join("\n");
    expect([...parseFfmpegList(output)]).toEqual(["libx264", "libmp3lame"]);
  });
});
