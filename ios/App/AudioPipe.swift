import AVFoundation
import IntercomCore

/// 16 kHz mono PCM16 capture/playback via AVAudioEngine; voice-processing gives AEC (port of AudioPipe.java).
final class AudioPipe: AudioSink {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let fmt = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
    private var talking = false
    private var pending = Data()

    func start(speaker: Bool, onCapture: @escaping (Data) -> Void) {
        let s = AVAudioSession.sharedInstance()
        var opts: AVAudioSession.CategoryOptions = [.allowBluetooth, .allowBluetoothA2DP]
        if speaker { opts.insert(.defaultToSpeaker) }
        try? s.setCategory(.playAndRecord, mode: .voiceChat, options: opts)
        try? s.setActive(true)
        try? engine.inputNode.setVoiceProcessingEnabled(true)
        engine.attach(player)
        let play = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        engine.connect(player, to: engine.mainMixerNode, format: play)
        let inFmt = engine.inputNode.outputFormat(forBus: 0)
        let conv = AVAudioConverter(from: inFmt, to: fmt)
        engine.inputNode.installTap(onBus: 0, bufferSize: 2048, format: inFmt) { [weak self] buf, _ in
            guard let self = self, let conv = conv else { return }
            let cap = AVAudioFrameCount(Double(buf.frameLength) * 16000 / inFmt.sampleRate) + 16
            guard let out = AVAudioPCMBuffer(pcmFormat: self.fmt, frameCapacity: cap) else { return }
            var given = false
            conv.convert(to: out, error: nil) { _, st in
                if given { st.pointee = .noDataNow; return nil }
                given = true; st.pointee = .haveData; return buf
            }
            guard let p = out.int16ChannelData?[0] else { return }
            self.pending.append(Data(bytes: p, count: Int(out.frameLength) * 2))
            while self.pending.count >= 2560 {            // 80 ms frames
                onCapture(self.pending.prefix(2560)); self.pending.removeFirst(2560)
            }
        }
        try? engine.start(); player.play()
    }

    func play(_ pcm: Data) {
        let n = AVAudioFrameCount(pcm.count / 2)
        guard let b = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!, frameCapacity: n) else { return }
        b.frameLength = n
        pcm.withUnsafeBytes { raw in
            let src = raw.bindMemory(to: Int16.self)
            for i in 0..<Int(n) { b.floatChannelData![0][i] = Float(src[i]) / 32768 }
        }
        player.scheduleBuffer(b)
    }

    func setTalking(_ on: Bool) { talking = on }

    func stop() {
        engine.inputNode.removeTap(onBus: 0); player.stop(); engine.stop()
        pending = Data()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
