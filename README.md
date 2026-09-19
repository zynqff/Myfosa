# Myfosa iOS — release source

Нативное iOS-приложение по ТЗ `TZ_local_translator_ios.md`.

## llama.cpp

ТЗ требует официальный `llama.cpp` SwiftUI/XCFramework путь. Репозиторий не вшит в этот архив, потому что XCFramework занимает сотни мегабайт и должен собираться под конкретную версию llama.cpp.

1. Откройте `Myfosa.xcodeproj` на Mac с Xcode.
2. Выполните `Scripts/bootstrap_llama.sh`.
3. Добавьте полученный `build-apple/llama.xcframework` в `Vendor/` проекта и в target `Myfosa`.
4. Соберите на реальном iPhone. Для simulator GPU Metal отключается в коде, как в официальном примере.
5. 

Скрипт фиксирует commit llama.cpp, чтобы релиз был воспроизводимым.

## Signing

Bundle ID в проекте: `com.SiaSoft.Myfosa` — замените на свой перед архивированием.

Для App Store/TestFlight потребуется собственная Apple Developer Team и подпись. Для локальной установки можно использовать обычный provisioning через Xcode.

Hi guys! (Zynqochka)
