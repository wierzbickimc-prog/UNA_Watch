import Foundation

/// A FIT workout file, reduced to what the watch reads. Follows
/// una-sdk/Libs/Header/SDK/Fit/FitWorkoutReader.hpp, including its checks, so a
/// file accepted here is one the watch will list. Saving writes a fresh file with
/// these fields only: anything else in the original isn't kept.
public struct FitWorkout: Equatable, Sendable {
    public static let maxSteps = 100
    public static let maxRepeatCount: UInt32 = 99
    static let maxRepeatDepth = 4

    public struct Step: Equatable, Sendable {
        public var durationType: UInt8 = 0xFF
        public var durationValue: UInt32 = invalid
        public var targetType: UInt8 = 0xFF
        public var targetValue: UInt32 = invalid
        public var customLow: UInt32 = invalid
        public var customHigh: UInt32 = invalid
        public var intensity: UInt8 = 0xFF
        public var notes = ""
        public var name = ""

        var isRepeat: Bool { (6...13).contains(durationType) }
    }

    public enum Failure: LocalizedError, Equatable {
        case notFit
        case damaged
        case notWorkout
        case noSteps
        case tooManySteps(Int)
        case badStructure
        case notRunning

        public var errorDescription: String? {
            switch self {
            case .notFit: return "This isn't a FIT file."
            case .damaged: return "This FIT file is damaged."
            case .notWorkout: return "This FIT file isn't a workout."
            case .noSteps: return "This workout has no steps."
            case .tooManySteps(let count): return "This workout has \(count) steps, and the watch holds \(maxSteps)."
            case .badStructure: return "This workout's steps or repeats are invalid."
            case .notRunning: return "This workout isn't for running, so the watch wouldn't list it."
            }
        }
    }

    public static let invalid: UInt32 = 0xFFFF_FFFF
    public static let running: UInt8 = 1
    static let generic: UInt8 = 0

    public var name = ""
    public var description = ""
    public var sport: UInt8 = 0xFF
    public var subSport: UInt8 = 0xFF
    public var steps: [Step] = []

    public init(name: String, sport: UInt8 = FitWorkout.running, steps: [Step]) {
        self.name = name
        self.sport = sport
        self.steps = steps
    }

    // MARK: Reading

    private struct Field {
        let number: UInt8
        let size: Int
    }

    private struct Definition {
        let global: UInt16
        let bigEndian: Bool
        let fields: [Field]
        let developerBytes: Int
    }

