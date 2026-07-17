import XCTest
@testable import AlphaSubCore

final class DownmixMatrixTests: XCTestCase {
    func testStereoAndMonoAreIdentity() {
        XCTAssertEqual(DownmixMatrix.coefficients(channelCount: 2).map { $0.left },  [1, 0])
        XCTAssertEqual(DownmixMatrix.coefficients(channelCount: 2).map { $0.right }, [0, 1])
        XCTAssertEqual(DownmixMatrix.coefficients(channelCount: 1).count, 1)
    }

    func testFiveOneFollowsBS775() {
        let c = DownmixMatrix.coefficients(channelCount: 6)
        let n = DownmixMatrix.normalization()
        XCTAssertEqual(c.count, 6)
        XCTAssertEqual(c[0].left,  n, accuracy: 1e-12)                       // L → Lo only
        XCTAssertEqual(c[0].right, 0)
        XCTAssertEqual(c[2].left,  DownmixMatrix.minus3dB * n, accuracy: 1e-12) // C → both at −3 dB
        XCTAssertEqual(c[2].right, DownmixMatrix.minus3dB * n, accuracy: 1e-12)
        XCTAssertEqual(c[3].left, 0); XCTAssertEqual(c[3].right, 0)          // LFE dropped
        XCTAssertEqual(c[4].left,  DownmixMatrix.minus3dB * n, accuracy: 1e-12) // Ls → Lo
        XCTAssertEqual(c[4].right, 0)
    }

    func testFullScaleAllChannelsDoesNotClip() {
        let c = DownmixMatrix.coefficients(channelCount: 6)
        let lo = c.reduce(0) { $0 + $1.left }
        let ro = c.reduce(0) { $0 + $1.right }
        XCTAssertLessThanOrEqual(lo, 1.0 + 1e-9)
        XCTAssertLessThanOrEqual(ro, 1.0 + 1e-9)
    }

    func testDegenerateChannelCounts() {
        XCTAssertTrue(DownmixMatrix.coefficients(channelCount: 0).isEmpty)
        XCTAssertEqual(DownmixMatrix.coefficients(channelCount: 4).count, 4) // fallback path
    }
}
