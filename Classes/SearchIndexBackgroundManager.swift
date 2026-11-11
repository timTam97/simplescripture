import BackgroundTasks
import Foundation

final class SearchIndexBuildGate: @unchecked Sendable {
    static let shared = SearchIndexBuildGate()

    private let lock = NSLock()

    func perform(_ operation: () throws -> Void) rethrows {
        lock.lock()
        defer { lock.unlock() }
        try operation()
    }

    /// Whether a build is inside the gate right now, a foreground or a background
    /// one. Never waits: it is asked on the main thread, when the app becomes
    /// active (`SearchModel.indexMayHaveChanged`).
    var isHeld: Bool {
        guard lock.try() else { return true }
        lock.unlock()
        return false
    }
}

final class SearchIndexBackgroundManager {
    struct Scheduler {
        let register: (
            _ identifier: String,
            _ handler: @escaping (BGProcessingTask) -> Void
        ) -> Bool
        let submit: (
            _ request: BGProcessingTaskRequest,
            _ completion: @escaping (Error?) -> Void
        ) -> Void
        let cancel: (_ identifier: String) -> Void

        static let live = Scheduler(
            register: { identifier, handler in
                BGTaskScheduler.shared.register(
                    forTaskWithIdentifier: identifier,
                    using: nil
                ) { task in
                    guard let processingTask = task as? BGProcessingTask else {
                        task.setTaskCompleted(success: false)
                        return
                    }
                    handler(processingTask)
                }
            },
            submit: { request, completion in
                DispatchQueue.global(qos: .utility).async {
                    BGTaskScheduler.shared.submitTaskRequest(
                        request,
                        completionHandler: completion
                    )
                }
            },
            cancel: { identifier in
                BGTaskScheduler.shared.cancel(
                    taskRequestWithIdentifier: identifier
                )
            }
        )
    }