    public init(fit: Data) throws {
        let bytes = [UInt8](fit)
        guard bytes.count >= 14, bytes[0] == 12 || bytes[0] == 14, bytes[1] >> 4 <= 2,
              bytes[8...11].elementsEqual(Array(".FIT".utf8)) else { throw Failure.notFit }
        let headerSize = Int(bytes[0])
        let dataSize = Int(bytes[4]) | Int(bytes[5]) << 8 | Int(bytes[6]) << 16 | Int(bytes[7]) << 24
        let end = headerSize + dataSize
        guard end + 2 <= bytes.count, Self.crc(bytes[0..<end + 2]) == 0 else { throw Failure.damaged }

        var definitions: [Int: Definition] = [:]
        var fileType: UInt32?
        var indexed: [Int: Step] = [:]
        var position = headerSize

        func take(_ count: Int) throws -> ArraySlice<UInt8> {
            guard count >= 0, position + count <= end else { throw Failure.damaged }
            defer { position += count }
            return bytes[position..<position + count]
        }

        while position < end {
            let header = try take(1).first!
            if header & 0x80 == 0, header & 0x40 != 0 {
                _ = try take(1)
                let bigEndian = try take(1).first! == 1
                let globalBytes = Array(try take(2))
                let global = bigEndian ? UInt16(globalBytes[0]) << 8 | UInt16(globalBytes[1])
                                       : UInt16(globalBytes[1]) << 8 | UInt16(globalBytes[0])
                let count = Int(try take(1).first!)
                var fields: [Field] = []
                for _ in 0..<count {
                    let field = Array(try take(3))
                    fields.append(Field(number: field[0], size: Int(field[1])))
                }
                var developerBytes = 0
                if header & 0x20 != 0 {
                    for _ in 0..<Int(try take(1).first!) {
                        developerBytes += Int(Array(try take(3))[1])
                    }
                }
                definitions[Int(header & 0x0F)] = Definition(global: global, bigEndian: bigEndian, fields: fields,
                                                             developerBytes: developerBytes)
                continue
            }

            // A compressed timestamp header carries its local type in bits 5 and 6.
            let local = header & 0x80 != 0 ? Int((header >> 5) & 0x03) : Int(header & 0x0F)
            guard let definition = definitions[local] else { throw Failure.damaged }
            var numbers: [UInt8: UInt32] = [:]
            var texts: [UInt8: String] = [:]
            for field in definition.fields {
                let value = try take(field.size)
                numbers[field.number] = Self.number(value, bigEndian: definition.bigEndian)
                texts[field.number] = Self.text(value)
            }
            _ = try take(definition.developerBytes)

            switch definition.global {
            case 0:
                fileType = numbers[0] ?? fileType
            case 26:
                name = texts[8] ?? name
                description = texts[17] ?? description
                sport = numbers[4].map(Self.byte) ?? sport
                subSport = numbers[11].map(Self.byte) ?? subSport
            case 27:
                guard let index = numbers[254], index != Self.invalid, indexed[Int(index)] == nil else {
                    throw Failure.badStructure
                }
                indexed[Int(index)] = Step(
                    durationType: numbers[1].map(Self.byte) ?? 0xFF,
                    durationValue: numbers[2] ?? Self.invalid,
                    targetType: numbers[3].map(Self.byte) ?? 0xFF,
                    targetValue: numbers[4] ?? Self.invalid,
                    customLow: numbers[5] ?? Self.invalid,
                    customHigh: numbers[6] ?? Self.invalid,
                    intensity: numbers[7].map(Self.byte) ?? 0xFF,
                    notes: texts[8] ?? "",
                    name: texts[0] ?? ""
                )
            default:
                break
            }
        }

        guard fileType == 5 else { throw Failure.notWorkout }
        guard !indexed.isEmpty else { throw Failure.noSteps }
        guard indexed.count <= Self.maxSteps else { throw Failure.tooManySteps(indexed.count) }
        guard indexed.keys.sorted() == Array(0..<indexed.count) else { throw Failure.badStructure }
        steps = (0..<indexed.count).map { indexed[$0]! }
        guard hasValidRepeats else { throw Failure.badStructure }
        guard sport == Self.running || sport == Self.generic || sport == 0xFF else { throw Failure.notRunning }
    }

    private var hasValidRepeats: Bool {
        var blocks: [ClosedRange<Int>] = []
        for (index, step) in steps.enumerated() where step.isRepeat {
            guard step.durationValue < UInt32(index) else { return false }
            let block = Int(step.durationValue)...index
            for other in blocks where other.overlaps(block) && !(block.lowerBound <= other.lowerBound) {
                return false
            }
            blocks.append(block)
        }
        return blocks.allSatisfy { block in
            blocks.filter { $0.lowerBound <= block.lowerBound && $0.upperBound >= block.upperBound }.count
                <= Self.maxRepeatDepth
        }
    }

    /// An all-ones value is FIT's "not set", at any width.
    private static func number(_ value: ArraySlice<UInt8>, bigEndian: Bool) -> UInt32? {
        guard [1, 2, 4].contains(value.count) else { return nil }
        let ordered = bigEndian ? Array(value) : Array(value.reversed())
        let result = ordered.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        return value.allSatisfy({ $0 == 0xFF }) ? invalid : result
    }

    private static func text(_ value: ArraySlice<UInt8>) -> String {
        String(decoding: value.prefix { $0 != 0 }, as: UTF8.self)
    }

    private static func byte(_ value: UInt32) -> UInt8 {
        value == invalid ? 0xFF : UInt8(truncatingIfNeeded: value)
    }

    // MARK: Totals

    /// With repeats expanded. A step that ends by distance or by hand adds no time.
    public var totalSeconds: Int { Int(totals().ms / 1000) }
    public var totalMetres: Double { Double(totals().cm) / 100 }

    /// Each repeat folds its block into its own slot, so an outer repeat counts it again.
    private func totals() -> (ms: UInt64, cm: UInt64) {
        var parts = [(ms: UInt64, cm: UInt64)](repeating: (0, 0), count: steps.count)
        for (index, step) in steps.enumerated() {
            if step.isRepeat {
                let times = step.durationType == 6 && step.targetValue != Self.invalid ? UInt64(max(step.targetValue, 1)) : 1
                let from = Int(step.durationValue)
                parts[index] = (parts[from..<index].reduce(0) { $0 + $1.ms } * times,
                                parts[from..<index].reduce(0) { $0 + $1.cm } * times)
                for inner in from..<index { parts[inner] = (0, 0) }
            } else if step.durationValue != Self.invalid {
                if step.durationType == 0 { parts[index].ms = UInt64(step.durationValue) }
                if step.durationType == 1 { parts[index].cm = UInt64(step.durationValue) }
            }
        }
        return (parts.reduce(0) { $0 + $1.ms }, parts.reduce(0) { $0 + $1.cm })
    }

