import Foundation


package struct AnyCodingKey: CodingKey, Sendable {
    package let stringValue: String
    package let intValue: Int?

    package init(_ stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    package init(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    package init(intValue: Int) {
        self.stringValue = "\(intValue)"
        self.intValue = intValue
    }
}
