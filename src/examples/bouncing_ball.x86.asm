section .bss
partH: resd 1
tmp: resd 1
cnt: resd 1
section .data
cls: db "Part", 0
pAnchored: db "Anchored", 0
pColor: db "Color", 0
section .text
_start:
    mov eax, 0x201
    mov ebx, cls
    mov ecx, 4
    int 0x80
    mov [partH], eax
    mov eax, 0x207
    mov ebx, [partH]
    mov ecx, pAnchored
    mov edx, 8
    mov esi, -1
    mov edi, 1
    int 0x80
    mov eax, 0x204
    mov ebx, 255
    mov ecx, 90
    mov edx, 30
    int 0x80
    mov [tmp], eax
    mov eax, 0x207
    mov ebx, [partH]
    mov ecx, pColor
    mov edx, 5
    mov esi, [tmp]
    int 0x80
    mov eax, 0x209
    mov ebx, [partH]
    mov ecx, 0
    int 0x80
    mov ebp, 20000
    xor edi, edi
    mov dword [cnt], 0
loop:
    add edi, -100
    add ebp, edi
    cmp ebp, 0
    jge above
    xor ebp, ebp
    mov eax, edi
    imul eax, eax, -8
    cdq
    mov ecx, 10
    idiv ecx
    mov edi, eax
above:
    mov eax, 0x233
    mov ebx, [partH]
    mov ecx, 0
    mov edx, ebp
    mov esi, 0
    int 0x80
    mov eax, 0x210
    mov ebx, 20
    int 0x80
    inc dword [cnt]
    cmp dword [cnt], 200
    jl loop
    mov eax, 1
    xor ebx, ebx
    int 0x80
