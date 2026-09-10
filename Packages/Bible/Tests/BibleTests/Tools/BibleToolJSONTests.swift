import Core
import Testing
@testable import Bible

@Suite("BibleToolJSON")
struct BibleToolJSONTests {
    @Test func integerArgumentsAcceptOnlyExactlyRepresentableValues() {
        let cases: [(JSONValue, Int?)] = [
            (.int(Int.max), Int.max),
            (.double(2), 2),
            (.double(-2), -2),
            (.double(Double(Int.min)), Int.min),
            (.double(Double(Int.max).nextDown), Int.max - 1023),
            (.double(1.5), nil),
            (.double(.nan), nil),
            (.double(.infinity), nil),
            (.double(-.infinity), nil),
            (.double(Double(Int.max)), nil),
            (.double(.greatestFiniteMagnitude), nil),
            (.double(-.greatestFiniteMagnitude), nil),
            (.string("2"), nil),
        ]
        for (value, expected) in cases {
            #expect(BibleToolJSON.optionalInt(["chapter": value], key: "chapter") == expected)
        }
        #expect(BibleToolJSON.optionalInt([:], key: "chapter") == nil)
    }
}
