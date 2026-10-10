import AVFoundation
import Foundation
import os

/// Lock-protected ring of interleaved stereo Int16 samples. The original used a lock-free ring
/// built on the Synchronization module (macOS 15+); this one uses os_unfair_lock with very short
/// critical sections so it also runs on macOS 13.
final class AudioRing {
    private let storage: UnsafeMutablePointer<Int16>
    private let capacity: Int
    private var head = 0
    private var tail = 0
    private let lock: UnsafeMutablePointer<os_unfair_lock>

    init(capacity requested: Int) {
        var power = 1
        while power < requested { power <<= 1 }
        capacity = power
        storage = .allocate(capacity: power)
        storage.initialize(repeating: 0, count: power)
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
    }

    deinit {
        storage.deallocate()
        lock.deallocate()
    }

    var occupancy: Double {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        return Double(head - tail) / Double(capacity)
    }

    func clear() {
        os_unfair_lock_lock(lock)
        tail = head
        os_unfair_lock_unlock(lock)
    }

    /// Writes silence until the ring is `fraction` full (the rate-control setpoint).
    func prefill(fraction: Double) {
        os_unfair_lock_lock(lock)
        let target = Int(Double(capacity) * fraction) & ~1
        while head - tail < target {
            storage[head & (capacity - 1)] = 0
            head += 1
        }
        os_unfair_lock_unlock(lock)
    }

    @discardableResult
    func write(_ samples: UnsafePointer<Int16>, count: Int) -> Int {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        let n = min(capacity - (head - tail), count)
        guard n > 0 else { return 0 }
        for i in 0..<n { storage[(head + i) & (capacity - 1)] = samples[i] }
        head += n
        return n
    }

    func read(into destination: UnsafeMutablePointer<Int16>, max count: Int) -> Int {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        let n = min(head - tail, count)
        guard n > 0 else { return 0 }
        for i in 0..<n { destination[i] = storage[(tail + i) & (capacity - 1)] }
        tail += n
        return n
    }

    /// Gives back samples that were read but not consumed (consumer thread only).
    func unread(_ count: Int) {
        os_unfair_lock_lock(lock)
        tail -= min(count, tail)
        os_unfair_lock_unlock(lock)
    }
}

/// Variable-ratio linear resampler (stereo Int16 → two Float32 channels), as in the original
/// StereoResampler. Runs on the audio render thread; scratch memory is preallocated.
final class StereoResampler {
    private var previousLeft: Float = 0, previousRight: Float = 0
    private var currentLeft: Float = 0, currentRight: Float = 0
    private var fraction = 1.0
    private let scratchCapacity = 65536
    private let scratch: UnsafeMutablePointer<Int16>

    init() {
        scratch = .allocate(capacity: scratchCapacity)
        scratch.initialize(repeating: 0, count: scratchCapacity)
    }

    deinit { scratch.deallocate() }

    func render(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int, ring: AudioRing, step: Double) {
        let wanted = min((Int(Double(frames) * step) + 4) * 2, scratchCapacity)
        let got = ring.read(into: scratch, max: wanted)
        let available = got / 2
        var index = 0
        for frame in 0..<frames {
            while fraction >= 1.0 {
                previousLeft = currentLeft
                previousRight = currentRight
                if index < available {
                    currentLeft = Float(scratch[index * 2]) / 32768
                    currentRight = Float(scratch[index * 2 + 1]) / 32768
                    index += 1
                } else {
                    currentLeft = 0
                    currentRight = 0
                }
                fraction -= 1.0
            }
            let mix = Float(fraction)
            left[frame] = previousLeft + (currentLeft - previousLeft) * mix
            right[frame] = previousRight + (currentRight - previousRight) * mix
            fraction += step
        }
        if available > index { ring.unread((available - index) * 2) }
    }
}

/// Plays the core's audio through AVAudioEngine. Dynamic rate control (from the original
/// FramePacer.resampleRatio) nudges the resample ratio by up to ±0.5% with ring occupancy so
/// the core's clock and the sound card's clock never drift apart.
final class AudioOutput {
    private let engine = AVAudioEngine()
    private let ring = AudioRing(capacity: 16384)
    private let resampler = StereoResampler()
    private let step: UnsafeMutablePointer<Double>
    private var sourceRate = 44100.0
    private var deviceRate = 48000.0
    private var speed = 1.0
    private var node: AVAudioSourceNode?
    private(set) var isRunning = false
    private var observer: NSObjectProtocol?

    init() {
        step = .allocate(capacity: 1)
        step.initialize(to: 1.0)
    }

    deinit {
        stop()
        step.deallocate()
    }

    var volume: Float {
        get { engine.mainMixerNode.outputVolume }
        set { engine.mainMixerNode.outputVolume = max(0, min(1, newValue)) }
    }

    func start(sourceRate: Double) throws {
        self.sourceRate = sourceRate
        deviceRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        if deviceRate <= 0 { deviceRate = 48000 }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: deviceRate, channels: 2) else {
            throw CoreError.openFailed("no usable audio output format")
        }
        self.step.pointee = sourceRate * speed / deviceRate
        let ring = self.ring, resampler = self.resampler, stepPointer = self.step
        let source = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard buffers.count >= 2,
                let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            resampler.render(left: left, right: right, frames: Int(frameCount), ring: ring, step: stepPointer.pointee)
            return noErr
        }
        node = source
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        ring.clear()
        ring.prefill(fraction: 0.5)
        try engine.start()
        isRunning = true
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            // Output device changed (headphones, AirPlay): restart on the new device.
            try? self?.engine.start()
        }
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        if isRunning { engine.stop() }
        isRunning = false
        if let node { engine.detach(node) }
        node = nil
    }

    func setSourceRate(_ rate: Double) {
        sourceRate = rate
        step.pointee = sourceRate * speed / deviceRate
    }

    func setSpeed(_ value: Double) {
        speed = value
        step.pointee = sourceRate * speed / deviceRate
    }

    /// Core thread: queue a batch of interleaved stereo frames.
    func write(_ samples: UnsafePointer<Int16>, frames: Int) {
        ring.write(samples, count: frames * 2)
    }

    func resync() {
        ring.clear()
        ring.prefill(fraction: 0.5)
    }

    /// Core thread, once per frame.
    func updateRateControl() {
        let base = sourceRate * speed / deviceRate
        let occupancy = min(max(ring.occupancy, 0), 1)
        step.pointee = base * (1 + 0.005 * (2 * occupancy - 1))
    }
}
