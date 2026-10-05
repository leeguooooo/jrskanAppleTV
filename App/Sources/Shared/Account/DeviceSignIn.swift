import Foundation

/// RFC 8628 device sign-in: the TV shows a code, the viewer approves it on
/// their phone in the account center (where every sign-in method is
/// available), and the TV polls until the approval lands.
@MainActor
final class DeviceSignInModel: ObservableObject {
    enum Status: Equatable {
        case idle
        case requesting
        case waiting(DeviceAuthorization)
        case expired
        case denied
        case failed(String)
        case completed
    }

    @Published private(set) var status: Status = .idle

    private let sleep: (TimeInterval) async throws -> Void
    private let now: () -> Date
    private var task: Task<Void, Never>?

    init(sleep: @escaping (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
         now: @escaping () -> Date = Date.init) {
        self.sleep = sleep
        self.now = now
    }

    var authorization: DeviceAuthorization? {
        if case .waiting(let authorization) = status { return authorization }
        return nil
    }

    func start(session: AccountSession) {
        task?.cancel()
        task = Task { await run(session: session) }
    }

    func cancel() {
        task?.cancel()
        task = nil
        if case .waiting = status { status = .idle }
    }

    /// Exposed for tests; `start` runs it in a task.
    func run(session: AccountSession) async {
        status = .requesting
        let authorization: DeviceAuthorization
        do {
            authorization = try await session.api.requestDeviceCode()
        } catch {
            if !Task.isCancelled { status = .failed(error.localizedDescription) }
            return
        }
        guard !Task.isCancelled else { return }
        status = .waiting(authorization)

        let deadline = now().addingTimeInterval(TimeInterval(authorization.expiresIn))
        var interval = TimeInterval(max(authorization.interval, 1))
        while !Task.isCancelled {
            do { try await sleep(interval) } catch { return }
            if now() >= deadline {
                status = .expired
                return
            }
            do {
                let tokens = try await session.api.pollDeviceToken(deviceCode: authorization.deviceCode)
                await session.complete(with: tokens)
                status = .completed
                return
            } catch AccountError.oauth("authorization_pending", _) {
                continue
            } catch AccountError.oauth("slow_down", _) {
                interval += 5
            } catch AccountError.oauth("expired_token", _) {
                status = .expired
                return
            } catch AccountError.oauth("access_denied", _) {
                status = .denied
                return
            } catch AccountError.network {
                // A Wi-Fi blip should not throw away a code the viewer is typing in.
                interval = min(interval * 2, 30)
            } catch {
                status = .failed(error.localizedDescription)
                return
            }
        }
    }
}
