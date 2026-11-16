# Проверка изменений камеры и Datamosh

2026-11-16. iPhone 15 Pro Max (`iPhone16,2`), iOS 27.0.1. Подписанная debug-сборка, тесты на GPU устройства. Итог: **COMPLETE**.

Проверки модели на Swift/Linux: настройки и границы, NaN, восстановление JSON и пресетов, старт с выключенными эффектами, семь режимов Datamosh, запрет пересечений, последний кадр, отрицательные границы и переполнение, автоматические/ручные сбросы, preroll для Transfer, undo/redo, масштабирование пресетов, отмена.

Отчёт с устройства:

```text
PASS Metal compilation / glyph atlas
PASS nonempty BGRA render
PASS effect dof
PASS effect bloom
PASS effect tone
PASS effect color
PASS effect post
PASS effect ascii
PASS effect shakal
PASS effect macroblock
PASS effect lensFlare
PASS stationary motion blur / temporal initialization
PASS motion-dependent blur on translated checkerboard
PASS Datamosh melt / deterministic seed / segment boundaries
PASS Datamosh bloom / deterministic seed / segment boundaries
PASS Datamosh freeze / deterministic seed / segment boundaries
PASS Datamosh transfer / deterministic seed / segment boundaries
PASS Datamosh macroblock / deterministic seed / segment boundaries
PASS Datamosh vector / deterministic seed / segment boundaries
PASS Datamosh echo / deterministic seed / segment boundaries
PASS dense optical flow / interval and manual buffer resets
PASS PCM audio degradation / sample count and timing
PASS mixed-mode MOV export / bit-exact compressed audio / exact frame count / deterministic scrubbing
PASS 10-effect stack / JPEG encoding
PASS missing-depth behavior
PASS HEVC/MOV finish / readable video track
BENCH ASCII 6px / 300%, 1080x1920
THROUGHPUT: 1690.6 render FPS, p95 3.1 ms, 0 skipped
MOVING + AUDIO 30: 30.1 render FPS, p95 4.4 ms, 0 skipped, 240/240 encoded frames, 30.00 encoded FPS, 0 drops
COMPLETE
```

Datamosh проверялся на синтетической последовательности 96×160 со сменой сцены и движением: каждый режим отдельно, чередование режимов в одном MOV, два вида оценки движения, сбросы, повторяемость скраббинга, число кадров, длительность и побайтовое совпадение сжатого AAC до/после экспорта. Это проверяет функциональность, но не измеряет качество оптического потока или скорость экспорта 4K. Замер 1080p/30 относится к ASCII, а не Datamosh.

Рендер-проверки не заменяют ручную проверку жестов, удобства таймлайна, оптических переходов и звука на слух. iOS 18 проверена по доступности API при сборке; физическое устройство с этой версией не использовалось.

Ручная проверка на том же iPhone: пользователь подтвердил открытие редактора после записи, добавление точек и смену режима. Найденная при этом ошибка первого кадра была вызвана повторным PTS=0 в passthrough-таблице MOV. После исключения пустых edit-list записей и дублирующих времён пользователь повторно открыл то же видео и подтвердил отсутствие ложного сообщения при добавлении/удалении точек. В диагностический сценарий добавлен захват с ненулевым дробным временем камеры и перемешанные переходы по всем кадрам; он собирается, но повторный GPU-прогон этой добавленной проверки не запускался.