    typealias BuildOperation = (
        _ module: String,
        _ progress: PSSearchProgressBlock?
    ) throws -> Void

    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }

        func cancel() {
            lock.lock()
            cancelled = true
            lock.unlock()
        }
    }

    private let defaults: UserDefaults
    private let scheduler: Scheduler
    private let buildOperation: BuildOperation
    private let buildGate: SearchIndexBuildGate
    private let lock = NSLock()
    private var didRegister = false
    private var foregroundModule: String?
    private var backgroundCancellation: Cancellation?

    let taskIdentifier: String

    /// How many times a *background* build may fail before the recovery record is
    /// dropped. Internal rather than private so the test drives the real budget
    /// instead of hardcoding it.
    static let maxBuildAttempts = 3

    init(
        defaults: UserDefaults = .standard,
        taskIdentifier: String? = nil,
        scheduler: Scheduler = .live,
        buildGate: SearchIndexBuildGate = .shared,
        buildOperation: @escaping BuildOperation = { module, progress in
            try PSSearchEngine.engine(forModuleName: module)
                .build(progress: progress)
        }
    ) {
        self.defaults = defaults
        self.scheduler = scheduler
        self.buildGate = buildGate
        self.buildOperation = buildOperation
        let bundleIdentifier = Bundle.main.bundleIdentifier
            ?? "org.crosswire.PocketSword"
        self.taskIdentifier = taskIdentifier
            ?? "\(bundleIdentifier).search-index"
    }

    @discardableResult
    func register() -> Bool {
        lock.lock()
        guard !didRegister else {
            lock.unlock()
            return true
        }
        didRegister = true
        lock.unlock()

        let registered = scheduler.register(taskIdentifier) { [weak self] task in
            self?.handle(task)
        }
        if !registered {
            lock.lock()
            didRegister = false
            lock.unlock()
        }
        return registered
    }

    func resumePendingBuildIfNeeded() {
        guard let module = pendingModule else { return }
        scheduleRecovery(for: module)
    }

    func beginForegroundBuild(module: String) {
        lock.lock()
        foregroundModule = module
        let cancellation = backgroundCancellation
        // A fresh user-initiated build resets the background retry budget: the last
        // module's exhausted attempts must not deny this one its retries. Written under
        // the lock, with the record, because `registerFailedAttempt` reads both together
        // off a background queue.
        defaults.removeObject(forKey: Defaults.pendingSearchIndexAttempts)
        defaults.set(module, forKey: Defaults.pendingSearchIndexModule)
        lock.unlock()
        cancellation?.cancel()
        scheduleRecovery(for: module)
    }

    func finishForegroundBuild(module: String) {
        lock.lock()
        if foregroundModule == module {
            foregroundModule = nil
        }
        lock.unlock()
        clearPendingModule(ifMatching: module)
        scheduler.cancel(taskIdentifier)
    }

    var pendingModule: String? {
        defaults.string(forKey: Defaults.pendingSearchIndexModule)
    }

    private func scheduleRecovery(for module: String) {
        defaults.set(module, forKey: Defaults.pendingSearchIndexModule)
        let request = BGProcessingTaskRequest(identifier: taskIdentifier)
        request.requiresNetworkConnectivity = false
        request.requiresExternalPower = false
        scheduler.submit(request) { error in
            if let error {
                alog(
                    "Unable to schedule search index recovery for "
                        + "\(module): \(error.localizedDescription)"
                )
            }
        }
    }

    private func handle(_ task: BGProcessingTask) {
        guard let module = pendingModule else {
            task.setTaskCompleted(success: true)
            return
        }

        let cancellation = Cancellation()
        lock.lock()
        guard foregroundModule == nil else {
            lock.unlock()
            scheduleRecovery(for: module)
            task.setTaskCompleted(success: false)
            return
        }
        backgroundCancellation = cancellation
        lock.unlock()
        task.expirationHandler = {
            cancellation.cancel()
        }

        performPendingBuild(
            cancellationRequested: { cancellation.isCancelled }
        ) { [weak self] success, shouldRetry in
            guard let self else {
                task.setTaskCompleted(success: false)
                return
            }
            self.lock.lock()
            if self.backgroundCancellation === cancellation {
                self.backgroundCancellation = nil
            }
            self.lock.unlock()

            if shouldRetry {
                self.scheduleRecovery(for: module)
            }
            task.setTaskCompleted(success: success)
        }
    }

    func performPendingBuild(
        cancellationRequested: @escaping () -> Bool,
        completion: @escaping (
            _ success: Bool,
            _ shouldRetry: Bool
        ) -> Void
    ) {
        guard let module = pendingModule else {
            completion(true, false)
            return
        }

        let operation = buildOperation
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else {
                completion(false, false)
                return
            }

            var buildError: Error?
            do {
                try self.buildGate.perform {
                    try operation(module) { _, cancel in
                        cancel = cancellationRequested()
                    }
                }
            } catch {
                buildError = error
            }

            // The order is success, then expiry, then failure.
            //
            // A build that RETURNED has committed and stamped a complete index,
            // whatever the flag says by now, so that is decided first.
            // `PSSearchEngine.build` can only see a cancel at its 500-row progress
            // poll: after the last one (row 31,000 of the KJV's 31,102) the
            // remaining inserts, the COMMIT and the meta stamp cannot be stopped,
            // and a flag raised there — the task expiring, or
            // `beginForegroundBuild` cancelling — arrives with no error. Tested
            // flag-first, that was reported as an interrupted run: the record
            // stayed, `handle` resubmitted, and the next background slot opened
            // with `dropIndex()` on the finished index.
            guard let buildError else {
                // The one record a finished build must not clear: that of a
                // foreground build of the same module that began in that tail.
                // `beginForegroundBuild` has just written it, the foreground build
                // is waiting at the gate to drop and rebuild this index, and
                // `finishForegroundBuild` clears the record when it is done.
                //
                // Read under `lock` and released before `clearPendingModule`,
                // which takes the same lock — `NSLock` is not recursive.
                self.lock.lock()
                let foregroundOwnsRecord = self.foregroundModule == module
                self.lock.unlock()
                if !foregroundOwnsRecord {
                    self.clearPendingModule(ifMatching: module)
                }
                completion(true, false)
                return
            }

            // Expiration is not a failure: the recovery record stays put and
            // `handle` resubmits the request, which is the entire point of it. It
            // must be tested BEFORE the failure arm, because `PSSearchEngine.build`
            // throws `.cancelled` on expiry — so an expired run arrives with both
            // an error and the flag set, and billing the error first would spend
            // retry budget on an interruption.
            if cancellationRequested() {
                completion(false, true)
                return
            }

            // A build error is NOT automatically terminal. A full disk, an sqlite busy
            // timeout, or a process killed mid-write all throw and succeed on a later
            // attempt, and `build` drops any partial index, so a retry cannot compound.
            // Clearing the record here would leave the user with no index and no
            // retry.
            //
            // But it has to be BOUNDED: `resumePendingBuildIfNeeded()` runs from
            // `didFinishLaunching`, so a deterministic failure would otherwise re-run a
            // ~30 s background build on every cold launch, forever, invisibly.
            // Exhausting the budget clears the record; the Search tab's own build
            // button is driven by `indexIsFresh()` and never consults it.
            let willRetry = self.registerFailedAttempt(for: module)
            alog(
                "Background search index build failed for "
                + "\(module): \(buildError.localizedDescription)"
                + (willRetry
                   ? " — will retry"
                   : " — retry budget exhausted, leaving it to the Search tab")
            )
            completion(false, willRetry)
        }
    }

    /// Records one failed background attempt; returns whether a retry is left.
    ///
    /// Only a *build error* spends budget; an expiration is handled before this.
    ///
    /// **It must NOT resurrect a record that is no longer there.** A background
    /// build can fail *after* the user's own foreground build of the same module
    /// finished and cleared the record. Re-persisting a retry then would schedule a
    /// recovery build that — because `PSSearchEngine.build` opens with
    /// `dropIndex()` — DESTROYS the index the user just waited for. A missing (or
    /// reassigned) record means someone else has taken over: spend nothing.
    ///
    /// The read-modify-write runs under `lock` because `UserDefaults` is atomic per
    /// access, not across a read and a write, and this runs on a utility queue while
    /// `beginForegroundBuild` clears the counter from the main actor.
    /// `clearPendingModule` takes the same lock, so it is called only after this
    /// one is released — `NSLock` is not recursive.
    private func registerFailedAttempt(for module: String) -> Bool {
        lock.lock()
        let stillPending =
            defaults.string(forKey: Defaults.pendingSearchIndexModule) == module
        var attempts = 0
        if stillPending {
            attempts = defaults.integer(
                forKey: Defaults.pendingSearchIndexAttempts
            ) + 1
            if attempts < Self.maxBuildAttempts {
                defaults.set(attempts, forKey: Defaults.pendingSearchIndexAttempts)
            }
        }
        lock.unlock()

        guard stillPending else { return false }
        guard attempts < Self.maxBuildAttempts else {
            clearPendingModule(ifMatching: module)
            return false
        }
        return true
    }

    /// Drops the recovery record, and the counter with it.
    ///
    /// Under `lock` for the same reason `registerFailedAttempt` is: the compare and the
    /// two removes are one logical operation, and this is reached from a global utility
    /// queue as well as the main actor. No caller may hold the lock when it calls this
    /// (`NSLock` is not recursive) — `finishForegroundBuild` and `registerFailedAttempt`
    /// both release it first, deliberately.
    private func clearPendingModule(ifMatching module: String) {
        lock.lock()
        defer { lock.unlock() }
        guard defaults.string(forKey: Defaults.pendingSearchIndexModule) == module
        else { return }
        defaults.removeObject(forKey: Defaults.pendingSearchIndexModule)
        // The counter is meaningless without the module it counts for; leaving it
        // behind would poison the budget of the next module's recovery.
        defaults.removeObject(forKey: Defaults.pendingSearchIndexAttempts)
    }
}
