import XCTest
@testable import HLSDownloader

final class AttributeListParserTests: XCTestCase {
    func testParsesQuotedCommaWithoutSplittingField() {
        let attributes = AttributeListParser.parse(
            #"TYPE=AUDIO,GROUP-ID="audio",NAME="日本語, ステレオ",DEFAULT=YES"#
        )

        XCTAssertEqual(attributes["TYPE"], "AUDIO")
        XCTAssertEqual(attributes["GROUP-ID"], "audio")
        XCTAssertEqual(attributes["NAME"], "日本語, ステレオ")
        XCTAssertEqual(attributes["DEFAULT"], "YES")
    }
}

