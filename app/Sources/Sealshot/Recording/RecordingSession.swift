import AVFoundation
import ScreenCaptureKit

/// What's being recorded and where it's going. Resolved by the coordinator
/// before the engine starts.
struct RecordingSession {
    enum Source {
        case display(SCDisplay)
        case window(SCWindow)
        case region(SCDisplay, CGRect)   // rect in display pixels, top-left origin
    }
    let source: Source
    let outputURL: URL
    let format: RecordingFormat
    let frameRate: Int
    let capturesSystemAudio: Bool
    let capturesMicrophone: Bool
    let reducesMicNoise: Bool
    let showsCursor: Bool

    var hasAudio: Bool { capturesSystemAudio || capturesMicrophone }
}
