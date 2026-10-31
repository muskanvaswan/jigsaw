import AVFoundation

/// The soft wooden tock of a piece dropping into place, synthesized so the app ships no audio files.
/// Plays through the ambient category, so it respects the silent switch and never interrupts music.
enum Click {
    private static let players: [AVAudioPlayer] = {
        try? AVAudioSession.sharedInstance().setCategory(.ambient, options: [.mixWithOthers])
        let sound = makeSound()
        return (0..<3).compactMap { _ in
            let player = try? AVAudioPlayer(data: sound)
            player?.volume = 0.45
            player?.prepareToPlay()
            return player
        }
    }()
    private static var next = 0

    static func prepare() { _ = players }

    static func play() {
        guard !players.isEmpty else { return }
        let player = players[next % players.count]
        next += 1
        player.currentTime = 0
        player.play()
    }

    private static func makeSound() -> Data {
        let rate = 44_100
        let count = rate * 9 / 100
        var noise = SeededGenerator(seed: 7)
        var samples = [Int16](repeating: 0, count: count)
        for i in 0..<count {
            let t = Double(i) / Double(rate)
            let body = sin(2 * .pi * 740 * t) * 0.6 + sin(2 * .pi * 1_870 * t) * 0.22
            let knock = Double(noise.jitter(1)) * exp(-t * 900) * 0.35
            let attack = min(1, t / 0.0015)
            let value = (body * exp(-t * 65) + knock) * attack * 0.55
            samples[i] = Int16(max(-1, min(1, value)) * Double(Int16.max))
        }

        var data = Data()
        func put(_ text: String) { data.append(contentsOf: Array(text.utf8)) }
        func put<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        put("RIFF"); put(UInt32(36 + count * 2)); put("WAVE")
        put("fmt "); put(UInt32(16)); put(UInt16(1)); put(UInt16(1))
        put(UInt32(rate)); put(UInt32(rate * 2)); put(UInt16(2)); put(UInt16(16))
        put("data"); put(UInt32(count * 2))
        samples.forEach { put($0) }
        return data
    }
}
