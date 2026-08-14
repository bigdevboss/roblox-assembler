# Roblox Syscalls

Полная таблица системных вызовов интерпретатора. Один набор номеров для обеих
архитектур, разница только в том, какие регистры держат аргументы.

## ABI

| роль | x86 | RISC-V |
|------|-----|--------|
| вызов | `int 0x80` | `ecall` |
| номер | `eax` | `a7` |
| арг 1..6 | `ebx ecx edx esi edi ebp` | `a0 a1 a2 a3 a4 a5` |
| возврат 1 | `eax` | `a0` |
| возврат 2 | `ebx` (если есть) | `a1` (если есть) |

Типы аргументов:

| обозначение | что это |
|-------------|---------|
| `handle` | целое число, индекс в таблице значений машины. Instance, Vector3, Color3, CFrame, строки и другие объекты живут там |
| `ptr, len` | указатель на байты в памяти + длина. Для строк и имён |
| `number` | 32-битное число, интерпретируется как signed там, где нужен знак |

`valueHandle = -1` (0xFFFFFFFF) означает, что само значение лежит сырым числом
в следующем аргументе. Используется, когда надо передать number или boolean.

`getProperty` возвращает в первом регистре kind, во втором значение или handle:

| kind | тип | где значение |
|------|-----|--------------|
| 0 | number | во втором регистре числом |
| 1 | string | во втором регистре handle |
| 2 | boolean | во втором регистре 0 или 1 |
| 3 | Instance | во втором регистре handle |
| 4 | Vector3 | во втором регистре handle |
| 5 | Color3 | во втором регистре handle |
| 6 | CFrame | во втором регистре handle |
| 7 | nil | значения нет |

## Базовые

| номер | имя | аргументы | возврат |
|-------|-----|-----------|---------|
| 1 | exit | code | завершает машину |
| 3 | read | fd, buf, len | прочитано байт |
| 4 | write | fd, buf, len | записано байт, текст уходит в вывод |

## Объекты и сервисы

| номер | имя | аргументы | возврат |
|-------|-----|-----------|---------|
| 0x201 | createInstance | className ptr,len | handle |
| 0x202 | getService | имя ptr,len | handle |
| 0x203 | vector3 | x, y, z | handle |
| 0x204 | color3 | r, g, b | handle |
| 0x205 | cframe | x, y, z | handle |
| 0x206 | string | ptr, len | handle |
| 0x209 | setParent | handle, parentHandle (0 = Workspace) | 0 |
| 0x20A | getChild | handle, имя ptr,len | handle или 0 |
| 0x20B | childrenCount | handle | количество |
| 0x20C | getChildAt | handle, index | handle или 0 |
| 0x20F | destroy | handle | 0 |
| 0x216 | clone | handle | новый handle |
| 0x217 | waitForChild | handle, имя ptr,len | handle |

## Свойства

| номер | имя | аргументы | возврат |
|-------|-----|-----------|---------|
| 0x207 | setProperty | handle, имя ptr,len, valueHandle или -1, rawNum | 0 |
| 0x208 | getProperty | handle, имя ptr,len | kind, значение |

## События

| номер | имя | аргументы | возврат |
|-------|-----|-----------|---------|
| 0x20D | connect | handle, имя события ptr,len | connHandle |
| 0x20E | disconnect | connHandle | 0 |
| 0x213 | poll | нет | connHandle (0 = пусто), payloadHandle |

События не прерывают программу. Они падают в очередь, программа забирает их
через poll. Классический цикл: poll, обработать, wait, poll.

## Векторы и CFrame

| номер | имя | аргументы | возврат |
|-------|-----|-----------|---------|
| 0x218 | vector3Add | aHandle, bHandle | handle |
| 0x219 | vector3Sub | aHandle, bHandle | handle |
| 0x21A | vector3MulScalar | aHandle, scalar | handle |
| 0x21B | vector3Dot | aHandle, bHandle | number |
| 0x21C | vector3Cross | aHandle, bHandle | handle |
| 0x21D | magnitude | vHandle | number (floor) |
| 0x21E | cframeLookAt | posHandle, targetHandle | handle |
| 0x21F | cframeMultiply | aHandle, bHandle | handle |

## Физика и анимация

