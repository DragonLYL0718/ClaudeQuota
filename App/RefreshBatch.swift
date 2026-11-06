import Foundation

/// A bounded batch whose deadline does not wait for an uncooperative network callback.
/// Late callbacks are ignored after cancellation or completion.
@MainActor
final class RefreshBatch {
    struct Request {
        let account: AccountConfig
        let generation: Int
    }

    private var pending: [Request]
    private var active: [UUID: (Request, Task<Void, Never>)] = [:]
    private let fetcher: AccountFetching
    private let concurrency: Int
    private let timeout: TimeInterval
    private let receive: (Request, Result<AccountFetchResult, Error>) -> Void
    private var continuation: CheckedContinuation<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var finished = false

    init(requests: [Request], fetcher: AccountFetching, concurrency: Int, timeout: TimeInterval,
         receive: @escaping (Request, Result<AccountFetchResult, Error>) -> Void) {
        pending = requests
        self.fetcher = fetcher
        self.concurrency = max(1, concurrency)
        self.timeout = min(300, max(0.01, timeout))
        self.receive = receive
    }

    func run() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                deadline = Task { @MainActor [weak self, timeout] in
                    do { try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000)) }
                    catch { return }
                    self?.expire()
                }
                pump()
            }
        } onCancel: {
            Task { @MainActor in self.cancelAll() }
        }
    }

    func cancel(_ id: UUID) {
        pending.removeAll { $0.account.id == id }
        if let (_, task) = active.removeValue(forKey: id) {
            task.cancel()
            fetcher.invalidate(id)
        }
        pump()
    }

    private func pump() {
        guard !finished else { return }
        while active.count < concurrency, !pending.isEmpty {
            let request = pending.removeFirst()
            let task = Task { @MainActor [weak self, fetcher] in
                let result: Result<AccountFetchResult, Error>
                do {
                    try Task.checkCancellation()
                    result = .success(try await fetcher.fetch(request.account))
                } catch { result = .failure(error) }
                self?.complete(request, result)
            }
            active[request.account.id] = (request, task)
        }
        if pending.isEmpty && active.isEmpty { finish() }
    }

    private func complete(_ request: Request, _ result: Result<AccountFetchResult, Error>) {
        guard !finished, active.removeValue(forKey: request.account.id) != nil else { return }
        receive(request, result)
        pump()
    }

    private func expire() {
        guard !finished else { return }
        let remaining = pending + active.values.map { $0.0 }
        stopRequests()
        for request in remaining {
            receive(request, .failure(ServiceError.timeout(request.account.service.displayName)))
        }
        finish()
    }

    private func cancelAll() {
        guard !finished else { return }
        stopRequests()
        finish()
    }

    private func stopRequests() {
        let running = active
        active.removeAll()
        pending.removeAll()
        for (id, (_, task)) in running {
            task.cancel()
            fetcher.invalidate(id)
        }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        deadline?.cancel()
        deadline = nil
        let waiting = continuation
        continuation = nil
        waiting?.resume()
    }
}
