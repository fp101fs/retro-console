import Foundation

/// Runs one core on its own thread (never the main thread): load, frame loop with wall-clock
/// pacing, audio feed, battery saves, and a command queue for save states / reset.
final class EmulatorEngine {
    let box = FrameBox()
    let audio = AudioOutput()

    private let coreURL: URL
    private let gameURL: URL
    private let gameID: String
    private let systemName: String
    private let input: InputState

    private let stateLock = NSLock()
    private var paused = false
    private var speed = 1.0
    private var stopRequested = false
    private var commands: [() -> Void] = []
    private let finished = DispatchSemaphore(value: 0)
    private var started = false
    private var stopped = false

    init(coreURL: URL, gameURL: URL, gameID: String, systemName: String, input: InputState) {
        self.coreURL = coreURL
        self.gameURL = gameURL
        self.gameID = gameID
        self.systemName = systemName
        self.input = input
    }

    // MARK: Control (any thread)

    func setPaused(_ value: Bool) { stateLock.lock(); paused = value; stateLock.unlock() }

    func setSpeed(_ value: Double) {
        stateLock.lock(); speed = value; stateLock.unlock()
        audio.setSpeed(value)
    }

    /// Runs `work` on the emulation thread between frames; `completion` runs on the main thread.
    func perform<T>(_ work: @escaping (CoreSession) throws -> T, completion: @escaping (Result<T, Error>) -> Void) {
        stateLock.lock()
        commands.append { [weak self] in
            guard self != nil, let session = CoreSession.current else { return }
            let result = Result { try work(session) }
            DispatchQueue.main.async { completion(result) }
        }
        stateLock.unlock()
    }

    func reset() {
        perform({ $0.reset() }, completion: { _ in })
    }

    // MARK: Lifecycle

    func start(completion: @escaping (Result<Void, Error>) -> Void) {
        guard !started else { return }
        started = true
        let thread = Thread { [self] in self.threadMain(completion: completion) }
        thread.name = "Retro Console emulation"
        thread.stackSize = 16 * 1024 * 1024
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// Stops the thread and waits for it, so the next game can start on a clean core slot.
    func stop() {
        guard started, !stopped else { return }
        stopped = true
        stateLock.lock(); stopRequested = true; stateLock.unlock()
        _ = finished.wait(timeout: .now() + 5)
    }

    // MARK: Thread

    private func threadMain(completion: @escaping (Result<Void, Error>) -> Void) {
        let dataDirectory = AppPaths.dataDirectory(forGame: gameID)
        let session: CoreSession
        CrashGuard.arm(core: coreURL.lastPathComponent, game: gameURL.lastPathComponent, system: systemName)
        do {
            session = try CoreSession(coreURL: coreURL, systemDirectory: AppPaths.systemDirectory, saveDirectory: dataDirectory)
        } catch {
            CrashGuard.disarm()
            DispatchQueue.main.async { completion(.failure(error)) }
            finished.signal()
            return
        }

        let audio = self.audio, box = self.box
        session.inputProvider = { [input] in input.bits }
        session.onVideo = { data, width, height, pitch, format in
            box.store(bytes: PixelConverter.bgra(from: data, width: width, height: height, pitch: pitch, format: format),
                      width: width, height: height)
        }
        var currentSpeed = 1.0
        session.onAudio = { samples, frames in
            // Fast-forward is silent; slow motion keeps playing (the resampler stretches it).
            if currentSpeed <= 1.0 { audio.write(samples, frames: frames) }
        }
        session.onTimingChange = { [unowned session] in audio.setSourceRate(session.sampleRate) }

        do {
            try session.loadGame(path: gameURL.path)
        } catch {
            session.shutdown()
            CrashGuard.disarm()
            DispatchQueue.main.async { completion(.failure(error)) }
            finished.signal()
            return
        }

        box.aspect = session.aspect
        let batteryURL = SaveStates.batteryURL(game: gameID)
        if let saved = try? Data(contentsOf: batteryURL) { session.restoreSaveRAM(saved) }
        var lastBattery = session.saveRAMSnapshot()
        do { try audio.start(sourceRate: session.sampleRate) } catch { /* no sound device: play silently */ }
        audio.volume = AppSettings.shared.volume
        DispatchQueue.main.async { completion(.success(())) }

        var deadline = ProcessInfo.processInfo.systemUptime
        var batteryTimer = deadline
        var wasPaused = false
        while true {
            stateLock.lock()
            let stopNow = stopRequested
            let isPaused = paused
            currentSpeed = speed
            let queued = commands
            commands.removeAll()
            stateLock.unlock()
            if stopNow { break }
            queued.forEach { $0() }
            box.aspect = session.aspect

            if isPaused {
                wasPaused = true
                Thread.sleep(forTimeInterval: 0.016)
                deadline = ProcessInfo.processInfo.systemUptime
                continue
            }
            if wasPaused {
                audio.resync()
                wasPaused = false
            }

            session.runFrame()
            audio.updateRateControl()

            let frameTime = 1.0 / (max(session.fps, 1) * currentSpeed)
            deadline += frameTime
            let now = ProcessInfo.processInfo.systemUptime
            if deadline > now {
                Thread.sleep(forTimeInterval: deadline - now)
            } else if now - deadline > 0.1 {
                deadline = now   // fell behind (slow core or a stall): do not burst to catch up
            }

            if now - batteryTimer > 5 {
                batteryTimer = now
                if let current = session.saveRAMSnapshot(), current != lastBattery {
                    try? current.write(to: batteryURL, options: .atomic)
                    lastBattery = current
                }
            }
        }

        audio.stop()
        if let current = session.saveRAMSnapshot(), current != lastBattery || !FileManager.default.fileExists(atPath: batteryURL.path) {
            try? current.write(to: batteryURL, options: .atomic)
        }
        session.shutdown()
        CrashGuard.disarm()
        finished.signal()
    }
}
