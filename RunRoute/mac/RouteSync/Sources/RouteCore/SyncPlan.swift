import Foundation

/// What a sync would do. It never deletes on its own: a route that's only on the
/// watch may have been added some other way, so removing it is the user's call.
public struct SyncPlan: Equatable, Sendable {
    /// RouteCatalog::kMaxRoutes in the watch app.
    public static let capacity = 32

    public enum Action: Equatable, Sendable {
        case add
        case update
        case upToDate
        /// Sending it would take the watch past its limit.
        case noRoom
        /// Another GPX file has the same route name. The watch's drive ignores case.
        case sameName(String)
    }

    public struct Item: Equatable, Sendable {
        public let route: RouteFile
        public let action: Action
    }

    public let items: [Item]
    public let watchOnly: [WatchRoute]
    /// Every route on the watch, for rebuilding the plan when the folder changes.
    public let allWatchRoutes: [WatchRoute]

    public var toSend: [RouteFile] {
        items.filter { $0.action == .add || $0.action == .update }.map(\.route)
    }

    public init(local: [RouteFile], watch: [WatchRoute]) {
        allWatchRoutes = watch
        var byName: [String: WatchRoute] = [:]
        for route in watch { byName[route.name.lowercased()] = route }

        var used = watch.count
        var firstWithName: [String: String] = [:]
        var localNames: Set<String> = []
        items = local.map { route in
            let key = route.name.lowercased()
            if let first = firstWithName[key] {
                return Item(route: route, action: .sameName(first))
            }
            firstWithName[key] = route.name
            localNames.insert(key)

            guard let existing = byName[key] else {
                guard used < Self.capacity else { return Item(route: route, action: .noRoom) }
                used += 1
                return Item(route: route, action: .add)
            }
            let same = existing.size == route.data.count && existing.crc == crc32(route.data)
            return Item(route: route, action: same ? .upToDate : .update)
        }
        watchOnly = watch.filter { !localNames.contains($0.name.lowercased()) }
    }
}
