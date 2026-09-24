# Myfosa

An offline translator for iOS. A language model runs entirely on the device through [llama.cpp](https://github.com/ggml-org/llama.cpp) and Metal. Your text, voice and photos never leave the phone.

> The app interface is currently in Russian. Translation works between 33 languages.

## Features

- **Text translation** between 33 languages, with results streamed as they are generated.
- **Voice input.** Speech recognition runs on the device when it is supported for the selected language.
- **Photo translation.** Text in an image is recognized with Vision and translated. Use the camera or pick a photo from the library.
- **Read aloud.** Translations are spoken with the built-in iOS speech synthesizer.
- **Translation history** stored locally in Core Data, with per-item deletion and a full clear.
- **Automatic model unloading** from memory after a timeout (30 s to 10 min) and when the app goes to the background.
- **Model updates without an app release.** Background download with size and SHA-256 verification.
- Light, dark and system themes, first-launch onboarding, iPhone and iPad.

Supported languages: English, Russian, German, French, Spanish, Italian, Portuguese, Chinese, Japanese, Korean, Arabic, Turkish, Dutch, Polish, Ukrainian, Vietnamese, Thai, Indonesian, Malay, Hindi, Bengali, Persian, Hebrew, Czech, Greek, Romanian, Hungarian, Swedish, Danish, Finnish, Norwegian, Slovak, Bulgarian.

## Privacy

Translation, on-device text recognition and speech synthesis all run locally. The app has no accounts, no ads and no analytics.

The network is used for two things only: fetching `config.json` and downloading the model file. No text you translate is sent in those requests. If on-device speech recognition is unavailable for a language, iOS may process the audio on Apple's servers. The full policy text lives in `Myfosa/Views/PrivacyPolicyView.swift`. Before releasing, fill in the constants in `PolicyConfig` (developer name, contact email, date).

## Requirements

| | |
|---|---|
| iOS | 16.0 or later |
| Device | A physical iPhone or iPad (arm64). There is no simulator build: `llama.xcframework` ships only an `ios-arm64` slice |
| To build | A Mac with Xcode, Swift 5.9 |
| To rebuild llama | `git`, `cmake`, `python3` |

## Getting started

A prebuilt `Vendor/llama.xcframework` is committed to the repository, so you do not need to rebuild llama.cpp for a normal build.

1. Open `Myfosa.xcodeproj` in Xcode.
2. Change the bundle identifier (`com.SiaSoft.Myfosa`) to your own and select your team under Signing & Capabilities.
3. Connect an iPhone and run the `Myfosa` scheme.
4. On first launch the app offers to download the model.

## Rebuilding llama.cpp

The project uses the [chaxu01/llama.cpp](https://github.com/chaxu01/llama.cpp) fork pinned to commit `92c448af6`. It already contains the `Q2_0C` (2-bit) quantization type but has no Metal kernels for it. The bootstrap script adds them on top of the fork.

```bash
Scripts/bootstrap_llama.sh
```

The script clones the fork into `.build/llama.cpp`, applies `Scripts/patch_q2_0c_metal.sh`, builds `llama.xcframework` with Metal enabled and copies the result into `Vendor/`. Pinning the commit keeps the build reproducible.

## Model configuration

The app reads a remote `config.json` and caches it in Application Support. When offline, it falls back to the last saved copy. The URL is defined once in `Myfosa/Services/AppConfig.swift` (`ConfigEndpoint.url`).

```json
{
  "schemaVersion": 1,
  "app": { "minimumVersion": "1.0.0" },
  "model": {
    "id": "model-name",
    "version": "1",
    "fileName": "model.gguf",
    "sizeBytes": 123456789,
    "sha256": "…",
    "url": "https://example.com/model.gguf"
  }
}
```

To ship a new model, upload the file and update `id`/`version`, `sizeBytes`, `sha256` and `url` in the config. The app offers the update under Settings → Check for updates. The old file is removed only after the new one has been downloaded and verified.

## Project structure

```
Myfosa/
├── MyfosaApp.swift          Entry point, theme, onboarding
├── ViewModel.swift          App state, model load/unload, history
├── Models/                  TranslationItem, language list and display names
├── Services/
│   ├── TranslatorService    llama.cpp wrapper (model loading, streaming translation)
│   ├── AppConfig            Remote config.json and its cache
│   ├── ModelDownloadService Background model download
│   ├── ModelStore           Model storage and integrity checks
│   ├── HistoryStore         Translation history (Core Data)
│   ├── SpeechRecognizerService, SpeechSynthesizer
│   ├── CameraService, TextRecognitionService   Camera and OCR (Vision)
└── Views/                   SwiftUI screens: Translate, Camera, History, Settings, Onboarding
Scripts/                     Builds llama.xcframework with Q2_0C Metal kernels
Vendor/llama.xcframework     Prebuilt llama.cpp for iOS (arm64)
codemagic.yaml               CI build of an unsigned IPA
```

## CI

`codemagic.yaml` builds an unsigned `Myfosa-unsigned.ipa` on every push and tag to `main`. Before building, it checks that `Vendor/llama.xcframework` is present in the repository. Signing and uploading to TestFlight or the App Store require your own Apple Developer account and certificates.

## License

The project code is released under the [Apache 2.0 License](LICENSE). llama.cpp and ggml are licensed separately (MIT).
