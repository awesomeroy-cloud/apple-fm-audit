import Foundation
import AVFoundation

public struct TTSRequest: Sendable, Codable {
    public let model: String?
    public let input: String
    public let voice: String?
    public let responseFormat: String?
    public let speed: Double?
    public let pitch: Double?
    public let volume: Double?
    public let language: String?

    enum CodingKeys: String, CodingKey {
        case model, input, voice, speed, pitch, volume, language
        case responseFormat = "response_format"
        case pitchMultiplier = "pitch_multiplier"
    }

    public init(
        model: String? = nil,
        input: String,
        voice: String? = nil,
        responseFormat: String? = nil,
        speed: Double? = nil,
        pitch: Double? = nil,
        volume: Double? = nil,
        language: String? = nil
    ) {
        self.model = model
        self.input = input
        self.voice = voice
        self.responseFormat = responseFormat
        self.speed = speed
        self.pitch = pitch
        self.volume = volume
        self.language = language
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.model = try container.decodeIfPresent(String.self, forKey: .model)
        self.input = try container.decode(String.self, forKey: .input)
        self.voice = try container.decodeIfPresent(String.self, forKey: .voice)
        self.responseFormat = try container.decodeIfPresent(String.self, forKey: .responseFormat)
        self.speed = try container.decodeIfPresent(Double.self, forKey: .speed)
        let rawPitch = try container.decodeIfPresent(Double.self, forKey: .pitch)
        let rawPitchMult = try container.decodeIfPresent(Double.self, forKey: .pitchMultiplier)
        self.pitch = rawPitch ?? rawPitchMult
        self.volume = try container.decodeIfPresent(Double.self, forKey: .volume)
        self.language = try container.decodeIfPresent(String.self, forKey: .language)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(model, forKey: .model)
        try container.encode(input, forKey: .input)
        try container.encodeIfPresent(voice, forKey: .voice)
        try container.encodeIfPresent(responseFormat, forKey: .responseFormat)
        try container.encodeIfPresent(speed, forKey: .speed)
        try container.encodeIfPresent(pitch, forKey: .pitch)
        try container.encodeIfPresent(volume, forKey: .volume)
        try container.encodeIfPresent(language, forKey: .language)
    }
}

public struct TTSResult: Sendable {
    public let data: Data
    public let contentType: String
    public let format: String

    public init(data: Data, contentType: String, format: String) {
        self.data = data
        self.contentType = contentType
        self.format = format
    }
}

public enum TTSError: LocalizedError, CustomStringConvertible {
    case emptyInput
    case synthesisFailed(String)
    case unsupportedFormat(String)
    case conversionFailed(String)
    case fileWriteFailed(String)

    public var description: String {
        switch self {
        case .emptyInput:
            return "Input text cannot be empty"
        case .synthesisFailed(let reason):
            return "Speech synthesis failed: \(reason)"
        case .unsupportedFormat(let format):
            return "Audio format '\(format)' is not supported by macOS native CoreAudio. Supported formats: wav, aac, m4a, flac, opus, caf, pcm"
        case .conversionFailed(let reason):
            return "Audio format conversion failed: \(reason)"
        case .fileWriteFailed(let reason):
            return "Audio file writing failed: \(reason)"
        }
    }

    public var errorDescription: String? {
        return description
    }
}

public final class TTSService: Sendable {
    private let queue = DispatchQueue(label: "com.apple-fm-audit.tts", qos: .userInitiated)

    public init() {}

    private static let openAIVoiceMap: [String: String] = [
        "alloy": "com.apple.voice.premium.en-US.Zoe",
        "echo": "com.apple.voice.premium.zh-CN.Yun",
        "fable": "com.apple.voice.premium.zh-CN.Lili",
        "onyx": "com.apple.voice.premium.zh-CN.Yue",
        "nova": "com.apple.voice.premium.zh-TW.Meijia",
        "shimmer": "com.apple.voice.premium.zh-CN.Lilian"
    ]

    public func synthesize(request: TTSRequest) async throws -> TTSResult {
        let trimmed = request.input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw TTSError.emptyInput
        }

        let rawFormat = (request.responseFormat ?? "wav").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard rawFormat != "mp3" else {
            throw TTSError.unsupportedFormat("mp3 (macOS native CoreAudio encoder lacks MP3 write support; please use 'aac', 'm4a', 'flac', 'opus', 'caf', 'pcm', or 'wav')")
        }

        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let synth = AVSpeechSynthesizer()
                    let utterance = AVSpeechUtterance(string: trimmed)

