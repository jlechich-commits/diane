import Foundation
import Capacitor
import Speech
import AVFoundation

@objc(SpeechRecognitionPlugin)
public class SpeechRecognitionPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "SpeechRecognitionPlugin"
    public let jsName = "SpeechRecognition"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "requestPermissions", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "start", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "stop", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "isAvailable", returnType: CAPPluginReturnPromise)
    ]

    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    private var isListening = false

    override public func load() {
        speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    }

    @objc func requestPermissions(_ call: CAPPluginCall) {
        SFSpeechRecognizer.requestAuthorization { authStatus in
            AVAudioSession.sharedInstance().requestRecordPermission { allowed in
                DispatchQueue.main.async {
                    let speech: String
                    switch authStatus {
                    case .authorized: speech = "granted"
                    case .denied, .restricted: speech = "denied"
                    case .notDetermined: speech = "prompt"
                    @unknown default: speech = "denied"
                    }
                    call.resolve([
                        "speechRecognition": speech,
                        "microphone": allowed ? "granted" : "denied"
                    ])
                }
            }
        }
    }

    @objc func isAvailable(_ call: CAPPluginCall) {
        call.resolve(["available": speechRecognizer?.isAvailable ?? false])
    }

    @objc func start(_ call: CAPPluginCall) {
        let language = call.getString("language") ?? "en-US"
        let partialResults = call.getBool("partialResults") ?? false

        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: language)),
              recognizer.isAvailable else {
            call.reject("Speech recognizer not available")
            return
        }
        speechRecognizer = recognizer

        // Stop any existing recognition
        stopRecognition()

        // Configure audio session for simultaneous playback + recording
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth, .mixWithOthers])
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            call.reject("Audio session error: \(error.localizedDescription)")
            return
        }

        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest = recognitionRequest else {
            call.reject("Unable to create recognition request")
            return
        }
        recognitionRequest.shouldReportPartialResults = partialResults

        // Use on-device recognition if available (faster, more private)
        if #available(iOS 13, *) {
            recognitionRequest.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        }

        let inputNode = audioEngine.inputNode

        var hasResolved = false

        recognitionTask = recognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            guard let self = self else { return }

            if let result = result {
                let text = result.bestTranscription.formattedString

                if partialResults {
                    // Emit partial results as events
                    self.notifyListeners("partialResults", data: [
                        "matches": [text]
                    ])

                    // If final result in continuous mode, also emit
                    if result.isFinal {
                        self.notifyListeners("partialResults", data: [
                            "matches": [text]
                        ])
                        self.stopRecognition()
                        self.notifyListeners("end", data: [:])
                    }
                } else {
                    // One-shot mode — resolve the promise with the result
                    if result.isFinal && !hasResolved {
                        hasResolved = true
                        let alternatives = result.bestTranscription.segments.map { $0.substring }
                        call.resolve(["matches": alternatives.isEmpty ? [text] : [text]])
                        self.stopRecognition()
                    }
                }
            }

            if let error = error {
                if !hasResolved {
                    hasResolved = true
                    if partialResults {
                        // In continuous mode, just notify end
                        self.notifyListeners("end", data: [:])
                    } else {
                        call.reject("Recognition error: \(error.localizedDescription)")
                    }
                }
                self.stopRecognition()
            }
        }

        let recordingFormat = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
            isListening = true

            if partialResults {
                // In continuous mode, resolve immediately — results come via events
                call.resolve(["status": "started"])
            }
        } catch {
            call.reject("Audio engine error: \(error.localizedDescription)")
            stopRecognition()
        }
    }

    @objc func stop(_ call: CAPPluginCall) {
        stopRecognition()
        call.resolve()
    }

    private func stopRecognition() {
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        isListening = false
    }
}
