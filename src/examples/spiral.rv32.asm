.rv32
section .data
sin: .word 0, 174, 342, 500, 643, 766, 866, 940, 985, 1000, 985, 940, 866, 766, 643, 500, 342, 174, 0, -174, -342, -500, -643, -766, -866, -940, -985, -1000, -985, -940, -866, -766, -643, -500, -342, -174
cls: .byte "Part", 0
pAnchored: .byte "Anchored", 0
pColor: .byte "Color", 0
pSize: .byte "Size", 0
section .bss
partH: .space 4
tmp: .space 4
section .text
_start:
    li s0, 0
loop:
    li t0, 60
    bge s0, t0, done
    mv a0, s0
    li a1, 36
    rem t1, a0, a1
    addi t2, t1, 9
    rem t2, t2, a1
    la t3, sin
    slli t4, t1, 2
    add t4, t4, t3
    lw s1, 0(t4)
    slli t4, t2, 2
    add t4, t4, t3
    lw s2, 0(t4)
    addi t5, t1, 1
    li t6, 400
    mul t5, t5, t6
    mul a0, t5, s1
    li a1, 1000
    div a0, a0, a1
    mv s3, a0
    mul a0, t5, s2
    li a1, 1000
    div a0, a0, a1
    mv s4, a0
    li t6, 500
    mul s5, s0, t6
    la a0, cls
    li a1, 4
    li a7, 0x201
    ecall
    la t0, partH
    sw a0, 0(t0)
    la t0, partH
    lw a0, 0(t0)
    la a1, pAnchored
    li a2, 8
    li a3, -1
    li a4, 1
    li a7, 0x207
    ecall
    li a0, 2000
    li a1, 2000
    li a2, 2000
    li a7, 0x203
    ecall
    la t0, tmp
    sw a0, 0(t0)
    la t0, partH
    lw a0, 0(t0)
    la a1, pSize
    li a2, 4
    la t0, tmp
    lw a3, 0(t0)
    li a7, 0x207
    ecall
    li t0, 4
    mul a0, s0, t0
    andi a0, a0, 255
    mv s6, a0
    li t0, 255
    li t1, 4
    mul t2, s0, t1
    sub a1, t0, t2
    li t0, 8
    mul a2, s0, t0
    andi a2, a2, 255
    mv a0, s6
    li a7, 0x204
    ecall
    la t0, tmp
    sw a0, 0(t0)
    la t0, partH
    lw a0, 0(t0)
    la a1, pColor
    li a2, 5
    la t0, tmp
    lw a3, 0(t0)
    li a7, 0x207
    ecall
    la t0, partH
    lw a0, 0(t0)
    mv a1, s3
    mv a2, s5
    mv a3, s4
    li a7, 0x233
    ecall
    la t0, partH
    lw a0, 0(t0)
    li a1, 0
    li a7, 0x209
    ecall
    addi s0, s0, 1
    j loop
done:
    li a0, 0
    li a7, 1
    ecall
