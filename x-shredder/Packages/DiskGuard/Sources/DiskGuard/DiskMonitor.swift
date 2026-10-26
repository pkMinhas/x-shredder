import Foundation
import DiskArbitration

/// Calls `onChange` whenever a disk appears, disappears or changes.
public final class DiskMonitor {
    private let session: DASession?
    private let queue = DispatchQueue(label: "com.withpreet.x-shredder.disk-monitor")
    private let onChange: @Sendable () -> Void

    public init(onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
        session = DASessionCreate(kCFAllocatorDefault)
        guard let session else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        DARegisterDiskAppearedCallback(session, nil, { _, context in
            DiskMonitor.notify(context)
        }, context)
        DARegisterDiskDisappearedCallback(session, nil, { _, context in
            DiskMonitor.notify(context)
        }, context)
        DARegisterDiskDescriptionChangedCallback(session, nil, nil, { _, _, context in
            DiskMonitor.notify(context)
        }, context)
        DASessionSetDispatchQueue(session, queue)
    }

    deinit {
        if let session { DASessionSetDispatchQueue(session, nil) }
        // Let any callback already on the queue finish before self goes away.
        queue.sync {}
    }

    private static func notify(_ context: UnsafeMutableRawPointer?) {
        guard let context else { return }
        Unmanaged<DiskMonitor>.fromOpaque(context).takeUnretainedValue().onChange()
    }
}
