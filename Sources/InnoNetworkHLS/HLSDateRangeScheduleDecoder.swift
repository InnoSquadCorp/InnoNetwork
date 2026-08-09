import Foundation

enum HLSDateRangeScheduleDecoder {
    static func decode(
        _ data: Data,
        parent: HLSDateRange,
        relativeTo sourceURL: URL,
        maximumEntryCount: Int
    ) throws -> [HLSDateRange] {
        let document: Document
        do {
            document = try JSONDecoder().decode(
                Document.self,
                from: data
            )
        } catch {
            throw HLSExternalResourceError.invalidDateRangeSchedule
        }
        guard
            !document.dateRanges.isEmpty,
            document.dateRanges.count <= maximumEntryCount
        else {
            if document.dateRanges.count > maximumEntryCount {
                throw
                    HLSExternalResourceError
                    .tooManyScheduledDateRanges(
                        limit: maximumEntryCount
                    )
            }
            throw HLSExternalResourceError.invalidDateRangeSchedule
        }

        do {
            let dateRanges = try document.dateRanges.map {
                try makeDateRange(
                    from: $0,
                    parent: parent,
                    relativeTo: sourceURL
                )
            }
            try HLSTimelineParser.validateClassTimelines(
                dateRanges
            )
            return dateRanges
        } catch let error as HLSExternalResourceError {
            throw error
        } catch {
            throw HLSExternalResourceError.invalidDateRangeSchedule
        }
    }

    private static func makeDateRange(
        from object: [String: JSONValue],
        parent: HLSDateRange,
        relativeTo sourceURL: URL
    ) throws -> HLSDateRange {
        guard
            let id = object["ID"]?.string,
            !id.isEmpty,
            let className = object["CLASS"]?.string,
            !className.isEmpty
        else {
            throw HLSExternalResourceError.invalidDateRangeSchedule
        }
        let hasStartDate = object["START-DATE"] != nil
        let hasScheduleOffset = object["X-SCHEDULE-OFFSET"] != nil
        guard hasStartDate != hasScheduleOffset else {
            throw HLSExternalResourceError.invalidDateRangeSchedule
        }

        let startDate: Date
        if let value = object["START-DATE"]?.string {
            startDate = try HLSTimelineParser.parseDate(value)
        } else if let offset = object["X-SCHEDULE-OFFSET"]?.number {
            guard offset.isFinite else {
                throw HLSExternalResourceError.invalidDateRangeSchedule
            }
            startDate = parent.startDate.addingTimeInterval(offset)
        } else {
            throw HLSExternalResourceError.invalidDateRangeSchedule
        }

        var values: [String: String] = [:]
        var quotedNames: Set<String> = []
        for (name, value) in object {
            guard isValidAttributeName(name) else {
                throw HLSExternalResourceError.invalidDateRangeSchedule
            }
            switch representation(of: value, named: name) {
            case .quoted(let text):
                values[name] = text
                quotedNames.insert(name)
            case .unquoted(let text):
                values[name] = text
            case .extensionValue:
                values[name] = "<json>"
                quotedNames.insert(name)
            case .invalid:
                throw HLSExternalResourceError
                    .invalidDateRangeSchedule
            }
        }
        values["ID"] = id
        quotedNames.insert("ID")
        values["CLASS"] = className
        quotedNames.insert("CLASS")
        values["START-DATE"] = dateString(startDate)
        quotedNames.insert("START-DATE")

        return try HLSTimelineParser.makeDateRange(
            id: id,
            attributes: HLSAttributeList(
                values: values,
                quotedNames: quotedNames
            ),
            relativeTo: sourceURL,
            allowsPreloading: true
        )
    }

    private static func representation(
        of value: JSONValue,
        named name: String
    ) -> AttributeRepresentation {
        if unquotedNames.contains(name) {
            if let number = value.numberString {
                return .unquoted(number)
            }
            if let string = value.string {
                return .unquoted(string)
            }
            return .invalid
        }
        if quotedNames.contains(name) {
            guard let string = value.string else {
                return .invalid
            }
            return .quoted(string)
        }
        switch value {
        case .string(let string):
            return .quoted(string)
        case .number(let number):
            return .unquoted(
                NSDecimalNumber(decimal: number).stringValue
            )
        case .boolean, .array, .object, .null:
            return .extensionValue
        }
    }

    private static func isValidAttributeName(_ name: String) -> Bool {
        !name.isEmpty
            && name.allSatisfy {
                $0.isASCII
                    && ($0.isUppercase || $0.isNumber || $0 == "-")
            }
    }

    private static func dateString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds,
        ]
        return formatter.string(from: date)
    }

    private static let quotedNames: Set<String> = [
        "CLASS",
        "CUE",
        "END-DATE",
        "ID",
        "START-DATE",
        "X-ASSET-LIST",
        "X-ASSET-URI",
        "X-TARGET-CLASS",
        "X-TARGET-ID",
        "X-URI",
    ]

    private static let unquotedNames: Set<String> = [
        "DURATION",
        "END-ON-NEXT",
        "PLANNED-DURATION",
        "X-DURATION-AT-JOIN",
        "X-PLAYOUT-LIMIT",
        "X-RESUME-OFFSET",
        "X-SCHEDULE-OFFSET",
    ]

    private enum AttributeRepresentation {
        case quoted(String)
        case unquoted(String)
        case extensionValue
        case invalid
    }

    private struct Document: Decodable {
        let dateRanges: [[String: JSONValue]]

        private enum CodingKeys: String, CodingKey {
            case dateRanges = "DATERANGES"
        }
    }

    private indirect enum JSONValue: Decodable {
        case string(String)
        case number(Decimal)
        case boolean(Bool)
        case array([JSONValue])
        case object([String: JSONValue])
        case null

        var string: String? {
            guard case .string(let value) = self else {
                return nil
            }
            return value
        }

        var number: Double? {
            switch self {
            case .number(let value):
                return NSDecimalNumber(decimal: value).doubleValue
            case .string(let value):
                return Double(value)
            case .boolean, .array, .object, .null:
                return nil
            }
        }

        var numberString: String? {
            switch self {
            case .number(let value):
                return NSDecimalNumber(decimal: value).stringValue
            case .string(let value):
                return value
            case .boolean, .array, .object, .null:
                return nil
            }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() {
                self = .null
            } else if let value = try? container.decode(Bool.self) {
                self = .boolean(value)
            } else if let value = try? container.decode(Decimal.self) {
                self = .number(value)
            } else if let value = try? container.decode(String.self) {
                self = .string(value)
            } else if let value = try? container.decode([JSONValue].self) {
                self = .array(value)
            } else {
                self = .object(
                    try container.decode(
                        [String: JSONValue].self
                    )
                )
            }
        }
    }
}
