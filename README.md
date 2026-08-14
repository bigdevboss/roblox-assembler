# Roblox Assembler

Два интерпретатора ассемблера и загрузчик скомпилированных DLL для Roblox Studio.
Всё на чистом Luau со строгой типизацией, без внешних зависимостей.

Один скрипт читает текст ассемблера и исполняет его на виртуальной машине.
Второй скрипт это то же самое для клиента. Загрузчик берёт настоящие байты
DLL (машинный код из GCC или Clang), разбирает PE, применяет релокации,
резолвит импорты и запускает функции.

## Что внутри

**x86 (32 бита).** Полное целочисленное ядро: `mov add sub adc sbb and or xor
cmp test`, `inc dec`, `push pop pusha popa`, `call ret jmp` и все `jcc`,
`loop`, `lea`, `imul` в 1/2/3 формах, `mul div idiv`, `not neg`, сдвиги
`shl shr sar rol ror`, `movzx movsx`, `setcc` и `cmovcc` (30 условий), битовые
`bt bts btr btc bsf bsr`, `enter leave`, строковые `movsb stosb lodsb cmpsb
scasb` с `rep`, флаги `clc stc cmc lahf sahf`, `int` и `hlt`. EFLAGS с битами
как у настоящего процессора.

**RISC-V RV32IMAFD.** Ядро I, умножение M, атомики A (`lr.w sc.w amoadd
amoswap` и остальные), float F (single, с округлением до float32), double D.
Плюс псевдоинструкции `li la mv j jr ret call beqz bnez` и компактные
`fmv.s fabs.s fneg.s`. Регистры `x0..x31` и ABI-имена `a0..a7 t0..t6 s0..s11`.

**Загрузчик DLL.** Парсит PE32 (i386), декодирует машинный код, применяет
базовые релокации `.reloc`, резолвит экспорты и импорты. Импорты эмулируются:
`call [IAT]` ведёт в стаб, который зовёт Luau-обработчик. Уже есть
`msvcrt.dll` (`printf strlen malloc free memcpy memset exit`), `KERNEL32.dll`
(`GetTickCount Sleep ExitProcess`), `USER32.dll` (`MessageBoxA`).

**WinAPI поверх Roblox.** Библиотека `.include "winapi"` эмулирует файлы:
`CreateFileA WriteFile ReadFile CloseHandle DeleteFileA FileExistsA
MessageBoxA GetTickCount`. Путь `C:\Users\user\file.txt` превращается в
дерево инстансов `ServerScriptService/Users/user/file.txt` (файл это
StringValue). Работает только x86.

**Roblox API через syscall.** 63 вызова от `0x201` до `0x240`: Instance,
Vector3, Color3, CFrame, свойства, события, Tween, клонирование, физика,
DataStore, HttpService, JSON, MessagingService, рандом, вывод.

**Отладчик.** Брейкпоинты по метке или адресу, шаг, шаг с обходом вызовов,
дамп регистров и памяти, backtrace. Работает для обеих архитектур.

## Структура

```
x86asm/
├── serverAsm/init.server.luau     серверный интерпретатор (Script)
├── clientAsm/init.client.luau     клиентский интерпретатор (LocalScript)
├── examples/
│   ├── spiral.rv32.asm            спираль из 60 кубов (RISC-V)
│   └── bouncing_ball.x86.asm      прыгающий мяч (x86)
├── lib/winapi.asm                 исходник библиотеки WinAPI
└── install.luau                   одна команда для Command Bar
dll-demo/
├── cdemo.dll                      скомпилированный C (машинный код GCC)
└── build_cdemo.py                 как собрать эту DLL
```

## Как поставить в Studio

Самый быстрый способ это одна команда.

1. В Studio открой View, затем Toolbars, затем Command.
2. Вставьте целиком содержимое `install.luau` в Command Bar и нажмите Enter.
3. Нажмите Play.

Команда создаст `serverAsm` в ServerScriptService, `clientAsm` в
StarterPlayerScripts и папку `assembler` с тремя программами. После Play
в Workspace появится спираль и мяч, а в Output напечатается
`== C inside Roblox ==` и `add(40, 2) = 42`.

Чтобы поставить вручную: вставьте содержимое `serverAsm/init.server.luau` в Script
с именем `serverAsm` внутри ServerScriptService, а содержимое
`clientAsm/init.client.luau` в LocalScript с именем `clientAsm` внутри
StarterPlayerScripts.

## Как пользоваться

### Программа на ассемблере

