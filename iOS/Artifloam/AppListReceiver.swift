import Foundation
import Network

/// Listens for the Mac's app list while the Apps tab is on screen. iOS asks for Local Network access the first time, so it doesn't start any sooner.
final class AppListReceiver: @unchecked Sendable {
    private var listener: NWListener?
    private let onList: @Sendable () -> Void

    init(onList: @escaping @Sendable () -> Void) { self.onList = onList }

    func start() {
        guard listener == nil, let secret = AppListLink.secret(fromContainer: NSHomeDirectory()), let listener = try? NWListener(using: .tcp) else { return }
        listener.service = NWListener.Service(name: AppListLink.serviceName(secret: secret), type: AppListLink.serviceType)
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .global(qos: .utility))
            self?.receive(on: connection, secret: secret, so: Data())
        }
        listener.start(queue: .global(qos: .utility))
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func receive(on connection: NWConnection, secret: String, so far: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, finished, error in
            let all = far + (data ?? Data())
            guard error == nil, all.count <= AppListLink.maximumBytes else { connection.cancel(); return }
            guard finished else { self?.receive(on: connection, secret: secret, so: all); return }
            connection.cancel()
            // Anything that doesn't open with the key, or isn't a list, is ignored.
            guard let plain = AppListLink.open(all, secret: secret), MacAppList.decode(plain) != nil else { return }
            var file = MacAppList.file
            try? plain.write(to: file, options: .atomic)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? file.setResourceValues(values)
            self?.onList()
        }
    }
}
