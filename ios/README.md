# Velora for iPhone

Velora for iPhone is a focused, on-device voice-to-clipboard companion. Its
**Dictate to Clipboard** App Shortcut can be assigned to the iPhone Action
Button: press the button, speak, tap finish, and the transcript is copied.

## Build

Requirements: Xcode 26 or newer and XcodeGen.

```sh
cd ios
xcodegen generate
xcodebuild \
  -project VeloraMobile.xcodeproj \
  -scheme Velora \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=latest' \
  build
```

Open `VeloraMobile.xcodeproj` to run on an iPhone. The app requires iOS 17 or
newer. Audio stays on the device: iOS 26 uses Apple's newer `SpeechTranscriber`
when it is available, while the compatibility recognizer is deliberately
configured with `requiresOnDeviceRecognition = true`. If the selected language
is not available on-device, Velora asks the user to check Siri & Dictation or
choose another language rather than sending audio over the network.

## Speech model and efficiency

Velora does not bundle the Mac app's Whisper, MLX, or Qwen models on iPhone. It
uses Apple-owned system models that add no model files to the app bundle:

- On iOS 26, Velora prefers `SpeechAnalyzer` with the newer
  `SpeechTranscriber` model. Apple describes it as faster and more flexible than
  the previous recognizer, and its assets are installed and updated by iOS.
- On iOS 17–25, or when the newer model or its assets are unavailable,
  Velora falls back to `SFSpeechRecognizer` with
  `requiresOnDeviceRecognition = true`. It never falls back to server speech.
- On iOS 26 with Apple Intelligence available, dictations of six words or more
  are cleaned by Apple's on-device Foundation Model. Cleanup is prewarmed while
  recording, has a five-second budget, preserves names/numbers, and falls back
  to deterministic cleanup if the result changes too much. Short phrases,
  mostly non-Latin text, Code, and Raw avoid that model pass for lower latency.
- Every supported iPhone gets fast, model-free cleanup for unambiguous fillers,
  spoken breaks and punctuation, capitalization, and Message/Code endings.

The formatting style is explicit: Auto, Message, Email, Note, Code, or Raw. iOS
does not give a normal app access to another app's accessibility tree, so Velora
cannot safely infer the future paste destination the way the Mac app can. The
selected style remains active until changed in the Dictate screen or Settings.
If Apple Intelligence is disabled, still downloading, or unsupported, Settings
shows **Basic formatting** and dictation continues with the deterministic path.
The first iOS 26 dictation may take longer while iOS installs the selected
speech-language asset.

Apple documents that the older on-device recognition request can be less
accurate than server recognition. The iOS 26 path is the preferred efficiency
and quality path; the older recognizer remains a compatibility fallback.

References:

- [Apple: `requiresOnDeviceRecognition`](https://developer.apple.com/documentation/speech/sfspeechrecognitionrequest/requiresondevicerecognition)
- [Apple: Bring advanced speech-to-text to your app with SpeechAnalyzer](https://developer.apple.com/videos/play/wwdc2025/277/)
- [Apple: Foundation Models](https://developer.apple.com/documentation/foundationmodels)

## Assign the Action Button

1. Launch Velora once and allow microphone and speech recognition access.
2. Open **Settings → Action Button** on a supported iPhone.
3. Choose **Shortcut**, then select **Dictate to Clipboard** under Velora.

Apple's current setup guide:
<https://support.apple.com/guide/shortcuts/apdfea15680b/ios>