Программа это ModuleScript, который возвращает строку. Положите его в папку
`assembler` любого видимого сервиса или пометьте тегом `assembler`.
Интерпретатор найдёт его сам и выполнит в отдельном потоке.

```lua
-- ReplicatedStorage/assembler/hello
return [[
section .data
msg: db "hi", 10, 0
section .text
_start:
    mov eax, 0x211
    mov ebx, msg
    mov ecx, 3
    int 0x80
    mov eax, 1
    xor ebx, ebx
    int 0x80
]]
```

### Выбор архитектуры

Первой строкой поставьте флаг или директиву:

```asm
--!risc-v     RISC-V
--!x86        x86 (по умолчанию)
.rv32         то же, что --!risc-v
.x86          то же, что --!x86
```

Комментарии `;`, `--` и `#`. Директивы данных `db dw dd byte half word`,
резервирование `resb resw resd space`, константы `equ`, секции
`section .text .data .bss`. Неизвестные флаги вроде `--!strict` игнорируются.

### Сисколлы

Один набор номеров для обеих архитектур. x86 зовёт через `int 0x80`
(номер в `eax`, аргументы в `ebx ecx edx esi edi ebp`), RISC-V через `ecall`
(номер в `a7`, аргументы в `a0..a5`). Базовые: `1` exit, `4` write, `3` read.

Группы Roblox-вызовов (полный список смотрите в `serverAsm/init.server.luau`,
таблица `roboxDispatch`):

| диапазон | что делает |
|----------|------------|
| 0x201..0x214 | Instance, Vector3, Color3, CFrame, свойства, события, raycast |
| 0x215..0x223 | Tween, clone, waitForChild, векторная математика, звук, теги, рандом |
| 0x224..0x236 | вывод чисел и строк, DataStore, HTTP, JSON, анимация, физика, MessagingService |
| 0x237..0x23F | виртуальная файловая система (для WinAPI) |
| 0x240 | вызов эмулированного импорта DLL |

### WinAPI

Подключите библиотеку и пишите в виндовом стиле:

```asm
.include "winapi"
section .data
path: db "C:\Users\user\note.txt", 0
text: db "hello from file", 0
section .text
_start:
    mov eax, path
    xor ebx, ebx
    call CreateFileA
    mov ebp, eax
    mov eax, ebp
    mov ebx, text
    mov ecx, 14
    call WriteFile
    mov eax, ebp
    call CloseHandle
    mov eax, 1
    xor ebx, ebx
    int 0x80
```

Файл появится в Explorer как `ServerScriptService/Users/user/note.txt`.

### DLL (скомпилированный C)

Байты DLL лежат в ModuleScript как base64 или hex. Загрузчик распознаёт и
hex (`4D5A...`), и base64 (`TVo...`) автоматически. Если у DLL есть экспорт
`main`, бутстрап вызовет его сам.

```lua
local x86 = require(serverAsm)
local data = require(ReplicatedStorage.assembler.c_library)
local bytes = x86.bytesFromData(data)
local m = x86.new()
x86.callExport(m, bytes, "say_hi")   -- печатает через printf и возвращает 123
```

Полезные функции: `loadPE`, `disasmPE`, `disasmAt`, `listExports`,
`listImports`, `callExport`, `bytesFromData`.

## Примеры

**spiral.rv32.asm.** RISC-V с F расширением. Строит спираль из 60 цветных
кубов: таблица синуса, signed умножение и деление, радиус 14 метров, высота
30 метров, градиент цвета. Смотрите в Workspace после Play.

**bouncing_ball.x86.asm.** x86. Прыгающий мяч на fixed-point физике:
гравитация, отскок с потерей энергии, 200 кадров через syscall wait.

**cdemo.dll.** Настоящий машинный код GCC. Исходник `int say_hi(void){
printf("Hello from C! %d + %d = %d\n", 2, 40, 42); return 123; }`
скомпилирован в `gcc -m32 -O0`. Экспорты `say_hi`, `read_global`, `main`.
`main` печатает `== C inside Roblox ==` и `add(40, 2) = 42`. Внутри
релокации `.reloc` и импорт `msvcrt.printf`.

## Проверено

318 тестов зелёные: ядро x86, все расширения RISC-V, WinAPI, загрузчик DLL,
вызов C-функций, отладчик. Строгий типчек Luau без ошибок.

## Что дальше

Полный msvcrt (`sprintf puts strcmp`), prefetch всех экспортов DLL,
поддержка x64 и SSE, GUI отладчика в Studio.
