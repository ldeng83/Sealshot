import XCTest
import AVFoundation
@testable import Sealshot

final class RecordingFormatTests: XCTestCase {
    func test_hevcMov_attributes() {
        XCTAssertEqual(RecordingFormat.hevcMov.fileExtension, "mov")
        XCTAssertEqual(RecordingFormat.hevcMov.avFileType, .mov)
        XCTAssertEqual(RecordingFormat.hevcMov.videoCodec, .hevc)
    }
    func test_h264Mp4_attributes() {
        XCTAssertEqual(RecordingFormat.h264Mp4.fileExtension, "mp4")
        XCTAssertEqual(RecordingFormat.h264Mp4.avFileType, .mp4)
        XCTAssertEqual(RecordingFormat.h264Mp4.videoCodec, .h264)
    }
    func test_rawValueRoundTrips() {
        for f in RecordingFormat.allCases {
            XCTAssertEqual(RecordingFormat(rawValue: f.rawValue), f)
        }
    }
}
