section .bss
win_buf: resb 64
win_handles: resd 8
win_hdata: resb 2048
win_hsize: resd 8
win_hpos: resd 8
win_hused: resb 8
win_last_error: resd 1

section .text

win_strlen:
    push ebx
    mov ebx, eax
win_sl_loop:
    cmp byte [eax], 0
    je win_sl_done
    inc eax
    jmp win_sl_loop
win_sl_done:
    sub eax, ebx
    pop ebx
    ret

PathNormalizeA:
    push esi
    push edi
    push ebp
    mov esi, eax
    mov edi, ebx
    xor ebp, ebp
win_pn_loop:
    cmp ebp, 48
    jae win_pn_done
    mov al, [esi]
    test al, al
    jz win_pn_done
    cmp al, 58
    je win_pn_bad
    cmp al, 92
    je win_pn_bad
    cmp al, 47
    je win_pn_bad
    cmp al, 'A'
    jb win_pn_chk2
    cmp al, 'Z'
    jbe win_pn_store
win_pn_chk2:
    cmp al, 'a'
    jb win_pn_chk3
    cmp al, 'z'
    jbe win_pn_store
win_pn_chk3:
    cmp al, '0'
    jb win_pn_chk4
    cmp al, '9'
    jbe win_pn_store
win_pn_chk4:
    cmp al, '_'
    je win_pn_store
    cmp al, '-'
    je win_pn_store
win_pn_bad:
    mov al, '_'
win_pn_store:
    mov [edi], al
    inc esi
    inc edi
    inc ebp
    jmp win_pn_loop
win_pn_done:
    mov byte [edi], 0
    pop ebp
    pop edi
    pop esi
    ret

CreateFileA:
    push ebx
    push ecx
    push edx
    push esi
    push edi
    push ebp
    mov ebp, eax
    xor esi, esi
win_cf_find:
    cmp esi, 8
    jae win_cf_full
    cmp byte [win_hused + esi], 0
    je win_cf_found
    inc esi
    jmp win_cf_find
win_cf_found:
    mov eax, ebp
    call win_strlen
    mov ecx, eax
    mov eax, 0x23B
    mov ebx, ebp
    mov edx, 1
    int 0x80
    test eax, eax
    jz win_cf_fail
    mov [win_handles + esi*4], eax
    mov eax, 0x23C
    mov ebx, [win_handles + esi*4]
    int 0x80
    mov edi, eax
    mov eax, 0x227
    mov ebx, edi
    imul ecx, esi, 256
    add ecx, win_hdata
    mov edx, 256
    int 0x80
    mov [win_hsize + esi*4], eax
    mov dword [win_hpos + esi*4], 0
    mov byte [win_hused + esi], 1
    mov eax, esi
    jmp win_cf_ret
win_cf_full:
win_cf_fail:
    mov eax, -1
    jmp win_cf_ret
win_cf_ret:
    pop ebp
    pop edi
    pop esi
    pop edx
    pop ecx
    pop ebx
    ret

WriteFile:
    push esi
    push edi
    mov esi, eax
    mov edi, ebx
    cmp esi, 8
    jae win_wf_bad
    cmp byte [win_hused + esi], 0
    je win_wf_bad
    mov eax, [win_hpos + esi*4]
    add eax, ecx
    cmp eax, 256
    jle win_wf_clamp
    mov eax, [win_hpos + esi*4]
    mov edx, 256
    sub edx, eax
    mov ecx, edx
win_wf_clamp:
    mov eax, [win_hpos + esi*4]
    imul edx, esi, 256
    add edx, win_hdata
    add edx, eax
    push ecx
win_wf_copy:
    test ecx, ecx
    jz win_wf_copydone
    mov al, [edi]
    mov [edx], al
    inc edi
    inc edx
    dec ecx
    jmp win_wf_copy
win_wf_copydone:
    pop ecx
    mov eax, [win_hpos + esi*4]
    add eax, ecx
    mov [win_hpos + esi*4], eax
    mov ebx, [win_hsize + esi*4]
    cmp eax, ebx
    jle win_wf_done
    mov [win_hsize + esi*4], eax
