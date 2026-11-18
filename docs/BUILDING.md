# Сборка

Проект — Swift Package в `Trenches/`. Основной проверенный путь: **Windows → WSL2 Ubuntu → xtool → iPhone по USB**.

## Окружение

- Swift 6+, настроенный [xtool и Darwin SDK](https://github.com/xtool-org/xtool).
- iOS SDK 26+ для компиляции новых API; deployment target приложения — iOS 18.0.
- Bash, Python 3.9+, `rsync`; для проверки подписанного IPA — OpenSSL.
- Для установки из WSL: `usbipd-win`, `libimobiledevice`, `ideviceinstaller` и Clang.

Проверенная конфигурация: xtool 1.24.0, Swift 6.4.2, iOS SDK 27.2. SDK устанавливается отдельно средствами xtool; в репозитории его нет.

## Общий IPA

Из корня репозитория в WSL:

```bash
bash Trenches/scripts/build.sh -c release
python3 Trenches/scripts/inspect-ipa.py Trenches/xtool/Trenches-share.ipa --unsigned
```

Результат: `Trenches/xtool/Trenches-share.ipa`. Он не содержит профиля устройства и требует подписи получателя.

Скрипт копирует проект в `~/.cache/trenches-build` на файловой системе WSL, собирает и возвращает IPA. Это обходит проблемы копирования метаданных с NTFS. Исходники меняй в репозитории, а не в кэше. Не запускай две сборки этого проекта одновременно: они используют один кэш.

## Подпись и установка на своё устройство

Настрой свой Apple ID и устройство по [инструкции xtool](https://github.com/xtool-org/xtool). При создании форка выбери собственный `bundleID` в `Trenches/xtool.yml`; это создаст отдельное приложение.

```bash
bash Trenches/scripts/build.sh --sign -c release
python3 Trenches/scripts/inspect-ipa.py Trenches/xtool/Trenches.ipa
bash Trenches/scripts/install.sh
```

Для WSL сначала подключи разблокированный iPhone и пробрось его из PowerShell:

```powershell
usbipd list
usbipd attach --wsl --busid <BUSID_телефона>
```

Подставь BUSID Apple Mobile Device из вывода, подтверди доверие и включи режим разработчика. После переподключения USB-проброс может понадобиться повторить.

В Linux `install.sh` использует ideviceinstaller с локальным адаптером AFC-записи по 4 КиБ — обход [зависания больших USBIP-передач](https://github.com/libimobiledevice/usbmuxd/issues/247). Адаптер действует только в процессе установки. В других средах используется `xtool install`.

## Проверки

```bash
bash Trenches/scripts/test-settings.sh
```

Проверяются настройки, границы параметров, восстановление JSON, пресеты, профили записи и модель Datamosh (пересечения, границы, сбросы, undo/redo, пресеты, отмена). GitHub Actions запускает эту проверку и проверяет синтаксис скриптов; полный iOS-билд в CI не настроен.

Диагностика на своём iPhone:

```bash
TRENCHES_VERIFY=1 bash Trenches/scripts/build.sh --sign -c debug
bash Trenches/scripts/install.sh
```

Открой trenches вручную. Режим проверит Metal, десять live-эффектов, статичный и движущийся Motion Blur, семь режимов Datamosh, сбросы и скраббинг, смешанный экспорт с точным копированием AAC, JPEG/MOV и запись движущегося ASCII 1080p/30 со синтетическим звуком. После COMPLETE или FAIL:

```bash
python3 Trenches/scripts/read-verification.py
```

Обычная сборка возвращает камеру. Счётчики последней реальной записи читаются отдельно:

```bash
python3 Trenches/scripts/read-verification.py --camera
```

Утилита определяет Bundle ID из локального подписанного IPA. При другой подписи передай `--bundle-id <ID>`. Она читает только текстовый отчёт приложения, без фото и видео.

При ошибке скраббинга Datamosh последний технический отчёт с временными метками читается отдельно:

```bash
python3 Trenches/scripts/read-verification.py --datamosh
```

Отчёт содержит запрошенный индекс, временную шкалу и состояние декодера; изображения и звуковые данные в него не записываются.

## Где что находится

| Файл | Назначение |
| --- | --- |
| `CameraService.swift` | Сессия камеры, глубина, очередь кадров и запись |
| `FrameRenderer.swift`, `Shaders/Effects.metal` | Core Image и Metal-эффекты |
| `CameraPreview.swift` | Отображение готовых кадров через Metal |
| `MovieRecorder.swift` | HEVC / H.264 + AAC, временная шкала и завершение MOV |
| `CameraModel.swift`, `ContentView.swift`, `EffectPanels.swift` | Состояние и SwiftUI-интерфейс |
| `EffectSettings.swift` | Параметры и пресеты |
| `AudioDegrader.swift` | PCM sample-and-hold и bitcrush с сохранением временной шкалы |
| `DatamoshDocument.swift` | Диапазоны, ограничения, история и пресеты |
| `DatamoshRenderer.swift` | Блочное предсказание на Metal, квантованный остаток и повреждённая опора |
| `DatamoshMedia.swift` | Декодирование, скраббинг, поиск диапазонов и последовательный экспорт |
| `DatamoshEditor.swift`, `DatamoshTimeline.swift`, `DatamoshEditorModel.swift` | Превью, таймлайн, зацикливание и отмена задач |

Файлы находятся в `Trenches/Sources/Trenches/`. Новые API ограничены `#available(iOS 26.0, *)`; старые устройства используют совместимый путь. Поздние кадры отбрасываются, очереди ограничены. Камера/качество/источник глубины переключаются между записями.

[← README](../README.md)