                    // 1. Resolve Voice / Language (Strictly prioritize Premium neural voices)
                    var resolvedVoice: AVSpeechSynthesisVoice? = nil
                    if let rawKey = request.voice?.trimmingCharacters(in: .whitespacesAndNewlines), !rawKey.isEmpty {
                        let lowKey = rawKey.lowercased()
                        if let mappedID = Self.openAIVoiceMap[lowKey], let v = AVSpeechSynthesisVoice(identifier: mappedID) {
                            resolvedVoice = v
                        } else if let v = AVSpeechSynthesisVoice(identifier: rawKey) {
                            resolvedVoice = v
                        } else {
                            let allVoices = AVSpeechSynthesisVoice.speechVoices()
                            if let v = allVoices.first(where: { $0.quality == .premium && ($0.name.lowercased() == lowKey || $0.identifier.lowercased().contains(lowKey)) }) {
                                resolvedVoice = v
                            } else if let v = allVoices.first(where: { $0.name.lowercased() == lowKey }) {
                                resolvedVoice = v
                            } else if let v = AVSpeechSynthesisVoice(language: rawKey) {
                                resolvedVoice = v
                            }
                        }
                    }
                    if resolvedVoice == nil, let lang = request.language?.trimmingCharacters(in: .whitespacesAndNewlines), !lang.isEmpty {
                        let allVoices = AVSpeechSynthesisVoice.speechVoices()
                        resolvedVoice = allVoices.first(where: { $0.language.lowercased().hasPrefix(lang.lowercased()) && $0.quality == .premium })
                            ?? AVSpeechSynthesisVoice(language: lang)
                    }
                    if resolvedVoice == nil {
                        resolvedVoice = AVSpeechSynthesisVoice(identifier: "com.apple.voice.premium.zh-CN.Lilian")
                            ?? AVSpeechSynthesisVoice(identifier: "com.apple.voice.premium.en-US.Zoe")
                    }
                    if let voice = resolvedVoice {
                        utterance.voice = voice
                    }

                    // 2. Speed / Rate
                    if let speed = request.speed {
                        let base = AVSpeechUtteranceDefaultSpeechRate
                        let target = base * Float(speed)
                        utterance.rate = min(max(target, AVSpeechUtteranceMinimumSpeechRate), AVSpeechUtteranceMaximumSpeechRate)
                    }

                    // 3. Pitch
                    if let pitch = request.pitch {
                        utterance.pitchMultiplier = min(max(Float(pitch), 0.5), 2.0)
                    }

                    // 4. Volume
                    if let volume = request.volume {
                        utterance.volume = min(max(Float(volume), 0.0), 1.0)
                    }

                    var buffers: [AVAudioPCMBuffer] = []
                    var done = false

                    synth.write(utterance) { buffer in
                        if let pcm = buffer as? AVAudioPCMBuffer {
                            if pcm.frameLength == 0 {
                                done = true
                            } else {
                                buffers.append(pcm)
                            }
                        }
                    }

                    let start = Date()
                    while !done && Date().timeIntervalSince(start) < 60 {
                        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
                    }

                    guard let first = buffers.first, !buffers.isEmpty else {
                        throw TTSError.synthesisFailed("No audio buffers produced")
                    }

                    // Raw PCM handling
                    if rawFormat == "pcm" {
                        var pcmData = Data()
                        for buf in buffers {
                            if let channelData = buf.floatChannelData {
                                let byteCount = Int(buf.frameLength) * MemoryLayout<Float>.size
                                pcmData.append(Data(bytes: channelData[0], count: byteCount))
                            }
                        }
                        continuation.resume(returning: TTSResult(data: pcmData, contentType: "audio/pcm", format: "pcm"))
                        return
                    }

                    // Write Base WAV file with explicit inner scope to guarantee RIFF header finalization
                    let tempWavURL = URL(fileURLWithPath: NSTemporaryDirectory())
                        .appendingPathComponent("afm_tts_\(UUID().uuidString).wav")
                    defer {
                        try? FileManager.default.removeItem(at: tempWavURL)
                    }

                    do {
                        let audioFile = try AVAudioFile(forWriting: tempWavURL, settings: first.format.settings)
                        for buf in buffers {
                            try audioFile.write(from: buf)
                        }
                    }

                    if rawFormat == "wav" {
                        let wavData = try Data(contentsOf: tempWavURL)
                        continuation.resume(returning: TTSResult(data: wavData, contentType: "audio/wav", format: "wav"))
                        return
                    }

                    // Convert to target format using afconvert
                    let (ext, fFormat, dFormat, cType): (String, String, String, String) = {
                        switch rawFormat {
                        case "aac", "m4a", "mp4":
                            return ("m4a", "m4af", "aac", "audio/aac")
                        case "flac":
                            return ("flac", "flac", "flac", "audio/flac")
                        case "opus":
                            return ("caf", "caff", "opus", "audio/opus")
                        case "caf":
                            return ("caf", "caff", "aac", "audio/x-caf")
                        default:
                            return ("m4a", "m4af", "aac", "audio/aac")
                        }
                    }()

                    let tempOutURL = URL(fileURLWithPath: NSTemporaryDirectory())
                        .appendingPathComponent("afm_tts_\(UUID().uuidString).\(ext)")
                    defer {
                        try? FileManager.default.removeItem(at: tempOutURL)
                    }

                    let proc = Process()
                    proc.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
                    proc.arguments = ["-f", fFormat, "-d", dFormat, tempWavURL.path, tempOutURL.path]
                    try proc.run()
                    proc.waitUntilExit()

                    guard proc.terminationStatus == 0 else {
                        throw TTSError.conversionFailed("afconvert exited with code \(proc.terminationStatus)")
                    }

                    let outData = try Data(contentsOf: tempOutURL)
                    continuation.resume(returning: TTSResult(data: outData, contentType: cType, format: rawFormat))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