win_wf_done:
    mov eax, ecx
    pop edi
    pop esi
    ret
win_wf_bad:
    mov eax, -1
    pop edi
    pop esi
    ret

ReadFile:
    push esi
    push edi
    mov esi, eax
    mov edi, ebx
    cmp esi, 8
    jae win_rf_bad
    cmp byte [win_hused + esi], 0
    je win_rf_bad
    mov eax, [win_hsize + esi*4]
    mov edx, [win_hpos + esi*4]
    sub eax, edx
    jle win_rf_eof
    cmp eax, ecx
    jle win_rf_use
    mov eax, ecx
win_rf_use:
    push eax
    mov ecx, eax
    imul edx, esi, 256
    add edx, win_hdata
    mov eax, [win_hpos + esi*4]
    add edx, eax
win_rf_copy:
    test ecx, ecx
    jz win_rf_copydone
    mov al, [edx]
    mov [edi], al
    inc edx
    inc edi
    dec ecx
    jmp win_rf_copy
win_rf_copydone:
    pop eax
    mov ecx, [win_hpos + esi*4]
    add ecx, eax
    mov [win_hpos + esi*4], ecx
    pop edi
    pop esi
    ret
win_rf_eof:
    mov eax, 0
    pop edi
    pop esi
    ret
win_rf_bad:
    mov eax, -1
    pop edi
    pop esi
    ret

CloseHandle:
    push esi
    push edi
    push ebp
    mov ebp, eax
    cmp ebp, 8
    jae win_ch_bad
    cmp byte [win_hused + ebp], 0
    je win_ch_bad
    mov eax, 0x206
    imul ebx, ebp, 256
    add ebx, win_hdata
    mov ecx, [win_hsize + ebp*4]
    int 0x80
    mov edi, eax
    mov eax, 0x23D
    mov ebx, [win_handles + ebp*4]
    mov ecx, edi
    int 0x80
    mov byte [win_hused + ebp], 0
    mov dword [win_handles + ebp*4], 0
    mov eax, 0
    pop ebp
    pop edi
    pop esi
    ret
win_ch_bad:
    mov eax, -1
    pop ebp
    pop edi
    pop esi
    ret

DeleteFileA:
    push esi
    push edi
    mov edi, eax
    call win_strlen
    mov ecx, eax
    mov eax, 0x23E
    mov ebx, edi
    int 0x80
    mov eax, 0
    pop edi
    pop esi
    ret

FileExistsA:
    push esi
    push edi
    mov edi, eax
    call win_strlen
    mov ecx, eax
    mov eax, 0x23F
    mov ebx, edi
    int 0x80
    pop edi
    pop esi
    ret

GetTickCount:
    mov eax, 0x23A
    int 0x80
    ret

MessageBoxA:
    push esi
    push edi
    mov edi, ebx
    mov ebx, win_buf
    mov byte [ebx], '['
    inc ebx
    mov esi, ecx
win_mb_cap:
    mov al, [esi]
    test al, al
    jz win_mb_capdone
    mov [ebx], al
    inc esi
    inc ebx
    jmp win_mb_cap
win_mb_capdone:
    mov byte [ebx], ']'
    inc ebx
    mov byte [ebx], ' '
    inc ebx
    mov esi, edi
win_mb_text:
    mov al, [esi]
    test al, al
    jz win_mb_textdone
    mov [ebx], al
    inc esi
    inc ebx
    jmp win_mb_text
win_mb_textdone:
    mov byte [ebx], 10
    inc ebx
    mov byte [ebx], 0
    sub ebx, win_buf
    mov ecx, ebx
    mov ebx, win_buf
    mov eax, 0x211
    int 0x80
    mov eax, 0
    pop edi
    pop esi
    ret

GetLastError:
    mov eax, [win_last_error]
    ret

SetLastError:
    mov [win_last_error], eax
    mov eax, 0
    ret
