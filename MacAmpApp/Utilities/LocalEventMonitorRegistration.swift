import AppKit

@MainActor
struct LocalEventMonitorRegistration {
    var add: (NSEvent.EventTypeMask, @escaping (NSEvent) -> NSEvent?) -> Any?
    var remove: (Any) -> Void

    static let appKit = Self(
        add: { NSEvent.addLocalMonitorForEvents(matching: $0, handler: $1) },
        remove: { NSEvent.removeMonitor($0) }
    )
}
