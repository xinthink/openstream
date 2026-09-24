import Foundation
import FluidAudio

// Spike-only harness for ADR-0004 gate #1, candidate A0: SenseVoiceSmall
// (CoreML / ANE) through FluidAudio, the dependency the product's
// transcription-helper already links. This is a measurement adapter, not
// product code.
//
// Modes
//   zh-smoke --wav <file> [--lang <code>]   one-shot: prints one JSON result line
//   zh-smoke                                NDJSON stdio shell (the spike protocol)
//
// NDJSON shell (C2 in prototypes/zh-asr-holder-252/README.md):
//   startup:  {"event":"ready","load_ms":N}  or  {"event":"error",...} then exit(1)
//   request:  {"id":"1","cmd":"transcribe","wav":"<base64 WAV>","lang":"yue"}
//   reply:    {"id":"1","status":"ok","text":"...","ms":312}
//   request:  {"id":"2","cmd":"ping"}  ->  {"id":"2","status":"ok"}

func elog(_ message: String) {
    FileHandle.standardError.write(Data(("zh-smoke: " + message + "\n").utf8))
}

func emit(_ object: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object) else {
        elog("failed to serialise a reply, dropping it")
        return
    }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

// Bridge the async FluidAudio API into this blocking loop, mirroring
// native/transcription-helper/Sources/transcription-helper/main.swift.
final class ResultBox<T>: @unchecked Sendable {
    var value: Result<T, Error>?
}

func blocking<T>(_ operation: @Sendable @escaping () async -> Result<T, Error>) -> Result<T, Error> {
    let box = ResultBox<T>()
    let semaphore = DispatchSemaphore(value: 0)
    Task.detached {
        box.value = await operation()
        semaphore.signal()
    }
    semaphore.wait()
    return box.value!
}

// SenseVoiceSmall language-id order (FunASR lid): 0 auto, 1 zh, 2 en, 3 yue,
// 4 ja, 5 ko, 6 nospeech. The smoke run verifies this table rather than
// trusting it; `auto` is the safe default.
func languageIndex(for code: String?) -> Int32 {
    switch code {
    case "zh", "cmn": return 1
    case "en": return 2
    case "yue": return 3
    case "ja": return 4
    case "ko": return 5
    default: return 0
    }
}

// MARK: - Arguments

var wavPath: String?
var oneShotLanguage: String?
var arguments = Array(CommandLine.arguments.dropFirst())
var cursor = 0
while cursor < arguments.count {
    switch arguments[cursor] {
    case "--wav":
        cursor += 1
        wavPath = cursor < arguments.count ? arguments[cursor] : nil
    case "--lang":
        cursor += 1
        oneShotLanguage = cursor < arguments.count ? arguments[cursor] : nil
    default:
        elog("ignoring unknown argument \"\(arguments[cursor])\"")
    }
    cursor += 1
}

// MARK: - Model load

elog("loading SenseVoiceSmall fp16 (ANE); the first run downloads ~471 MB through the model registry")
let loadStartedAt = Date()
let loaded = blocking { () -> Result<SenseVoiceModels, Error> in
    do {
        return .success(try await SenseVoiceModels.downloadAndLoad(precision: .fp16))
    } catch {
        return .failure(error)
    }
}

let loadedModels: SenseVoiceModels
switch loaded {
case .success(let models):
    loadedModels = models
case .failure(let error):
    emit(["event": "error", "message": "\(error)"])
    elog("model load failed: \(error)")
    exit(1)
}
let loadMs = Int(Date().timeIntervalSince(loadStartedAt) * 1000)
elog("model loaded in \(loadMs) ms")

// One manager per language index, built lazily: the requested variety is a
// per-request field in the spike protocol, and the manager pins it at init.
// Top-level state in main.swift is MainActor-isolated (SE-0343), so the two
// helpers that touch it are annotated to match.
var managers: [Int32: SenseVoiceManager] = [:]

@MainActor
func manager(for index: Int32) -> SenseVoiceManager {
    if let existing = managers[index] { return existing }
    let created = SenseVoiceManager(models: loadedModels, language: index)
    managers[index] = created
    return created
}

@MainActor
func transcribe(path: String, language: String?) -> Result<(String, Int), Error> {
    let box = manager(for: languageIndex(for: language))
    return blocking { () -> Result<(String, Int), Error> in
        do {
            let startedAt = Date()
            let text = try await box.transcribe(audioURL: URL(fileURLWithPath: path))
            return .success((text, Int(Date().timeIntervalSince(startedAt) * 1000)))
        } catch {
            return .failure(error)
        }
    }
}

// MARK: - One-shot mode

if let wavPath {
    switch transcribe(path: wavPath, language: oneShotLanguage) {
    case .success(let (text, ms)):
        emit([
            "event": "result",
            "wav": wavPath,
            "lang": oneShotLanguage ?? "auto",
            "load_ms": loadMs,
            "infer_ms": ms,
            "text": text,
        ])
    case .failure(let error):
        emit(["event": "error", "wav": wavPath, "message": "\(error)"])
        exit(1)
    }
    exit(0)
}

// MARK: - NDJSON shell

emit(["event": "ready", "load_ms": loadMs])

while let line = readLine(strippingNewline: true) {
    if line.isEmpty { continue }
    guard let data = line.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let id = object["id"] as? String,
          let command = object["cmd"] as? String
    else {
        elog("ignoring a malformed request line")
        continue
    }

    switch command {
    case "ping":
        emit(["id": id, "status": "ok"])

    case "transcribe":
        guard let base64 = object["wav"] as? String,
              let wav = Data(base64Encoded: base64),
              wav.count > 44
        else {
            emit(["id": id, "status": "error", "reason": "transcribe needs a base64 \"wav\" field"])
            continue
        }
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("zh-smoke-\(id).wav")
        do {
            try wav.write(to: scratch)
        } catch {
            emit(["id": id, "status": "error", "reason": "could not stage the audio: \(error)"])
            continue
        }
        let outcome = transcribe(path: scratch.path, language: object["lang"] as? String)
        try? FileManager.default.removeItem(at: scratch)
        switch outcome {
        case .success(let (text, ms)):
            emit(["id": id, "status": "ok", "text": text, "ms": ms])
        case .failure(let error):
            emit(["id": id, "status": "error", "reason": "\(error)"])
        }

    default:
        emit(["id": id, "status": "error", "reason": "unknown command \"\(command)\""])
    }
}
