import AVFoundation
import CoreMedia

enum RecordingError: Error { case writerFailed, noContent, permissionDenied }

/// Seam over AVAssetWriter so the engine can be exercised with a fake.
protocol RecordingWriter: AnyObject {
    func start(at sourceTime: CMTime) throws
    func appendVideo(_ sample: CMSampleBuffer)
    func appendAudio(_ sample: CMSampleBuffer)
    func finish(_ completion: @escaping (Result<URL, Error>) -> Void)
}

/// Writes H.264/HEVC video + (optionally) one AAC audio track to a file.
///
/// UNVERIFIED: the SCStream→writer path requires on-device smoke testing
/// (record, then play back the file). Compilation is the only automated gate.
final class AssetRecordingWriter: RecordingWriter {
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let audioInput: AVAssetWriterInput?
    let url: URL

    init(url: URL, format: RecordingFormat, size: CGSize, hasAudio: Bool) throws {
        self.url = url
        writer = try AVAssetWriter(outputURL: url, fileType: format.avFileType)

        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: format.videoCodec,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
        ])
        videoInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(videoInput) else { throw RecordingError.writerFailed }
        writer.add(videoInput)

        if hasAudio {
            let a = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 2,
                // 48 kHz matches the canonical mix rate (and SCK/mic native
                // rate), so the encoder isn't handed a rate it must resample.
                AVSampleRateKey: 48_000,
                // 192 kbps stereo: 128 kbps left audible compression coloration
                // on music/media system audio.
                AVEncoderBitRateKey: 192_000,
            ])
            a.expectsMediaDataInRealTime = true
            if writer.canAdd(a) { writer.add(a); audioInput = a } else { audioInput = nil }
        } else {
            audioInput = nil
        }
    }

    func start(at sourceTime: CMTime) throws {
        guard writer.startWriting() else { throw writer.error ?? RecordingError.writerFailed }
        writer.startSession(atSourceTime: sourceTime)
    }

    func appendVideo(_ sample: CMSampleBuffer) {
        guard writer.status == .writing, videoInput.isReadyForMoreMediaData else { return }
        videoInput.append(sample)
    }

    func appendAudio(_ sample: CMSampleBuffer) {
        guard writer.status == .writing,
              let audioInput, audioInput.isReadyForMoreMediaData else { return }
        audioInput.append(sample)
    }

    func finish(_ completion: @escaping (Result<URL, Error>) -> Void) {
        videoInput.markAsFinished()
        audioInput?.markAsFinished()
        let url = self.url
        writer.finishWriting { [weak writer] in
            if let err = writer?.error { completion(.failure(err)) }
            else { completion(.success(url)) }
        }
    }
}