    // MARK: Writing

    public func encoded() -> Data {
        var body: [UInt8] = []

        func define(local: UInt8, global: UInt16, _ fields: [(UInt8, UInt8, UInt8)]) {
            body += [0x40 | local, 0, 0, UInt8(global & 0xFF), UInt8(global >> 8), UInt8(fields.count)]
            for field in fields { body += [field.0, field.1, field.2] }
        }

        func u16(_ value: UInt16) -> [UInt8] { [UInt8(value & 0xFF), UInt8(value >> 8)] }
        func u32(_ value: UInt32) -> [UInt8] { (0..<4).map { UInt8((value >> (8 * UInt32($0))) & 0xFF) } }
        let enumType: UInt8 = 0x00, stringType: UInt8 = 0x07, u16Type: UInt8 = 0x84, u32Type: UInt8 = 0x86

        // file_id: a workout, from a development manufacturer.
        define(local: 0, global: 0, [(0, 1, enumType), (1, 2, u16Type), (2, 2, u16Type)])
        body += [0, 5] + u16(255) + u16(0)

        let nameBytes = 64, descriptionBytes = 160, stepNameBytes = 32, notesBytes = 64
        define(local: 1, global: 26, [(8, UInt8(nameBytes), stringType), (4, 1, enumType), (11, 1, enumType),
                                      (6, 2, u16Type), (17, UInt8(descriptionBytes), stringType)])
        body += [1] + Self.fixed(name, nameBytes) + [sport, subSport] + u16(UInt16(steps.count))
            + Self.fixed(description, descriptionBytes)

        define(local: 2, global: 27, [(254, 2, u16Type), (0, UInt8(stepNameBytes), stringType), (1, 1, enumType),
                                      (2, 4, u32Type), (3, 1, enumType), (4, 4, u32Type), (5, 4, u32Type),
                                      (6, 4, u32Type), (7, 1, enumType), (8, UInt8(notesBytes), stringType)])
        for (index, step) in steps.enumerated() {
            body += [2] + u16(UInt16(index)) + Self.fixed(step.name, stepNameBytes) + [step.durationType]
            body += u32(step.durationValue) + [step.targetType] + u32(step.targetValue)
            body += u32(step.customLow) + u32(step.customHigh) + [step.intensity]
            body += Self.fixed(step.notes, notesBytes)
        }

        var file: [UInt8] = [14, 0x20] + u16(2132) + u32(UInt32(body.count)) + Array(".FIT".utf8)
        file += u16(Self.crc(file[0...]))
        file += body
        file += u16(Self.crc(file[0...]))
        return Data(file)
    }

    /// Text in a fixed-size field, cut on a character boundary and NUL-terminated.
    private static func fixed(_ text: String, _ size: Int) -> [UInt8] {
        var bytes: [UInt8] = []
        for scalar in text.unicodeScalars {
            let encoded = Array(String(scalar).utf8)
            if bytes.count + encoded.count >= size { break }
            bytes += encoded
        }
        return bytes + Array(repeating: 0, count: size - bytes.count)
    }

    static func crc(_ bytes: ArraySlice<UInt8>) -> UInt16 {
        let table: [UInt16] = [0x0000, 0xCC01, 0xD801, 0x1400, 0xF001, 0x3C00, 0x2800, 0xE401,
                               0xA001, 0x6C00, 0x7800, 0xB401, 0x5000, 0x9C01, 0x8801, 0x4400]
        var crc: UInt16 = 0
        for byte in bytes {
            var tmp = table[Int(crc & 0xF)]
            crc = (crc >> 4) & 0x0FFF
            crc = crc ^ tmp ^ table[Int(byte & 0xF)]
            tmp = table[Int(crc & 0xF)]
            crc = (crc >> 4) & 0x0FFF
            crc = crc ^ tmp ^ table[Int((byte >> 4) & 0xF)]
        }
        return crc
    }
}
