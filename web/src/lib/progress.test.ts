import { describe, expect, it } from "vitest";
import { parseEncodingStats, parseStreamMetadata, progressFromStats } from "./progress";

describe("progress helpers", () => {
  it("parses FFmpeg progress lines", () => {
    const stats = parseEncodingStats("frame=  120 fps=28.4 size=1024kB time=00:00:04.50 bitrate=1864.2kbits/s speed=1.11x");

    expect(stats?.frame).toBe(120);
    expect(stats?.fps).toBe(28.4);
    expect(stats?.timeMilliseconds).toBe(4500);
    expect(progressFromStats(stats!, 9)).toBe(0.5);
  });

  it("extracts media metadata from ffprobe json", () => {
    const metadata = parseStreamMetadata({
      streams: [
        { codec_type: "video", codec_name: "h264", width: 1920, height: 1080, r_frame_rate: "30000/1001", bit_rate: "2000000" },
        { codec_type: "audio", codec_name: "aac", bit_rate: "128000" }
      ],
      format: { duration: "10.5", bit_rate: "2128000", format_name: "mov,mp4,m4a,3gp,3g2,mj2" }
    });

    expect(metadata.dimensions).toEqual({ width: 1920, height: 1080 });
    expect(metadata.duration).toBe(10.5);
    expect(metadata.videoCodec).toBe("h264");
    expect(metadata.audioCodec).toBe("aac");
    expect(metadata.fps).toBeCloseTo(29.97, 2);
  });
});
