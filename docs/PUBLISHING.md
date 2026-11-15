# Публикация на GitHub

Рекомендуемое имя репозитория: **trenches**.

**Description:** Native iPhone camera with real-time ASCII and GPU effects. SwiftUI + Metal. iOS 18+.

**Topics:** `ios`, `swift`, `swiftui`, `metal`, `camera`, `ascii`, `shaders`, `xtool`.

## Репозиторий

В готовой папке `dist/v1.2.1/` есть `trenches-1.2.1-source.zip`. Распакуй его в отдельную папку — это чистый набор файлов для публикации.

Создай пустой публичный репозиторий на GitHub без автоматически добавленных README и лицензии. В распакованной папке выполни:

```bash
git init -b main
git add .
git commit -m "Release trenches 1.2.1"
git remote add origin https://github.com/YOUR_USERNAME/trenches.git
git push -u origin main
```

Замени `YOUR_USERNAME` на свой GitHub-логин. В репозиторий входят README, документация, MIT, исходники, ресурсы, скрипты и проверки. Кэш сборки, логи, чужие референсы и файлы подписи исключены. IPA загружается в Release.

## Release 1.2.1

1. Открой **Releases → Draft a new release**.
2. Создай тег **`v1.2.1`** на ветке `main`.
3. Заголовок: **`trenches 1.2.1`**.
4. Вставь содержимое `dist/v1.2.1/release-notes.md` в описание.
5. Приложи **`trenches-1.2.1.ipa`** и **`SHA256SUMS.txt`** из той же папки.
6. Дополнительно можно приложить `trenches-1.2.1-source.zip`; GitHub также создаёт архив исходников из тега.
7. Опубликуй релиз.

Общий IPA проверен на отсутствие профиля устройства. Личный `Trenches/xtool/Trenches.ipa` предназначен для локальной установки; в Release нужен файл из `dist/v1.2.1/`.

## Подготовить следующий релиз

Обнови версию и номер сборки в `Trenches/Info.plist`, CHANGELOG и описание в `docs/releases/`. Затем:

```bash
bash Trenches/scripts/build.sh -c release
python3 Trenches/scripts/package-release.py
```

Скрипт проверит общий IPA, сопоставит версию с исходниками и подготовит версионную папку в `dist/` с IPA, исходниками, описанием и SHA-256. Контрольные суммы можно сверить командой `sha256sum -c SHA256SUMS.txt` из этой папки.

[← README](../README.md)
