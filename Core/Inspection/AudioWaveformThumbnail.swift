import AudioToolbox
import CoreGraphics
import Foundation

/// A small, sampled overview of real audio amplitudes, not a full-resolution waveform.
/// Call on a worker queue while the source URL is valid. No playback session is used.
enum AudioWaveformThumbnail {
    static func samples(
        from url: URL,
        barCount: Int = 24,
        isCancelled: () -> Bool = { false }
    ) -> [Float]? {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .milliseconds(500))
        func shouldStop() -> Bool { isCancelled() || clock.now >= deadline }
        guard url.isFileURL, !shouldStop() else { return nil }

        var openedFile: ExtAudioFileRef?
        guard ExtAudioFileOpenURL(url as CFURL, &openedFile) == noErr,
              let file = openedFile else { return nil }
        defer { ExtAudioFileDispose(file) }

        var format = AudioStreamBasicDescription()
        var formatSize = UInt32(MemoryLayout.size(ofValue: format))
        var length: Int64 = 0
        var lengthSize = UInt32(MemoryLayout.size(ofValue: length))
        guard !shouldStop(),
              ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileDataFormat, &formatSize, &format) == noErr,
              ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileLengthFrames, &lengthSize, &length) == noErr,
              length > 0, format.mSampleRate.isFinite, format.mSampleRate > 0,
              (1...8).contains(format.mChannelsPerFrame) else { return nil }

        // Keep channels separate so opposite-phase stereo doesn't disappear in a mono mix.
        let channels = format.mChannelsPerFrame
        var clientFormat = AudioStreamBasicDescription(
            mSampleRate: format.mSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagsNativeFloatPacked,
            mBytesPerPacket: channels * 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: channels * 4,
            mChannelsPerFrame: channels,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        guard ExtAudioFileSetProperty(
            file, kExtAudioFileProperty_ClientDataFormat,
            UInt32(MemoryLayout.size(ofValue: clientFormat)), &clientFormat
        ) == noErr else { return nil }

        let count = min(64, max(1, barCount))
        let window = min(2_048, max(1, length / Int64(count)))
        var buffer = [Float](repeating: 0, count: Int(window) * Int(channels))
        var peaks = [Float]()
        peaks.reserveCapacity(count)

        for index in 0..<count {
            guard !shouldStop() else { return nil }
            let center = Double(length) * (Double(index) + 0.5) / Double(count)
            let position = min(length - window, max(0, Int64(center - Double(window) / 2)))
            guard ExtAudioFileSeek(file, position) == noErr, !shouldStop() else { return nil }
            var frames = UInt32(window)
            let status = buffer.withUnsafeMutableBytes { bytes in
                var list = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(
                        mNumberChannels: channels,
                        mDataByteSize: UInt32(bytes.count),
                        mData: bytes.baseAddress
                    )
                )
                return ExtAudioFileRead(file, &frames, &list)
            }
            guard status == noErr, frames > 0, !shouldStop() else { return nil }
            var peak: Float = 0
            for sample in buffer.prefix(Int(frames) * Int(channels)) where sample.isFinite {
                peak = max(peak, abs(sample))
            }
            peaks.append(peak)
        }

        guard let maximum = peaks.max(), maximum > 0 else { return peaks }
        return peaks.map { $0 / maximum }
    }

    static func image(
        from url: URL,
        maxPixelSize: Int,
        isCancelled: () -> Bool = { false }
    ) -> CGImage? {
        guard let peaks = samples(from: url, isCancelled: isCancelled), !isCancelled() else { return nil }
        let size = min(256, max(1, maxPixelSize))
        guard let context = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        let side = CGFloat(size)
        context.setFillColor(CGColor(red: 8 / 255, green: 18 / 255, blue: 30 / 255, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        context.setFillColor(CGColor(red: 163 / 255, green: 221 / 255, blue: 1, alpha: 1))
        let inset = side * 0.12
        let step = (side - inset * 2) / CGFloat(peaks.count)
        let width = step * 0.65
        for (index, peak) in peaks.enumerated() {
            let height = max(side * 0.015, CGFloat(peak) * side * 0.72)
            let rect = CGRect(
                x: inset + CGFloat(index) * step + (step - width) / 2,
                y: (side - height) / 2, width: width, height: height
            )
            context.addPath(CGPath(roundedRect: rect, cornerWidth: width / 2, cornerHeight: width / 2, transform: nil))
            context.fillPath()
        }
        return isCancelled() ? nil : context.makeImage()
    }
}
