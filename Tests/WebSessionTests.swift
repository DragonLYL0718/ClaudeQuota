import Foundation
import XCTest

@MainActor
final class WebSessionTests: XCTestCase {
    func testDeadlineReturnsWhenUnderlyingOperationNeverCompletes() async {
        let operation = WebDeadlineOperation<Int>()
        var interrupted = false
        let start = Date()
        do {
            _ = try await operation.run(timeout: 0.03, timeoutError: ServiceError.timeout("fixture"),
                                        onInterrupt: { interrupted = true }) { _ in }
            XCTFail("An unresolved request must time out")
        } catch {
            guard case ServiceError.timeout = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertTrue(interrupted)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    func testTaskCancellationStopsOperationAndIgnoresLateCompletion() async {
        let operation = WebDeadlineOperation<Int>()
        var callback: ((Result<Int, Error>) -> Void)?
        var interrupted = false
        let task = Task { @MainActor in
            try await operation.run(timeout: 60, timeoutError: ServiceError.timeout("fixture"),
                                    onInterrupt: { interrupted = true }) { callback = $0 }
        }
        while callback == nil { await Task.yield() }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(interrupted)
        callback?(.success(42))
        callback?(.failure(ServiceError.badResponse("late callback")))
    }

    func testSuccessCancelsDeadlineWithoutInterruptingNextOperation() async throws {
        let first = WebDeadlineOperation<Int>()
        var interrupted = false
        let value = try await first.run(timeout: 0.02, timeoutError: ServiceError.timeout("first"),
                                        onInterrupt: { interrupted = true }) { $0(.success(7)) }
        XCTAssertEqual(value, 7)
        let second = WebDeadlineOperation<Int>()
        let next = try await second.run(timeout: 1, timeoutError: ServiceError.timeout("second")) { complete in
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(50))
                complete(.success(9))
            }
        }
        XCTAssertEqual(next, 9)
        XCTAssertFalse(interrupted)
    }

    func testExplicitCancellationBeforeStartCannotLeaveContinuationPending() async {
        let operation = WebDeadlineOperation<Int>()
        operation.cancel()
        var started = false
        do {
            _ = try await operation.run(timeout: 1, timeoutError: ServiceError.timeout("fixture")) { _ in started = true }
            XCTFail("Expected cancellation")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(started)
    }
}
