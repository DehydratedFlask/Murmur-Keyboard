import AVFoundation
import Foundation

/// What the segmenter found in a finished recording.
struct SpeechScan: Sendable {
    /// A trimmed 16 kHz mono copy holding only the speech, or nil when the
    /// recording contains none.
    let audioURL: URL?
    let speechDuration: TimeInterval
    let totalDuration: TimeInterval

    /// Shorter than this and the model is only hearing room tone. Kept low
    /// enough that a dictated "Hi" or "No" still counts as speech.
    static let minimumSpeech: TimeInterval = 0.15

    var hasSpeech: Bool {
        speechDuration >= Self.minimumSpeech
    }
}

/// Finds the speech in a recording and hands the rest to the bin.
///
/// Whisper does not output nothing when it hears only silence or a steady fan:
/// it invents whole sentences — "Thank you.", "Please subscribe", "Subtitles by
/// …" — and those invented words are exactly what show up as extra text in a
/// dictation. Amical solves this by running voice-activity detection and passing
/// only the speech stretches to the model, so Murmur does the same, with an
/// energy threshold that adapts to the room's own noise floor instead of a
/// bundled Silero model.
///
/// The state machine mirrors Amical's `extractSpeechFromVad`: two thresholds
/// with hysteresis, pre-roll so the first syllable is not clipped, post-roll and
/// hangover so a pause mid-sentence does not split it, and a minimum length so a
/// cough is not speech.
enum SpeechSegmenter {

    private static let sampleRate: Double = 16_000
    /// 32 ms at 16 kHz, the frame size Amical's VAD uses.
    private static let frameSamples = 512

    private static let startFrames = 2
    private static let endSilenceFrames = 20      // ~640 ms
    private static let preRollFrames = 15         // ~480 ms
    private static let postRollFrames = 6         // ~192 ms
    private static let minimumSpeechFrames = 2

    private struct Segment {
        let start: Int
        let end: Int
    }

    static func scan(_ url: URL) async -> SpeechScan? {
        await Task.detached(priority: .userInitiated) {
            scanSync(url)
        }.value
    }

    // MARK: - Pipeline

    private static func scanSync(_ url: URL) -> SpeechScan? {
        guard let (samples, sourceRate) = readSamples(url), !samples.isEmpty else {
            return nil
        }

        let totalDuration = Double(samples.count) / sourceRate
        let frames = frameEnergies(samples)

        guard frames.count >= minimumSpeechFrames else {
            return SpeechScan(audioURL: nil, speechDuration: 0, totalDuration: totalDuration)
        }

        // The quiet fifth of the frames is the room, not the speaker. Everything
        // above it is judged against that floor, so a noisy café and a silent
        // bedroom are treated the same way.
        let noiseFloor = percentile(frames, 0.2)
        let startThreshold = max(noiseFloor * 2.2, 0.006)
        let endThreshold = max(noiseFloor * 1.4, 0.0035)

        let loudest = frames.max() ?? 0
        guard loudest >= endThreshold * 1.5 else {
            return SpeechScan(audioURL: nil, speechDuration: 0, totalDuration: totalDuration)
        }

        let segments = speechSegments(frames: frames, start: startThreshold, end: endThreshold)
        guard !segments.isEmpty else {
            return SpeechScan(audioURL: nil, speechDuration: 0, totalDuration: totalDuration)
        }

        guard let trimmedURL = writeTrimmed(samples, segments: segments) else {
            return nil
        }

        let speechSamples = segments.reduce(0) { total, segment in
            total + (segment.end - segment.start)
        } * frameSamples
        let speechDuration = min(
            Double(speechSamples) / sourceRate,
            totalDuration
        )

        return SpeechScan(
            audioURL: trimmedURL,
            speechDuration: speechDuration,
            totalDuration: totalDuration
        )
    }

    // MARK: - Analysis

    private static func frameEnergies(_ samples: [Float]) -> [Float] {
        var energies: [Float] = []
        energies.reserveCapacity(samples.count / frameSamples + 1)

        var index = 0
        while index < samples.count {
            let end = min(index + frameSamples, samples.count)
            var sum: Float = 0
            for i in index..<end {
                let sample = samples[i]
                sum += sample * sample
            }
            energies.append(sqrt(sum / Float(max(end - index, 1))))
            index = end
        }
        return energies
    }

    private static func percentile(_ values: [Float], _ fraction: Double) -> Float {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = min(
            max(Int(Double(sorted.count - 1) * fraction), 0),
            sorted.count - 1
        )
        return sorted[index]
    }

