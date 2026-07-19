# Velora for iPhone

Velora for iPhone is a focused, on-device voice-to-clipboard companion. Its
**Dictate to Clipboard** App Shortcut can be assigned to the iPhone Action
Button: press the button, speak, tap finish, and the transcript is copied.

## Build

Requirements: Xcode 16 or newer and XcodeGen.

```sh
cd ios
xcodegen generate
xcodebuild \
  -project VeloraMobile.xcodeproj \
  -scheme Velora \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  build
```

Open `VeloraMobile.xcodeproj` to run on an iPhone. The app requires iOS 17 or
newer. Speech recognition is deliberately configured with
`requiresOnDeviceRecognition = true`; if the selected language is not available
on-device, Velora asks the user to download that language rather than sending
audio over the network.

## Assign the Action Button

1. Launch Velora once and allow microphone and speech recognition access.
2. Open **Settings → Action Button** on a supported iPhone.
3. Choose **Shortcut**, then select **Dictate to Clipboard** under Velora.

Apple's current setup guide:
<https://support.apple.com/guide/shortcuts/apdfea15680b/ios>
