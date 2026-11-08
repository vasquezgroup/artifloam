import Foundation
import MacStewardCore
import Network
import PhotoEngine

/// Offers the newest app list to Artifloam on the iPhone that was just read, until its Apps tab picks it up.
/// See AppListLink for why only that iPhone can find or open it. Failing is fine: the list stays on the Mac either way.
final class IPhoneAppListSender: @unchecked Sendable {
    static let shared = IPhoneAppListSender()
    /// Long enough to read on the Mac, then pick up the iPhone and open the tab.
    private static let patience: TimeInterval = 600
    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "IPhoneAppListSender")

    func offer(_ report: IPhoneAppsReport) {
        guard let list = IPhoneAppList(report: report),
              let container = report.apps.first(where: { $0.bundleID == IPhoneAppList.bundleID })?.container,
              let secret = AppListLink.secret(fromContainer: container) else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let plain = try? encoder.encode(list), let sealed = AppListLink.seal(plain, secret: secret) else { return }
        let name = AppListLink.serviceName(secret: secret)
        queue.async { [self] in
            browser?.cancel()
            let browser = NWBrowser(for: .bonjour(type: AppListLink.serviceType, domain: nil), using: .tcp)
            browser.browseResultsChangedHandler = { [weak self, weak browser] results, _ in
                guard let found = results.first(where: {
                    if case .service(name, _, _, _) = $0.endpoint { return true }
                    return false
                }) else { return }
                browser?.cancel()
                self?.send(sealed, to: found.endpoint)
            }
            browser.start(queue: queue)
            self.browser = browser
            queue.asyncAfter(deadline: .now() + Self.patience) { [weak browser] in browser?.cancel() }
        }
    }

    private func send(_ data: Data, to endpoint: NWEndpoint) {
        let connection = NWConnection(to: endpoint, using: .tcp)
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready: connection.send(content: data, isComplete: true, completion: .contentProcessed { _ in })
            case .failed: connection.cancel()
            default: break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 30) { connection.cancel() }
    }
}
