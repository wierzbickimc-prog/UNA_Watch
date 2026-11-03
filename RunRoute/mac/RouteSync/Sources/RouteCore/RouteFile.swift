import Foundation

/// A GPX file turned into the route format RunRoute reads. Matches
/// RunRoute/tools/gpx2route.py, byte for byte.
public struct RouteFile: Equatable, Sendable {
    public static let maxPoints = 4000
    public static let maxName = 39

    public private(set) var name: String
    /// The GPX file's name. Two files can share a route name, but not this.
    public let fileName: String
    public let data: Data
    public let pointCount: Int
    public let keptCount: Int
    public let metres: Double

    public var miles: Double { metres / 1609.344 }

    public enum Failure: LocalizedError, Equatable {
        case unreadable(String)
        case noRoute

        public var errorDescription: String? {
            switch self {
            case .unreadable(let why): return "Can't read this GPX file: \(why)"
            case .noRoute: return "No route: it needs at least 2 track or route points."
            }
        }
    }

    public struct Point: Equatable, Sendable {
        public let lat: Double
        public let lon: Double
    }

    public init(gpx url: URL) throws {
        let parsed: (name: String?, points: [Point])
        do {
            parsed = try Self.parse(Data(contentsOf: url))
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.unreadable(error.localizedDescription)
        }
        guard parsed.points.count >= 2 else { throw Failure.noRoute }

        let xy = Self.toMetres(parsed.points)
        var tolerance = 0.0
        var keep = Array(parsed.points.indices)
        while keep.count > Self.maxPoints {
            tolerance = tolerance > 0 ? tolerance * 1.5 : 1.0
            keep = Self.simplify(xy, tolerance: tolerance)
        }

        var bytes = Data("URTE".utf8)
        Self.append(UInt32(keep.count), to: &bytes)
        for index in keep {
            let point = parsed.points[index]
            Self.append(Self.fixed(point.lat), to: &bytes)
            Self.append(Self.fixed(point.lon), to: &bytes)
        }

        name = Self.routeName(gpxName: parsed.name, path: url)
        fileName = url.lastPathComponent
        data = bytes
        pointCount = parsed.points.count
        keptCount = keep.count
        metres = zip(xy, xy.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
    }

    public func renamed(_ newName: String) -> RouteFile {
        var copy = self
        copy.name = Self.cleanName(newName) ?? name
        return copy
    }

    /// A name that works as a file name and that the watch's fonts can show.
    public static func routeName(gpxName: String?, path: URL) -> String {
        cleanName(gpxName ?? path.deletingPathExtension().lastPathComponent) ?? "Route"
    }

    /// Nil if nothing usable is left.
    public static func cleanName(_ raw: String) -> String? {
        let allowed = raw.unicodeScalars.filter {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == " " || $0 == "_" || $0 == "-")
        }
        let words = String(String.UnicodeScalarView(allowed)).split(separator: " ").joined(separator: " ")
        let clean = String(words.prefix(maxName)).trimmingCharacters(in: .whitespaces)
        return clean.isEmpty ? nil : clean
    }

    static func parse(_ xml: Data) throws -> (name: String?, points: [Point]) {
        let reader = GPXReader()
        let parser = XMLParser(data: xml)
        parser.delegate = reader
        guard parser.parse(), reader.failure == nil else {
            throw Failure.unreadable(reader.failure ?? "it isn't valid GPX.")
        }
        return (reader.name, reader.track.isEmpty ? reader.routePoints : reader.track)
    }

    private static func fixed(_ degrees: Double) -> Int32 {
        Int32((degrees * 1e7).rounded(.toNearestOrEven))
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    private static func toMetres(_ points: [Point]) -> [(x: Double, y: Double)] {
        let metresPerDegree = 111320.0
        let origin = points[0]
        let perLon = metresPerDegree * cos(origin.lat * .pi / 180)
        return points.map { (($0.lon - origin.lon) * perLon, ($0.lat - origin.lat) * metresPerDegree) }
    }

    private static func offset(_ p: (x: Double, y: Double), _ a: (x: Double, y: Double), _ b: (x: Double, y: Double)) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSq = dx * dx + dy * dy
        let t = lengthSq == 0 ? 0 : max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSq))
        return hypot(p.x - a.x - dx * t, p.y - a.y - dy * t)
    }

    /// Douglas-Peucker: the indexes of the points to keep.
    private static func simplify(_ xy: [(x: Double, y: Double)], tolerance: Double) -> [Int] {
        var keep: Set<Int> = [0, xy.count - 1]
        var stack = [(0, xy.count - 1)]
        while let (first, last) = stack.popLast() {
            var worst = -1.0
            var worstAt: Int?
            var i = first + 1
            while i < last {
                let d = offset(xy[i], xy[first], xy[last])
                if d > worst {
                    worst = d
                    worstAt = i
                }
                i += 1
            }
            if let at = worstAt, worst > tolerance {
                keep.insert(at)
                stack.append((first, at))
                stack.append((at, last))
            }
        }
        return keep.sorted()
    }
}

private final class GPXReader: NSObject, XMLParserDelegate {
    var name: String?
    var track: [RouteFile.Point] = []
    var routePoints: [RouteFile.Point] = []
    var failure: String?

    private var text: String?

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        let tag = element.split(separator: ":").last.map(String.init) ?? element
        switch tag {
        case "trkpt", "rtept":
            guard let lat = attributes["lat"].flatMap(Double.init), let lon = attributes["lon"].flatMap(Double.init) else {
                failure = "a \(tag) has no valid lat and lon"
                parser.abortParsing()
                return
            }
            let point = RouteFile.Point(lat: lat, lon: lon)
            if tag == "trkpt" { track.append(point) } else { routePoints.append(point) }
        case "name":
            if name == nil { text = "" }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text?.append(string)
    }

    func parser(_ parser: XMLParser, foundCDATA block: Data) {
        text?.append(String(decoding: block, as: UTF8.self))
    }

    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
        guard let found = text, element.hasSuffix("name") else { return }
        text = nil
        if !found.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { name = found }
    }
}