    private static func speechSegments(frames: [Float], start: Float, end: Float) -> [Segment] {
        var segments: [Segment] = []
        var inSpeech = false
        var consecutiveSpeech = 0
        var consecutiveSilence = 0
        var speechStart = 0

        for index in frames.indices {
            let level = frames[index]

            if !inSpeech {
                if level >= start {
                    consecutiveSpeech += 1
                    if consecutiveSpeech >= startFrames {
                        inSpeech = true
                        speechStart = max(0, index - consecutiveSpeech - preRollFrames + 1)
                        consecutiveSilence = 0
                    }
                } else {
                    consecutiveSpeech = 0
                }
            } else if level < end {
                consecutiveSilence += 1
                if consecutiveSilence >= endSilenceFrames {
                    let speechEnd = min(frames.count - 1, index + postRollFrames)
                    if speechEnd - speechStart + 1 >= minimumSpeechFrames {
                        segments.append(Segment(start: speechStart, end: speechEnd))
                    }
                    inSpeech = false
                    consecutiveSpeech = 0
                    consecutiveSilence = 0
                }
            } else {
                consecutiveSilence = 0
            }
        }

        if inSpeech, frames.count - speechStart >= minimumSpeechFrames {
            segments.append(Segment(start: speechStart, end: frames.count - 1))
        }

        // Join stretches that touch, so one sentence with a short breath is a
        // single segment rather than two clips split mid-word.
        var merged: [Segment] = []
        for segment in segments {
            if let last = merged.last, segment.start <= last.end {
                merged[merged.count - 1] = Segment(
                    start: last.start,
                    end: max(last.end, segment.end)
                )
            } else {
                merged.append(segment)
            }
        }
        return merged
    }

    // MARK: - Audio I/O

    /// Reads the recording as normalised float samples at 16 kHz mono.
    private static func readSamples(_ url: URL) -> (samples: [Float], rate: Double)? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        let capacity = AVAudioFrameCount(file.length)
        guard capacity > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity)
        else { return nil }

        do {
            try file.read(into: buffer)
        } catch {
            return nil
        }

        let count = Int(buffer.frameLength)
        guard count > 0 else { return nil }

        if format.commonFormat == .pcmFormatFloat32,
           Int(format.channelCount) == 1,
           let channel = buffer.floatChannelData?[0] {
            return (Array(UnsafeBufferPointer(start: channel, count: count)), format.sampleRate)
        }

        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ),
        let converter = AVAudioConverter(from: format, to: target)
        else { return nil }

        let ratio = sampleRate / format.sampleRate
        let targetCapacity = AVAudioFrameCount(Double(count) * ratio) + 1
        guard let converted = AVAudioPCMBuffer(
            pcmFormat: target,
            frameCapacity: targetCapacity
        ) else { return nil }

        var conversionError: NSError?
        var suppliedInput = false
        converter.convert(to: converted, error: &conversionError) { _, status in
            if suppliedInput {
                status.pointee = .endOfStream
                return nil
            }
            suppliedInput = true
            status.pointee = .haveData
            return buffer
        }

        guard conversionError == nil,
              let channel = converted.floatChannelData?[0]
        else { return nil }

        return (
            Array(UnsafeBufferPointer(
                start: channel,
                count: Int(converted.frameLength)
            )),
            target.sampleRate
        )
    }

    /// Writes the speech segments to a fresh 16 kHz mono WAV.
    private static func writeTrimmed(_ samples: [Float], segments: [Segment]) -> URL? {
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("speech-\(UUID().uuidString)")
            .appendingPathExtension("wav")

        let secondsPerWrite = 16_000
        var pending: [Float] = []
        pending.reserveCapacity(secondsPerWrite)

        do {
            let file = try AVAudioFile(forWriting: url, settings: settings)
            let format = file.processingFormat

            func flush() throws {
                guard !pending.isEmpty,
                      let buffer = AVAudioPCMBuffer(
                          pcmFormat: format,
                          frameCapacity: AVAudioFrameCount(pending.count)
                      )
                else { return }

                buffer.frameLength = AVAudioFrameCount(pending.count)
                if let channel = buffer.floatChannelData?[0] {
                    pending.withUnsafeBufferPointer { source in
                        guard let base = source.baseAddress else { return }
                        channel.update(from: base, count: pending.count)
                    }
                }
                try file.write(from: buffer)
                pending.removeAll(keepingCapacity: true)
            }

            for segment in segments {
                let start = segment.start * frameSamples
                let end = min((segment.end + 1) * frameSamples, samples.count)
                guard start < end else { continue }

                var index = start
                while index < end {
                    let chunkEnd = min(index + (secondsPerWrite - pending.count), end)
                    pending.append(contentsOf: samples[index..<chunkEnd])
                    index = chunkEnd
                    if pending.count == secondsPerWrite {
                        try flush()
                    }
                }
            }

            try flush()
            return url
        } catch {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
    }
}
