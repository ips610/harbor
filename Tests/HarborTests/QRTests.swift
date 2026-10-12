import CoreImage
import XCTest
@testable import Harbor

/// harbor's QR codes have rounded modules and the wave mark over the middle, so
/// what matters is that they still scan: each one is drawn the way the menu
/// draws it and read back with the system's own QR reader.
final class QRTests: XCTestCase {
    /// A short LAN address, a Bonjour one, and a public tunnel link of about 70 characters.
    private let urls = [
        "http://192.168.1.24:3000/",
        "http://IPS-MacBook-Pro.local:5173/",
        "https://harbor-tide-example-quick-tunnel-name-abc.trycloudflare.com/",
    ]

    private func read(_ image: CGImage) -> String? {
        let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
        return detector?.features(in: CIImage(cgImage: image)).compactMap { ($0 as? CIQRCodeFeature)?.messageString }.first
    }

    func testCodesScanAtTheMenusSizes() throws {
        XCTAssertEqual(urls[2].count, 68)
        // 132 pt in a row's details and the tunnel line, 150 pt in the "another device" card; 1x and 2x screens.
        for url in urls {
            for points in [132, 150] {
                for scale in [1, 2] {
                    let image = try XCTUnwrap(QR.image(url, pixels: points * scale))
                    XCTAssertEqual(image.width, points * scale)
                    XCTAssertEqual(read(image), url, "\(points) pt at \(scale)x")
                }
            }
        }
    }

    /// A project shared both ways shows two codes at once, one under the other in the menu.
    /// Whoever points a camera at them has both in the picture: each must still read whole.
    func testTwoCodesInOnePictureBothScan() throws {
        let links = ["http://storefront.local/", "https://quiet-harbor-demo.trycloudflare.com"]
        let detector = try XCTUnwrap(CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
        for points in [132, 150] {
            for scale in [1, 2] {
                // As the card stacks them: a code, a line with its link, the next code; on the menu's dark backdrop.
                let side = points * scale, gap = 28 * scale
                let codes = try links.map { try XCTUnwrap(QR.image($0, pixels: side)) }
                let picture = try XCTUnwrap(CGContext(data: nil, width: side + 2 * gap, height: 2 * side + 3 * gap, bitsPerComponent: 8, bytesPerRow: 0,
                                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                picture.setFillColor(CGColor(gray: 0.16, alpha: 1))
                picture.fill(CGRect(x: 0, y: 0, width: picture.width, height: picture.height))
                picture.draw(codes[0], in: CGRect(x: gap, y: 2 * gap + side, width: side, height: side))
                picture.draw(codes[1], in: CGRect(x: gap, y: gap, width: side, height: side))
                let found = detector.features(in: CIImage(cgImage: try XCTUnwrap(picture.makeImage()))).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
                XCTAssertEqual(found.sorted(), links.sorted(), "\(points) pt at \(scale)x")
            }
        }
    }

    func testMatrixHasNoQuietZoneAndTheThreeEyes() throws {
        for url in urls {
            let m = try XCTUnwrap(QR.matrix(url))
            let n = m.count
            XCTAssertTrue(n >= 21 && (n - 21) % 4 == 0, "\(n) isn't a QR size")
            XCTAssertTrue(m.allSatisfy { $0.count == n })
            // A finder pattern in three corners (dark outer ring), none in the fourth.
            for (x, y) in [(0, 0), (n - 7, 0), (0, n - 7)] {
                XCTAssertTrue((0..<7).allSatisfy { m[y][x + $0] && m[y + 6][x + $0] && m[y + $0][x] && m[y + $0][x + 6] })
            }
            XCTAssertFalse((0..<7).allSatisfy { m[n - 1][n - 7 + $0] })
            // What the page gets: the same modules as rows of 0 and 1.
            let rows = try XCTUnwrap(MainActor.assumeIsolated { Tunnels.shared.qrRows(url) })
            XCTAssertEqual(rows, m.map { String($0.map { $0 ? "1" : "0" }) })
        }
    }

    func testTheMarkNeverCoversTooMuch() {
        XCTAssertEqual(QR.hole(29), 7)
        XCTAssertEqual(QR.hole(49), 11)
        for n in stride(from: 21, through: 177, by: 4) {
            let hole = QR.hole(n)
            XCTAssertEqual(hole % 2, 1, "\(n)")                                   // odd, so it sits on the middle module
            XCTAssertLessThanOrEqual(Double(hole * hole) / Double(n * n), 0.0605, "\(n)")
            XCTAssertGreaterThanOrEqual(Double(hole) / Double(n), 0.19, "\(n)")
        }
    }

    func testCodeIsDarkOnWhite() throws {
        // The same in light and dark mode: nothing in the drawing reads the appearance.
        let image = try XCTUnwrap(QR.image(urls[0], pixels: 264))
        let w = image.width
        var px = [UInt8](repeating: 0, count: w * w * 4)
        let ctx = try XCTUnwrap(CGContext(data: &px, width: w, height: w, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: w))
        func color(_ x: Int, _ y: Int) -> [UInt8] { Array(px[(y * w + x) * 4..<(y * w + x) * 4 + 4]) }
        XCTAssertEqual(color(0, 0)[3], 0)                                   // outside the card's round corner
        XCTAssertEqual(color(w / 2, 4), [255, 255, 255, 255])               // the quiet zone, inside the white card
        XCTAssertEqual(color(w / 2, w / 2 - 16), [0x16, 0x17, 0x1c, 255])   // the mark's tile, above its two waves
        let ink = stride(from: 0, to: px.count, by: 4).filter { px[$0] == 11 && px[$0 + 1] == 11 && px[$0 + 2] == 12 }.count
        XCTAssertGreaterThan(Double(ink) / Double(w * w), 0.15)             // the modules are the dark ink
        let waves = stride(from: 0, to: px.count, by: 4).filter { px[$0] == 0xa7 && px[$0 + 1] == 0xb4 && px[$0 + 2] == 0xff }.count
        XCTAssertGreaterThan(waves, 50)                                     // and the two waves are there
    }
}