| номер | имя | аргументы | возврат |
|-------|-----|-----------|---------|
| 0x214 | raycast | originHandle, dirHandle | hitHandle или 0 |
| 0x215 | tweenProperty | objHandle, ms, свойство ptr,len, valueHandle или -1, rawNum | tweenHandle |
| 0x230 | applyImpulse | objHandle, vector3Handle | 0 |
| 0x231 | jump | humanoidHandle | 0 |
| 0x232 | walkSpeed | humanoidHandle, speed | 0 |
| 0x233 | setPosition | objHandle, x·1000, y·1000, z·1000 | 0 |
| 0x22E | loadAnimation | animatorHandle, animationIdHandle | trackHandle |
| 0x22F | playAnimation | trackHandle, fadeMs | 0 |

`setPosition` принимает координаты умноженными на 1000, чтобы ассемблер считал
в целых числах без float.

## Звук, теги, рандом

| номер | имя | аргументы | возврат |
|-------|-----|-----------|---------|
| 0x220 | playSound | objHandle, soundIdHandle, volume | soundHandle |
| 0x221 | addTag | objHandle, тег ptr,len | 0 |
| 0x222 | getTagged | тег ptr,len, index | handle или 0 |
| 0x223 | rand | maxExclusive | number |

## Вывод

| номер | имя | аргументы | возврат |
|-------|-----|-----------|---------|
| 0x211 | print | ptr, len | 0 |
| 0x212 | warn | ptr, len | 0 |
| 0x224 | printInt | number | 0, печатает decimal + перевод строки |
| 0x225 | printString | stringHandle | 0 |

## Строки

| номер | имя | аргументы | возврат |
|-------|-----|-----------|---------|
| 0x226 | stringLen | stringHandle | длина |
| 0x227 | stringGet | stringHandle, dstPtr, dstLen | скопировано, NUL в конце |

## DataStore

| номер | имя | аргументы | возврат |
|-------|-----|-----------|---------|
| 0x228 | dataStoreGet | имя ds ptr,len, ключ ptr,len | number или 0 |
| 0x229 | dataStoreSet | имя ds ptr,len, ключ ptr,len, number | 0 |
| 0x22A | dataStoreIncrement | имя ds ptr,len, ключ ptr,len, delta | новое значение |
| 0x237 | dataStoreGetString | имя ds ptr,len, ключ ptr,len | stringHandle |
| 0x238 | dataStoreSetString | имя ds ptr,len, ключ ptr,len, stringHandle | 0 |
| 0x239 | dataStoreRemove | имя ds ptr,len, ключ ptr,len | 0 |

## HTTP и JSON

| номер | имя | аргументы | возврат |
|-------|-----|-----------|---------|
| 0x22B | httpGet | url ptr,len | stringHandle тела |
| 0x236 | httpPost | url ptr,len, body ptr,len | stringHandle ответа |
| 0x22C | jsonEncode | valueHandle | stringHandle |
| 0x22D | jsonDecode | stringHandle | valueHandle |

Для HTTP нужно опубликованное место и включённый доступ к доменам в настройках.

## MessagingService

| номер | имя | аргументы | возврат |
|-------|-----|-----------|---------|
| 0x234 | messagingPublish | topic ptr,len, сообщение ptr,len | 0 |
| 0x235 | messagingSubscribe | topic ptr,len | 0, входящие идут в очередь poll |

## Время и виртуальная файловая система

| номер | имя | аргументы | возврат |
|-------|-----|-----------|---------|
| 0x210 | wait | миллисекунды | 0 |
| 0x23A | tickMs | нет | мс с запуска |
| 0x23B | fsOpen | путь ptr,len, createFlag (0 или 1) | handle или 0 |
| 0x23C | fsRead | handle | stringHandle содержимого |
| 0x23D | fsWrite | handle, stringHandle | 0 |
| 0x23E | fsDelete | путь ptr,len | 0 |
| 0x23F | fsExists | путь ptr,len | 1 или 0 |

Файловая система это дерево инстансов. `C:\Users\user\file.txt` раскладывается
в `ServerScriptService/Users/user/file.txt`, где файл это StringValue. Папки
создаются автоматически. Эти вызовы использует библиотека WinAPI, напрямую
звать их обычно не нужно.

## Импорты DLL

| номер | имя | аргументы | возврат |
|-------|-----|-----------|---------|
| 0x240 | callImport | idx | результат функции импорта |

Внутренний вызов. Его делает стаб, который загрузчик DLL ставит на место
записей таблицы импортов. idx это номер в реестре импортов машины.
