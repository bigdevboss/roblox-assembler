--!strict

















local x86: { [string]: any } = {}




type RegInfo = { field: string, size: number, hi: boolean }

type StrTok = { t: "str", v: string }
type CharTok = { t: "char", v: number }
type Token = string | StrTok | CharTok

type MemOperand = { kind: "mem", base: string?, index: string?, scale: number, disp: any, size: number? }
type Operand =
    | { kind: "reg", name: string, size: number }
    | { kind: "imm", val: number?, expr: {Token}? }
    | MemOperand

type Ctx = {
    labels: { [string]: number },
    equ: { [string]: number },
    here: number,
    mode: number,
    usedSym: boolean,
    line: number,
    target: any,
}

type Machine = {
    regs: { [string]: number },
    eflags: number,
    mem: { number },
    code: { any },
    codeByAddr: { [number]: any },
    labels: { [string]: number },
    stdout: { string },
    stdin: string,
    stdinPos: number,
    onOutput: ((string) -> ())?,
    stepCount: number,
    maxSteps: number,
    exited: boolean,
    exitCode: number,
    error: string?,
    hitBreakpoint: boolean,
    paused: boolean,
    pauseReason: string?,
    breakpoints: { [number]: boolean },
    values: { any },
    nextHandle: number,
    eventQueue: { any },
    target: any,
    csr: { any },
    fregs: { [string]: number },
    reservation: { addr: number, valid: boolean },
    imports: { any },
    heapTop: number,
}

type RunResult = { ok: boolean, output: string?, exitCode: number?, error: string?, machine: Machine }




local bit32lib = bit32
local band = bit32lib.band
local bor = bit32lib.bor
local bxor = bit32lib.bxor
local bnot = bit32lib.bnot
local lshift = bit32lib.lshift
local rshift = bit32lib.rshift
local arshift = bit32lib.arshift




local MASKS = { [8] = 0xFF, [16] = 0xFFFF, [32] = 0xFFFFFFFF }
local MSBS  = { [8] = 0x80, [16] = 0x8000, [32] = 0x80000000 }


local CF, PF, AF, ZF, SF, DF, OF = 0x0001, 0x0004, 0x0010, 0x0040, 0x0080, 0x0400, 0x0800


local PARITY: { [number]: boolean } = {}
for i = 0, 255 do
    local n = i
    local c = 0
    while n > 0 do
        c = c + (n % 2)
        n = (n - (n % 2)) / 2
    end
    PARITY[i + 1] = (c % 2 == 0)
end

local MEM_SIZE = 0x100000  
local STACK_TOP = 0x100000

local function rotl(v: number, n: number, w: number): number
    n = n % w
    if n == 0 then return band(v, MASKS[w]) end
    return band(bor(lshift(v, n), rshift(v, w - n)), MASKS[w])
end
local function rotr(v: number, n: number, w: number): number
    n = n % w
    if n == 0 then return band(v, MASKS[w]) end
    return band(bor(rshift(v, n), lshift(v, w - n)), MASKS[w])
end




local REG_BY_NAME: { [string]: RegInfo } = {}
local function reg(field: string, size: number, hi: boolean): RegInfo
    return { field = field, size = size, hi = hi }
end
for _, f in ipairs({ "eax", "ecx", "edx", "ebx", "esp", "ebp", "esi", "edi" }) do
    REG_BY_NAME[f] = reg(f, 32, false)
end
REG_BY_NAME.ax = reg("eax", 16, false); REG_BY_NAME.cx = reg("ecx", 16, false)
REG_BY_NAME.dx = reg("edx", 16, false); REG_BY_NAME.bx = reg("ebx", 16, false)
REG_BY_NAME.sp = reg("esp", 16, false); REG_BY_NAME.bp = reg("ebp", 16, false)
REG_BY_NAME.si = reg("esi", 16, false); REG_BY_NAME.di = reg("edi", 16, false)
REG_BY_NAME.al = reg("eax", 8, false);  REG_BY_NAME.cl = reg("ecx", 8, false)
REG_BY_NAME.dl = reg("edx", 8, false);  REG_BY_NAME.bl = reg("ebx", 8, false)
REG_BY_NAME.ah = reg("eax", 8, true);   REG_BY_NAME.ch = reg("ecx", 8, true)
REG_BY_NAME.dh = reg("edx", 8, true);   REG_BY_NAME.bh = reg("ebx", 8, true)




local RV_ABI: { [string]: number } = {
    zero = 0, ra = 1, sp = 2, gp = 3, tp = 4,
    t0 = 5, t1 = 6, t2 = 7,
    s0 = 8, fp = 8, s1 = 9,
    a0 = 10, a1 = 11, a2 = 12, a3 = 13, a4 = 14, a5 = 15, a6 = 16, a7 = 17,
    s2 = 18, s3 = 19, s4 = 20, s5 = 21, s6 = 22, s7 = 23, s8 = 24, s9 = 25, s10 = 26, s11 = 27,
    t3 = 28, t4 = 29, t5 = 30, t6 = 31,
}
local RV_REG_NAME: { [string]: string } = {}
for name, idx in pairs(RV_ABI) do
    RV_REG_NAME[name] = "x" .. tostring(idx)
end
for i = 0, 31 do
    RV_REG_NAME["x" .. tostring(i)] = "x" .. tostring(i)
end
local RV_ABI_NAMES: { [number]: string } = {}
for name, idx in pairs(RV_ABI) do
    RV_ABI_NAMES[idx] = name
end


local RV_CSR: { [string]: number } = {
    cycle = 0xC00, time = 0xC01, instret = 0xC02,
    cycleh = 0xC80, timeh = 0xC81, instreth = 0xC82,
    mstatus = 0x300, mtvec = 0x305, mscratch = 0x340, mepc = 0x341, mcause = 0x342,
}


local RV_FREG_NAME: { [string]: string } = {}
for i = 0, 31 do
    RV_FREG_NAME["f" .. tostring(i)] = "f" .. tostring(i)
end
local RV_FABI: { [string]: number } = {
    ft0 = 0, ft1 = 1, ft2 = 2, ft3 = 3, ft4 = 4, ft5 = 5, ft6 = 6, ft7 = 7,
    fs0 = 8, fs1 = 9,
    fa0 = 10, fa1 = 11, fa2 = 12, fa3 = 13, fa4 = 14, fa5 = 15, fa6 = 16, fa7 = 17,
    fs2 = 18, fs3 = 19, fs4 = 20, fs5 = 21, fs6 = 22, fs7 = 23, fs8 = 24, fs9 = 25, fs10 = 26, fs11 = 27,
    ft8 = 28, ft9 = 29, ft10 = 30, ft11 = 31,
}
for name, idx in pairs(RV_FABI) do
    RV_FREG_NAME[name] = "f" .. tostring(idx)
end
local RV_FABI_NAMES: { [number]: string } = {}
for name, idx in pairs(RV_FABI) do
    RV_FABI_NAMES[idx] = name
end




local function signExtend(v: number, w: number): number
    if w >= 32 then return band(v, 0xFFFFFFFF) end
    if band(v, MSBS[w]) ~= 0 then v = bor(v, bnot(MASKS[w])) end
    return band(v, 0xFFFFFFFF)
end
local function signedw(v: number, w: number): number
    v = band(v, MASKS[w])
    if band(v, MSBS[w]) ~= 0 then return v - (MASKS[w] + 1) end
    return v
end


local function mul32(a: number, b: number): (number, number)
    local a0 = band(a, 0xFFFF)
    local a1 = rshift(a, 16)
    local b0 = band(b, 0xFFFF)
    local b1 = rshift(b, 16)
    local p00 = a0 * b0
    local p01 = a0 * b1
    local p10 = a1 * b0
    local p11 = a1 * b1
    local mid = p01 + p10
    local lo = p00 + lshift(mid, 16)
    local hi = p11 + rshift(mid, 16) + math.floor(lo / 4294967296.0)
    return band(hi, 0xFFFFFFFF), band(lo, 0xFFFFFFFF)
end


local function div64_32(hi: number, lo: number, d: number): (number, number)
    local r = hi
    local q = 0
    for i = 31, 0, -1 do
        local bit = rshift(band(lo, lshift(1, i)), i)
        r = r * 2 + bit
        if r >= d then
            r = r - d
            q = bor(q, lshift(1, i))
        end
    end
    return q, r
end

local function idivq(a: number, b: number): number
    local q = math.abs(a) // math.abs(b)
    if (a < 0) ~= (b < 0) then q = -q end
    return q
end
local function imod(a: number, b: number): number
    return a - idivq(a, b) * b
end






local F32_MIN = 1.1754943508222875e-38
local F32_POW149 = 2.0 ^ 149
local F32_POW126 = 2.0 ^ -126

local function f32FromBits(b: number): number
    b = band(b, 0xFFFFFFFF)
    local sign = band(b, 0x80000000) ~= 0
    local exp = band(rshift(b, 23), 0xFF)
    local frac = band(b, 0x7FFFFF)
    local x: number
    if exp == 0xFF then
        x = (frac == 0) and math.huge or (0 / 0)
    elseif exp == 0 then
        x = (frac / 8388608.0) * F32_POW126
    else
        x = (1.0 + frac / 8388608.0) * (2.0 ^ (exp - 127))
    end
    if sign then x = -x end
    return x
end

local function f32Bits(x: number): number
    if x ~= x then return 0x7FC00000 end
    local neg = (x < 0) or (x == 0 and (1.0 / x) < 0)
    local signBit = neg and 0x80000000 or 0
    local ax = math.abs(x)
    if ax == math.huge then return signBit + 0x7F800000 end
    if ax == 0 then return signBit end
    if ax < F32_MIN then
        local f = math.floor(ax * F32_POW149 + 0.5)
        return signBit + band(f, 0x7FFFFF)
    end
    local m, e = math.frexp(ax)
    local scaled = m * 16777216.0
    local fl = math.floor(scaled)
    local frac = scaled - fl
    local mant = fl
    if frac > 0.5 then mant = fl + 1
    elseif frac == 0.5 then mant = (fl % 2 == 0) and fl or fl + 1 end
    if mant >= 16777216.0 then
        mant = mant / 2.0
        e = e + 1
    end
    local expField = e + 126
    if expField >= 255 then return signBit + 0x7F800000 end
    return signBit + lshift(expField, 23) + band(mant - 8388608.0, 0x7FFFFF)
end

local function f32(x: number): number
    return f32FromBits(f32Bits(x))
end






local function f64FromBits(lo: number, hi: number): number
    local packed = string.pack("<I4I4", band(lo, 0xFFFFFFFF), band(hi, 0xFFFFFFFF))
    local vals: {any} = { string.unpack("<d", packed) }
    return vals[1] :: number
end
local function f64Bits(x: number): (number, number)
    local packed = string.pack("<d", x)
    local vals: {any} = { string.unpack("<I4I4", packed) }
    return vals[1] :: number, vals[2] :: number
end




local function machineFail(m: Machine, msg: string): ()
    if m.exited and m.error ~= nil then return end
    m.error = msg
    m.exited = true
    if m.exitCode == 0 then m.exitCode = -1 end
end

local function machineEmit(m: Machine, s: string): ()
    m.stdout[#m.stdout + 1] = s
    if m.onOutput ~= nil then
        local ok = pcall(m.onOutput, s)
        if not ok then machineFail(m, "onOutput hook errored") end
    end
end

local function machineGetOutput(m: Machine): string
    return table.concat(m.stdout)
end



local function machineReadStr(m: Machine, addr: number, maxLen: number?): string
    maxLen = maxLen or 4096
    local out: {string} = {}
    for i = 0, maxLen - 1 do
        local b = m.mem[band(addr + i, 0xFFFFFFFF) + 1]
        if b == 0 then break end
        out[#out + 1] = string.char(b)
    end
    return table.concat(out)
end

local function machineWriteStr(m: Machine, addr: number, s: string): ()
    for i = 1, #s do
        m.mem[band(addr + i - 1, 0xFFFFFFFF) + 1] = string.byte(s, i)
    end
    m.mem[band(addr + #s, 0xFFFFFFFF) + 1] = 0
end

local function machineHandle(m: Machine, v: any): number
    if v == nil then return 0 end
    m.nextHandle += 1
    m.values[m.nextHandle] = v
    return m.nextHandle
end

local function machineDeref(m: Machine, h: number): any
    return m.values[h or 0]
end

local function machineEnqueueEvent(m: Machine, conn: number, payload: any): ()
    m.eventQueue[#m.eventQueue + 1] = {
        conn = conn,
        payload = (payload ~= nil) and machineHandle(m, payload) or 0,
    }
end


local function loadUint(m: Machine, addr: number, w: number): number
    if m.exited then return 0 end
    local a = band(addr, 0xFFFFFFFF)
    local n = w // 8
    if a + n > MEM_SIZE then
        machineFail(m, string.format("segmentation fault (read 0x%X)", a))
        return 0
    end
    local v = 0
    for i = 1, n do
        v = v + lshift(m.mem[a + i], 8 * (i - 1))
    end
    return v
end
local function storeUint(m: Machine, addr: number, w: number, v: number): ()
    if m.exited then return end
    local a = band(addr, 0xFFFFFFFF)
    local n = w // 8
    if a + n > MEM_SIZE then
        machineFail(m, string.format("segmentation fault (write 0x%X)", a))
        return
    end
    for i = 1, n do
        m.mem[a + i] = band(rshift(band(v, 0xFFFFFFFF), 8 * (i - 1)), 0xFF)
    end
    if m.reservation ~= nil and m.reservation.valid and m.reservation.addr == a then
        m.reservation.valid = false
    end
end


local function getf(m: Machine, f: number): boolean
    return band(m.eflags, f) ~= 0
end
local function setf(m: Machine, f: number, on: boolean): ()
    if on then m.eflags = bor(m.eflags, f) else m.eflags = band(m.eflags, bnot(f)) end
end





local x86Target: any = {}
local rv32Target: any = {}




local function tokenize(line: string): {Token}
    local tokens: {Token} = {}
    local i, n = 1, #line
    while i <= n do
        local c = line:sub(i, i)
        if c == " " or c == "\t" or c == "," then
            i = i + 1
        elseif c == ";" then
            break
        elseif c == "[" or c == "]" or c == "+" or c == "-" or c == "*" or c == ":" or c == "(" or c == ")" then
            tokens[#tokens + 1] = c
            i = i + 1
        elseif c == "$" then
            tokens[#tokens + 1] = "$"
            i = i + 1
        elseif c == "'" then
            local j = i + 1
            local v: number
            if line:sub(j, j) == "\\" then
                local esc = line:sub(j + 1, j + 1)
                if esc == "n" then v = 10 elseif esc == "t" then v = 9
                elseif esc == "0" then v = 0 elseif esc == "\\" then v = 92
                elseif esc == "'" then v = 39 else v = string.byte(esc) end
                j = j + 2
            else
                v = string.byte(line:sub(j, j))
                j = j + 1
            end
            local tok: CharTok = { t = "char", v = v }
            tokens[#tokens + 1] = tok
            i = j + 1
        elseif c == '"' then
            local j = i + 1
            local s: {string} = {}
            while j <= n and line:sub(j, j) ~= '"' do
                if line:sub(j, j) == "\\" then
                    local esc = line:sub(j + 1, j + 1)
                    if esc == "n" then s[#s + 1] = "\n" elseif esc == "t" then s[#s + 1] = "\t"
                    elseif esc == "0" then s[#s + 1] = "\0" elseif esc == "\\" then s[#s + 1] = "\\"
                    elseif esc == '"' then s[#s + 1] = '"' else s[#s + 1] = esc end
                    j = j + 2
                else
                    s[#s + 1] = line:sub(j, j)
                    j = j + 1
                end
            end
            local tok: StrTok = { t = "str", v = table.concat(s) }
            tokens[#tokens + 1] = tok
            i = j + 1
        else
            local j = i
            while j <= n do
                local ch = line:sub(j, j)
                if ch:match("[%w_.$]") then j = j + 1 else break end
            end
            if j == i then
                
                i = i + 1
            else
                tokens[#tokens + 1] = line:sub(i, j - 1)
                i = j
            end
        end
    end
    return tokens
end

local function parseNum(s: any): number?
    if type(s) ~= "string" then return nil end
    local str: string = s :: string
    if str:sub(1, 2) == "0x" or str:sub(1, 2) == "0X" then return tonumber(str:sub(3), 16) end
    if str:sub(1, 2) == "0b" or str:sub(1, 2) == "0B" then return tonumber(str:sub(3), 2) end
    if str:sub(1, 2) == "0o" or str:sub(1, 2) == "0O" then return tonumber(str:sub(3), 8) end
    if str:match("^%d+$") then return tonumber(str) end
    return nil
end

local function slice(tokens: {Token}, a: number, b: number): {Token}
    local out: {Token} = {}
    for i = a, b - 1 do out[#out + 1] = tokens[i] end
    return out
end

local function errAt(ctx: Ctx, msg: string): never
    error(msg .. " (line " .. tostring(ctx.line or "?") .. ")", 0)
end




local function parsePrimary(tokens: {Token}, i: number, ctx: Ctx): (number, number)
    local t: Token? = tokens[i]
    if t == nil then errAt(ctx, "expected expression, got end of line") end
    if t == "$" then ctx.usedSym = true; return ctx.here, i + 1 end
    if t == "-" then local v, j = parsePrimary(tokens, i + 1, ctx); return -v, j end
    if t == "+" then return parsePrimary(tokens, i + 1, ctx) end
    if type(t) == "table" then
        if t.t == "char" then return t.v, i + 1 end
        errAt(ctx, "string not allowed in expression")
    end
    local tok: string = t :: string
    local num = parseNum(tok)
    if num ~= nil then return num, i + 1 end
    ctx.usedSym = true
    if ctx.equ[tok] ~= nil then return ctx.equ[tok], i + 1 end
    if ctx.labels[tok] ~= nil then return ctx.labels[tok], i + 1 end
    if ctx.mode == 1 then return 0, i + 1 end  
    errAt(ctx, "unknown symbol: " .. tok)
    return 0, i + 1  
end

local function parseExpr(tokens: {Token}, i: number, ctx: Ctx): (number, number)
    local v, j = parsePrimary(tokens, i, ctx)
    while tokens[j] == "+" or tokens[j] == "-" do
        local op = tokens[j]
        local w, k = parsePrimary(tokens, j + 1, ctx)
        if op == "+" then v = v + w else v = v - w end
        j = k
    end
    return v, j
end



local function parseDispExpr(tokens: {Token}, i: number, ctx: Ctx): (number, number)
    local v, j = parsePrimary(tokens, i, ctx)
    while tokens[j] == "+" or tokens[j] == "-" do
        local nxt = tokens[j + 1]
        if nxt == nil or nxt == "]" or nxt == "*" or (type(nxt) == "string" and REG_BY_NAME[nxt] ~= nil) then break end
        local op = tokens[j]
        local w, k = parsePrimary(tokens, j + 1, ctx)
        if op == "+" then v = v + w else v = v - w end
        j = k
    end
    return v, j
end







local function x86ParseMem(tokens: {Token}, i: number, ctx: Ctx): (MemOperand, number)
    local j = i + 1
    local base: string? = nil
    local index: string? = nil
    local scale: number = 1
    local sign: number = 1
    local dispTerms: {any} = {}
    while tokens[j] ~= "]" do
        if tokens[j] == "+" then sign = 1; j = j + 1
        elseif tokens[j] == "-" then sign = -1; j = j + 1 end
        local tk: Token? = tokens[j]
        if tk == nil then errAt(ctx, "unclosed '['") end
        local r: RegInfo? = (type(tk) == "string") and REG_BY_NAME[tk] or nil
        if r ~= nil then
            if r.size ~= 32 then errAt(ctx, "only 32-bit registers allowed in addressing") end
            j = j + 1
            if tokens[j] == "*" then
                if sign == -1 then errAt(ctx, "negative index not allowed") end
                local sc = parseNum(tokens[j + 1])
                if sc == nil or (sc ~= 1 and sc ~= 2 and sc ~= 4 and sc ~= 8) then
                    errAt(ctx, "bad scale factor")
                end
                if index ~= nil then errAt(ctx, "too many index registers") end
                index = r.field; scale = sc :: number; j = j + 2
            else
                if sign == -1 then errAt(ctx, "cannot subtract a base register") end
                if base ~= nil then errAt(ctx, "too many base registers") end
                base = r.field
            end
        else
            local start = j
            ctx.usedSym = false
            local v, k = parseDispExpr(tokens, j, ctx)
            if ctx.usedSym then
                dispTerms[#dispTerms + 1] = { sign = sign, expr = slice(tokens, start, k) }
            else
                dispTerms[#dispTerms + 1] = { sign = sign, num = v }
            end
            j = k
        end
    end
    local mem: MemOperand = { kind = "mem", base = base, index = index, scale = scale, disp = dispTerms }
    return mem, j + 1
end

local function x86ParseOperand(tokens: {Token}, i: number, ctx: Ctx): (Operand, number)
    local t: Token? = tokens[i]
    if t == "[" then return x86ParseMem(tokens, i, ctx) end
    if t == "byte" or t == "word" or t == "dword" then
        local size = (t == "byte") and 8 or (t == "word") and 16 or 32
        local j = i + 1
        if tokens[j] == "ptr" then j = j + 1 end
        if tokens[j] ~= "[" then errAt(ctx, "expected '[' after size prefix") end
        local mem, k = x86ParseMem(tokens, j, ctx)
        mem.size = size
        return mem, k
    end
    if type(t) == "string" and REG_BY_NAME[t] ~= nil then
        local r: RegInfo = REG_BY_NAME[t]
        local op: Operand = { kind = "reg", name = t, size = r.size }
        return op, i + 1
    end
    local start = i
    ctx.usedSym = false
    local val, j = parseExpr(tokens, i, ctx)
    if ctx.usedSym then
        local op: Operand = { kind = "imm", expr = slice(tokens, start, j) }
        return op, j
    end
    local op: Operand = { kind = "imm", val = val }
    return op, j
end





local JUMPS = {
    jmp = true, je = true, jz = true, jne = true, jnz = true, jl = true, jnge = true,
    jle = true, jng = true, jg = true, jnle = true, jge = true, jnl = true, jb = true,
    jc = true, jnae = true, jbe = true, jna = true, ja = true, jnbe = true, jae = true,
    jnb = true, jnc = true, jo = true, jno = true, js = true, jns = true, jp = true,
    jpe = true, jnp = true, jpo = true, jcxz = true, jecxz = true, loop = true,
    loope = true, loopz = true, loopne = true, loopnz = true, call = true,
}
local SHIFTS = { shl = true, sal = true, shr = true, sar = true, rol = true, ror = true }
local STRINGOPS = {
    movsb = true, movsw = true, movsd = true, stosb = true, stosw = true, stosd = true,
    lodsb = true, lodsw = true, lodsd = true, cmpsb = true, cmpsw = true, cmpsd = true,
    scasb = true, scasw = true, scasd = true,
}
local ONE_BYTE = {
    nop = true, hlt = true, clc = true, stc = true, cmc = true, cdq = true, cwd = true,
    pusha = true, popa = true, ret = true, lahf = true, sahf = true, leave = true,
}
local REP_PREFIXES = { rep = true, repe = true, repz = true, repne = true, repnz = true }


local CC = {
    e = "e", z = "e", ne = "ne", nz = "ne",
    l = "l", nge = "l", ge = "ge", nl = "ge", le = "le", ng = "le", g = "g", nle = "g",
    b = "b", c = "b", nae = "b", ae = "ae", nb = "ae", nc = "ae", be = "be", na = "be", a = "a", nbe = "a",
    o = "o", no = "no", s = "s", ns = "ns", p = "p", pe = "p", np = "np", po = "np",
}
local CC_SUFFIXES: {string} = { "e", "z", "ne", "nz", "l", "nge", "ge", "nl", "le", "ng", "g", "nle", "b", "c", "nae", "ae", "nb", "nc", "be", "na", "a", "nbe", "o", "no", "s", "ns", "p", "pe", "np", "po" }
local SETCC: { [string]: boolean } = {}
local CMOVCC: { [string]: boolean } = {}
for _, c in ipairs(CC_SUFFIXES) do
    SETCC["set" .. c] = true
    CMOVCC["cmov" .. c] = true
end

local function dispBytes(op: Operand): number
    if op.kind ~= "mem" then return 0 end
    if op.base == nil and op.index == nil then return 4 end
    local hasExpr = false
    local d = 0
    local terms: {any} = op.disp :: {any}
    for _, t in ipairs(terms) do
        if t.num ~= nil then d = d + t.sign * t.num else hasExpr = true end
    end
    if hasExpr then return 4 end
    if d == 0 then return 0 end
    if d >= -128 and d <= 127 then return 1 end
    return 4
end

local function coreSize(mnemonic: string, ops: {Operand}): number
    if ONE_BYTE[mnemonic] then
        if mnemonic == "ret" and ops[1] ~= nil then return 3 end
        return 1
    end
    if mnemonic == "int" then return 2 end
    if JUMPS[mnemonic] then return 5 end
    if STRINGOPS[mnemonic] then return 1 end
    if SHIFTS[mnemonic] then
        local ib = (ops[2] ~= nil and ops[2].kind == "imm") and 1 or 0
        return 1 + 1 + dispBytes(ops[1] :: Operand) + ib
    end
    if SETCC[mnemonic] then return 2 + dispBytes(ops[1] :: Operand) end
    if CMOVCC[mnemonic] then return 2 + dispBytes(ops[1] :: Operand) end
    if mnemonic == "bt" or mnemonic == "bts" or mnemonic == "btr" or mnemonic == "btc" then
        local ib = (ops[2] ~= nil and ops[2].kind == "imm") and 1 or 0
        return 2 + dispBytes(ops[1] :: Operand) + ib
    end
    if mnemonic == "bsf" or mnemonic == "bsr" then return 2 + dispBytes(ops[1] :: Operand) end
    if mnemonic == "enter" then return 4 end
    if mnemonic == "push" then
        local op = ops[1]
        if op ~= nil and op.kind == "imm" and op.val ~= nil and op.val >= -128 and op.val <= 127 then
            return 2
        end
        return 1 + 1 + dispBytes(op :: Operand)
    end
    if mnemonic == "pop" then return 1 + 1 + dispBytes(ops[1] :: Operand) end
    if mnemonic == "mul" or mnemonic == "imul" or mnemonic == "div" or mnemonic == "idiv" then
        if mnemonic == "imul" and ops[2] ~= nil then
            local ib = (ops[3] ~= nil and ops[3].kind == "imm") and 4 or 0
            return 3 + dispBytes(ops[1] :: Operand) + ib
        end
        return 2 + dispBytes(ops[1] :: Operand)
    end
    if mnemonic == "movzx" or mnemonic == "movsx" then
        return 3 + dispBytes((ops[2] or ops[1]) :: Operand)
    end
    local hasModRM = false
    local db = 0
    for _, op in ipairs(ops) do
        if op.kind == "reg" or op.kind == "mem" then
            hasModRM = true
            db = math.max(db, dispBytes(op))
        end
    end
    local ib = 0
    for _, op in ipairs(ops) do
        if op.kind == "imm" then ib = ib + 4 end
    end
    return 1 + (hasModRM and 1 or 0) + db + ib
end

local function x86InstrSize(mnemonic: string, ops: {Operand}, prefix: string?): number
    return (prefix ~= nil and 1 or 0) + coreSize(mnemonic, ops)
end

local function x86Resolve(rec: any, ctx2: Ctx): {Operand}
    local resolvedOps: {Operand} = {}
    local recOps: {Operand} = rec.ops :: {Operand}
    for _, op in ipairs(recOps) do
        if op.kind == "imm" and op.expr ~= nil then
            resolvedOps[#resolvedOps + 1] = { kind = "imm", val = parseExpr(op.expr, 1, ctx2) }
        elseif op.kind == "mem" then
            local copy: MemOperand = { kind = "mem", base = op.base, index = op.index, scale = op.scale, disp = op.disp, size = op.size }
            local d = 0
            local terms: {any} = op.disp :: {any}
            for _, t in ipairs(terms) do
                if t.num ~= nil then d = d + t.sign * t.num
                else d = d + t.sign * parseExpr(t.expr :: {Token}, 1, ctx2) end
            end
            copy.disp = d
            resolvedOps[#resolvedOps + 1] = copy
        else
            resolvedOps[#resolvedOps + 1] = op
        end
    end
    return resolvedOps
end




local function rvParseOperand(tokens: {Token}, i: number, ctx: Ctx): (Operand, number)
    local t: Token? = tokens[i]
    if t == "(" then
        local baseTok: Token? = tokens[i + 1]
        if type(baseTok) ~= "string" then errAt(ctx, "expected register after '('") end
        local baseName: string = baseTok :: string
        local canon = RV_REG_NAME[baseName]
        if canon == nil then errAt(ctx, "unknown register: " .. baseName) end
        if tokens[i + 2] ~= ")" then errAt(ctx, "expected ')'") end
        local op: Operand = { kind = "mem", base = canon, index = nil, scale = 1, disp = 0 }
        return op, i + 3
    end
    if type(t) == "string" then
        local canon = RV_REG_NAME[t]
        if canon ~= nil then
            local op: Operand = { kind = "reg", name = canon, size = 32 }
            return op, i + 1
        end
        local fcanon = RV_FREG_NAME[t]
        if fcanon ~= nil then
            local op: Operand = { kind = "reg", name = fcanon, size = 32 }
            return op, i + 1
        end
        local csr = RV_CSR[t]
        if csr ~= nil then
            local op: Operand = { kind = "imm", val = csr }
            return op, i + 1
        end
    end
    
    local start = i
    ctx.usedSym = false
    local v, j = parseExpr(tokens, i, ctx)
    if tokens[j] == "(" then
        local baseTok: Token? = tokens[j + 1]
        if type(baseTok) ~= "string" then errAt(ctx, "expected register after '('") end
        local baseName: string = baseTok :: string
        local canon = RV_REG_NAME[baseName]
        if canon == nil then errAt(ctx, "unknown register: " .. baseName) end
        if tokens[j + 2] ~= ")" then errAt(ctx, "expected ')'") end
        local disp: any = ctx.usedSym and { expr = slice(tokens, start, j) } or v
        local op: Operand = { kind = "mem", base = canon, index = nil, scale = 1, disp = disp }
        return op, j + 3
    end
    if ctx.usedSym then
        local op: Operand = { kind = "imm", expr = slice(tokens, start, j) }
        return op, j
    end
    local op: Operand = { kind = "imm", val = v }
    return op, j
end



local function rvInstrSize(_mnemonic: string, _ops: {Operand}, _prefix: string?): number
    return 4
end

local function rvResolve(rec: any, ctx2: Ctx): {Operand}
    local resolved: {Operand} = {}
    local recOps: {Operand} = rec.ops :: {Operand}
    for _, op in ipairs(recOps) do
        if op.kind == "imm" and op.expr ~= nil then
            resolved[#resolved + 1] = { kind = "imm", val = parseExpr(op.expr, 1, ctx2) }
        elseif op.kind == "mem" then
            local disp: any = op.disp
            if typeof(disp) == "table" then
                disp = parseExpr(disp.expr, 1, ctx2)
            end
            resolved[#resolved + 1] = { kind = "mem", base = op.base, index = op.index, scale = op.scale, disp = disp, size = op.size }
        else
            resolved[#resolved + 1] = op
        end
    end
    return resolved
end




local BUILTIN_INCLUDES: { [string]: string } = {}

local function expandIncludes(src: string): string
    local out: {string} = {}
    for line in (src .. "\n"):gmatch("([^\n]*)\n") do
        local name = line:match("^%s*%.include%s+[\"']?([%w_]+)[\"']?%s*$")
        if name ~= nil then
            local inc: string? = BUILTIN_INCLUDES[name]
            if inc == nil then
                error("unknown include: " .. name, 0)
            end
            out[#out + 1] = inc
        else
            out[#out + 1] = line
        end
    end
    return table.concat(out, "\n")
end

local function assembleImpl(m: Machine, source: string): ()
    source = expandIncludes(source)
    local lines: {string} = {}
    for line in (source .. "\n"):gmatch("([^\n]*)\n") do
        lines[#lines + 1] = line
    end

    local labels: { [string]: number } = {}
    local equ: { [string]: number } = {}
    local records: { any } = {}
    local addr = 0
    local ctx: Ctx = {
        labels = labels, equ = equ, here = 0, mode = 1, usedSym = false, line = 1,
        target = m.target,
    }

    
    for lineNo, raw in ipairs(lines) do
        ctx.line = lineNo
        local line = raw
        
        local trimmed = line:gsub("^%s+", "")
        if trimmed:sub(1, 3) == "--!" then
            local flag = trimmed:match("^%-%-!(%S+)") or ""
            if flag == "risc-v" or flag == "riscv" or flag == "rv32" then
                ctx.target = rv32Target
                m.target = rv32Target
                m.target.resetRegs(m)
            elseif flag == "x86" then
                ctx.target = x86Target
                m.target = x86Target
                m.target.resetRegs(m)
            end
            
            line = ""
        end
        
        local cleaned: {string} = {}
        local inStr = false
        for k = 1, #line do
            local c = line:sub(k, k)
            local nxt = line:sub(k + 1, k + 1)
            if c == '"' then inStr = not inStr; cleaned[#cleaned + 1] = c
            elseif not inStr and (c == ";" or c == "#" or (c == "-" and nxt == "-")) then break
            else cleaned[#cleaned + 1] = c end
        end
        line = table.concat(cleaned)

        local tokens = tokenize(line)
        if #tokens > 0 then
            local i = 1
            while tokens[i] ~= nil and tokens[i + 1] == ":" do
                labels[tokens[i] :: string] = addr
                i = i + 2
            end
            if i <= #tokens then
                local first = tokens[i]
                if first == "section" or first == ".text" or first == ".data" or first == ".bss" then
                    local sec = (first == "section") and (tokens[i + 1] :: string) or (first :: string)
                    records[#records + 1] = { kind = "section", sec = sec, addr = addr, line = lineNo }
                elseif first == ".rv32" or first == ".riscv" then
                    ctx.target = rv32Target
                    m.target = rv32Target
                    m.target.resetRegs(m)
                elseif first == ".x86" then
                    ctx.target = x86Target
                    m.target = x86Target
                    m.target.resetRegs(m)
                elseif first == ".equ" or first == "equ" or tokens[i + 1] == "equ" then
                    local name: string?
                    local valIdx: number
                    if first == ".equ" or first == "equ" then
                        name = tokens[i + 1] :: string
                        valIdx = i + 2
                    else
                        name = first :: string
                        valIdx = i + 2
                    end
                    local v = parseExpr(tokens, valIdx, ctx)
                    equ[name] = v
                elseif first == "db" or first == ".db" or first == "byte" or first == ".byte"
                    or first == "dw" or first == ".dw" or first == "half" or first == ".half"
                    or first == "dd" or first == ".dd" or first == "word" or first == ".word" then
                    local width = (first == "db" or first == ".db" or first == "byte" or first == ".byte") and 1
                        or (first == "dw" or first == ".dw" or first == "half" or first == ".half") and 2 or 4
                    local items: { any } = {}
                    local j = i + 1
                    ctx.here = addr
                    while j <= #tokens do
                        local tk: Token? = tokens[j]
                        if type(tk) == "table" and tk.t == "str" then
                            items[#items + 1] = { str = tk.v }
                            j = j + 1
                        else
                            local start = j
                            ctx.usedSym = false
                            local v, k = parsePrimary(tokens, j, ctx)
                            if ctx.usedSym then
                                items[#items + 1] = { expr = slice(tokens, start, k) }
                            else
                                items[#items + 1] = { num = v }
                            end
                            j = k
                        end
                    end
                    local sz = 0
                    for _, it in ipairs(items) do
                        sz = sz + (it.str ~= nil and #it.str or width)
                    end
                    records[#records + 1] = { kind = "data", width = width, items = items, addr = addr, size = sz, line = lineNo }
                    addr = addr + sz
                elseif first == "resb" or first == ".resb" or first == "space" or first == ".space"
                    or first == "resw" or first == ".resw" or first == "resd" or first == ".resd" then
                    local width = (first == "resb" or first == ".resb" or first == "space" or first == ".space") and 1
                        or (first == "resw" or first == ".resw") and 2 or 4
                    local v = parseExpr(tokens, i + 1, ctx)
                    records[#records + 1] = { kind = "res", size = v * width, addr = addr, line = lineNo }
                    addr = addr + v * width
                else
                    local mnemonic = first :: string
                    local prefix: string? = nil
                    local j = i + 1
                    if ctx.target == x86Target and REP_PREFIXES[mnemonic] then
                        prefix = mnemonic
                        mnemonic = tokens[j] :: string
                        j = j + 1
                    end
                    ctx.here = addr
                    local ops: {Operand} = {}
                    while j <= #tokens do
                        local op, k = ctx.target.parseOperand(tokens, j, ctx)
                        ops[#ops + 1] = op
                        j = k
                    end
                    local sz = ctx.target.instrSize(mnemonic, ops, prefix)
                    records[#records + 1] = {
                        kind = "instr", mnemonic = mnemonic, prefix = prefix, ops = ops,
                        addr = addr, size = sz, line = lineNo, text = line,
                    }
                    addr = addr + sz
                end
            end
        end
    end

    
    local code: { any } = {}
    local codeByAddr: { [number]: any } = {}
    local mem = m.mem
    local ctx2: Ctx = {
        labels = labels, equ = equ, here = 0, mode = 2, usedSym = false, line = 1,
        target = m.target,
    }

    for _, rec in ipairs(records) do
        ctx2.line = rec.line
        if rec.kind == "instr" then
            ctx2.here = rec.addr
            local resolvedOps: {Operand} = m.target.resolve(rec, ctx2)
            local crec = {
                addr = rec.addr, size = rec.size, mnemonic = rec.mnemonic,
                prefix = rec.prefix, ops = resolvedOps, line = rec.line, text = rec.text,
            }
            code[#code + 1] = crec
            codeByAddr[rec.addr] = crec
        elseif rec.kind == "data" then
            ctx2.here = rec.addr
            local p = rec.addr
            local recItems: {any} = rec.items :: {any}
            for _, it in ipairs(recItems) do
                if it.str ~= nil then
                    for k = 1, #it.str do
                        mem[p + 1] = string.byte(it.str, k)
                        p = p + 1
                    end
                else
                    local v = it.num ~= nil and it.num or parseExpr(it.expr, 1, ctx2)
                    for k = 0, rec.width - 1 do
                        mem[p + 1] = band(rshift(band(v, 0xFFFFFFFF), 8 * k), 0xFF)
                        p = p + 1
                    end
                end
            end
        end
        
    end

    m.code = code
    m.codeByAddr = codeByAddr
    m.labels = labels
    local start = labels["_start"] or labels["main"] or (code[1] ~= nil and code[1].addr or 0)
    m.target.setPC(m, start)
end







local x86Syscall: (Machine) -> ()
local rvSyscall: (Machine) -> ()

do
local RAW = 0xFFFFFFFF
local function s32(n: number): number
    return signedw(n, 32)
end



local function coerce(obj: any, prop: string, value: any): any
    local cur: any = obj[prop]
    local vt = typeof(value)
    local ct = typeof(cur)
    if vt == "number" and ct == "boolean" then return value ~= 0 end
    if vt == "number" and ct == "string" then return tostring(value) end
    if vt == "string" and ct == "EnumItem" then
        local okEnum, enum = pcall(function(): any
            return (Enum :: any)[(cur :: any).EnumType.Name]
        end)
        if okEnum then
            local okItem, item = pcall(function(): any
                return (enum :: any)[value]
            end)
            if okItem then return item end
        end
        return cur
    end
    return value
end




local function hostCreateInstance(m: Machine, classPtr: number, classLen: number): number
    return machineHandle(m, Instance.new(machineReadStr(m, classPtr, classLen)))
end
local function hostGetService(m: Machine, namePtr: number, nameLen: number): number
    return machineHandle(m, game:GetService(machineReadStr(m, namePtr, nameLen)))
end
local function hostVector3(m: Machine, x: number, y: number, z: number): number
    return machineHandle(m, Vector3.new(s32(x), s32(y), s32(z)))
end
local function hostColor3(m: Machine, r: number, g: number, b: number): number
    return machineHandle(m, Color3.fromRGB(band(r, 0xFF), band(g, 0xFF), band(b, 0xFF)))
end
local function hostCFrame(m: Machine, x: number, y: number, z: number): number
    return machineHandle(m, CFrame.new(s32(x), s32(y), s32(z)))
end
local function hostString(m: Machine, ptr: number, len: number): number
    return machineHandle(m, machineReadStr(m, ptr, len))
end
local function hostSetProperty(m: Machine, handle: number, namePtr: number, nameLen: number, valueHandle: number, rawNum: number): ()
    local obj: any = machineDeref(m, handle)
    local name: string = machineReadStr(m, namePtr, nameLen)
    local value: any
    if valueHandle == RAW then value = rawNum else value = machineDeref(m, valueHandle) end
    obj[name] = coerce(obj, name, value)
end
local function hostGetProperty(m: Machine, handle: number, namePtr: number, nameLen: number): (number, number)
    local obj: any = machineDeref(m, handle)
    local name: string = machineReadStr(m, namePtr, nameLen)
    local v: any = obj[name]
    local t = typeof(v)
    if t == "number" then return 0, v end
    if t == "string" then return 1, machineHandle(m, v) end
    if t == "boolean" then return 2, (v and 1 or 0) end
    if t == "Instance" then return 3, machineHandle(m, v) end
    if t == "Vector3" then return 4, machineHandle(m, v) end
    if t == "Color3" then return 5, machineHandle(m, v) end
    if t == "CFrame" then return 6, machineHandle(m, v) end
    return 7, 0
end
local function hostSetParent(m: Machine, handle: number, parentHandle: number): ()
    local obj: any = machineDeref(m, handle)
    local ws: any = game:GetService("Workspace")
    obj.Parent = (parentHandle == 0) and ws or machineDeref(m, parentHandle)
end
local function hostGetChild(m: Machine, handle: number, namePtr: number, nameLen: number): number
    local obj: any = machineDeref(m, handle)
    local child: any = obj and obj:FindFirstChild(machineReadStr(m, namePtr, nameLen))
    return child and machineHandle(m, child) or 0
end
local function hostChildrenCount(m: Machine, handle: number): number
    local obj: any = machineDeref(m, handle)
    return obj and #obj:GetChildren() or 0
end
local function hostGetChildAt(m: Machine, handle: number, index: number): number
    local obj: any = machineDeref(m, handle)
    local kids: {any} = obj and obj:GetChildren() or {}
    return kids[index + 1] and machineHandle(m, kids[index + 1]) or 0
end
local function hostConnect(m: Machine, handle: number, evPtr: number, evLen: number): number
    local obj: any = machineDeref(m, handle)
    local evName: string = machineReadStr(m, evPtr, evLen)
    local connHandle = 0
    local conn = obj[evName]:Connect(function(...: any): ()
        machineEnqueueEvent(m, connHandle, select(1, ...))
    end)
    connHandle = machineHandle(m, conn)
    return connHandle
end
local function hostDisconnect(m: Machine, connHandle: number): ()
    local conn: any = machineDeref(m, connHandle)
    if conn ~= nil then conn:Disconnect() end
end
local function hostDestroy(m: Machine, handle: number): ()
    local obj: any = machineDeref(m, handle)
    if obj ~= nil then obj:Destroy() end
end
local function hostWait(m: Machine, ms: number): ()
    task.wait(ms / 1000)
end
local function hostPrint(m: Machine, ptr: number, len: number): ()
    machineEmit(m, machineReadStr(m, ptr, len))
end
local function hostWarn(m: Machine, ptr: number, len: number): ()
    warn(machineReadStr(m, ptr, len))
end
local function hostPoll(m: Machine): (number, number)
    local e: any = table.remove(m.eventQueue, 1)
    if e == nil then return 0, 0 end
    return e.conn, e.payload
end
local function hostRaycast(m: Machine, originHandle: number, dirHandle: number): number
    local ws: any = game:GetService("Workspace")
    local origin: any = machineDeref(m, originHandle)
    local dir: any = machineDeref(m, dirHandle)
    local result: any = ws:Raycast(origin, dir)
    return (result and result.Instance) and machineHandle(m, result.Instance) or 0
end




local function hostTweenProperty(m: Machine, objH: number, ms: number, propPtr: number, propLen: number, valueHandle: number, rawNum: number): number
    local obj: any = machineDeref(m, objH)
    local prop: string = machineReadStr(m, propPtr, propLen)
    local value: any
    if valueHandle == RAW then value = rawNum else value = machineDeref(m, valueHandle) end
    local ts: any = game:GetService("TweenService")
    local info: any = TweenInfo.new(ms / 1000, (Enum :: any).EasingStyle.Quad, (Enum :: any).EasingDirection.Out, 0, false, 0)
    local goals: any = {}
    goals[prop] = coerce(obj, prop, value)
    local tween = ts:Create(obj, info, goals)
    tween:Play()
    return machineHandle(m, tween)
end
local function hostClone(m: Machine, objH: number): number
    local obj: any = machineDeref(m, objH)
    return obj and machineHandle(m, obj:Clone()) or 0
end
local function hostWaitForChild(m: Machine, objH: number, namePtr: number, nameLen: number): number
    local obj: any = machineDeref(m, objH)
    local child: any = obj and obj:WaitForChild(machineReadStr(m, namePtr, nameLen))
    return child and machineHandle(m, child) or 0
end
local function hostVector3Add(m: Machine, aH: number, bH: number): number
    local a: any = machineDeref(m, aH)
    local b: any = machineDeref(m, bH)
    return machineHandle(m, a + b)
end
local function hostVector3Sub(m: Machine, aH: number, bH: number): number
    local a: any = machineDeref(m, aH)
    local b: any = machineDeref(m, bH)
    return machineHandle(m, a - b)
end
local function hostVector3MulScalar(m: Machine, aH: number, scalar: number): number
    local a: any = machineDeref(m, aH)
    return machineHandle(m, a * s32(scalar))
end
local function hostVector3Dot(m: Machine, aH: number, bH: number): number
    local a: any = machineDeref(m, aH)
    local b: any = machineDeref(m, bH)
    return a:Dot(b)
end
local function hostVector3Cross(m: Machine, aH: number, bH: number): number
    local a: any = machineDeref(m, aH)
    local b: any = machineDeref(m, bH)
    return machineHandle(m, a:Cross(b))
end
local function hostMagnitude(m: Machine, vH: number): number
    local v: any = machineDeref(m, vH)
    return math.floor(v.Magnitude)
end
local function hostCFrameLookAt(m: Machine, posH: number, targetH: number): number
    local pos: any = machineDeref(m, posH)
    local target: any = machineDeref(m, targetH)
    return machineHandle(m, CFrame.lookAt(pos, target))
end
local function hostCFrameMultiply(m: Machine, aH: number, bH: number): number
    local a: any = machineDeref(m, aH)
    local b: any = machineDeref(m, bH)
    return machineHandle(m, a * b)
end
local function hostPlaySound(m: Machine, objH: number, soundIdH: number, volume: number): number
    local obj: any = machineDeref(m, objH)
    local sound: any = Instance.new("Sound")
    sound.SoundId = machineDeref(m, soundIdH)
    sound.Volume = volume
    sound.Parent = obj
    sound:Play()
    return machineHandle(m, sound)
end
local function hostAddTag(m: Machine, objH: number, tagPtr: number, tagLen: number): ()
    local obj: any = machineDeref(m, objH)
    local cs: any = game:GetService("CollectionService")
    cs:AddTag(obj, machineReadStr(m, tagPtr, tagLen))
end
local function hostGetTagged(m: Machine, tagPtr: number, tagLen: number, index: number): number
    local cs: any = game:GetService("CollectionService")
    local list: {any} = cs:GetTagged(machineReadStr(m, tagPtr, tagLen))
    return list[index + 1] and machineHandle(m, list[index + 1]) or 0
end
local function hostRand(m: Machine, maxExclusive: number): number
    if maxExclusive <= 0 then return 0 end
    return math.random(0, maxExclusive - 1)
end




local function hostPrintInt(m: Machine, n: number): ()
    machineEmit(m, tostring(s32(n)) .. "\n")
end
local function hostPrintString(m: Machine, h: number): ()
    local s: any = machineDeref(m, h)
    machineEmit(m, (type(s) == "string") and s or tostring(s))
end
local function hostStringLen(m: Machine, h: number): number
    local s: any = machineDeref(m, h)
    return (type(s) == "string") and #s or 0
end
local function hostStringGet(m: Machine, h: number, dst: number, maxLen: number): number
    local s: any = machineDeref(m, h)
    local str: string = (type(s) == "string") and s or tostring(s)
    local n = math.min(#str, maxLen - 1)
    for i = 1, n do
        m.mem[band(dst + i - 1, 0xFFFFFFFF) + 1] = string.byte(str, i)
    end
    m.mem[band(dst + n, 0xFFFFFFFF) + 1] = 0
    return n
end
local function hostGetDataStore(m: Machine, namePtr: number, nameLen: number): any
    local dss: any = game:GetService("DataStoreService")
    return dss:GetDataStore(machineReadStr(m, namePtr, nameLen))
end
local function hostDataStoreGet(m: Machine, nPtr: number, nLen: number, kPtr: number, kLen: number): number
    local ok, v = pcall(function(): any
        local ds: any = hostGetDataStore(m, nPtr, nLen)
        return ds:GetAsync(machineReadStr(m, kPtr, kLen))
    end)
    return (ok and type(v) == "number" and s32(v)) or 0
end
local function hostDataStoreSet(m: Machine, nPtr: number, nLen: number, kPtr: number, kLen: number, value: number): number
    pcall(function(): ()
        local ds: any = hostGetDataStore(m, nPtr, nLen)
        ds:SetAsync(machineReadStr(m, kPtr, kLen), s32(value))
    end)
    return 0
end
local function hostDataStoreIncrement(m: Machine, nPtr: number, nLen: number, kPtr: number, kLen: number, delta: number): number
    local ok, v = pcall(function(): any
        local ds: any = hostGetDataStore(m, nPtr, nLen)
        return ds:IncrementAsync(machineReadStr(m, kPtr, kLen), s32(delta))
    end)
    return (ok and type(v) == "number" and s32(v)) or 0
end
local function hostHttpGet(m: Machine, urlPtr: number, urlLen: number): number
    local hs: any = game:GetService("HttpService")
    local ok, body = pcall(function(): any
        return hs:GetAsync(machineReadStr(m, urlPtr, urlLen))
    end)
    return machineHandle(m, (ok and type(body) == "string" and body) or "")
end
local function hostJsonEncode(m: Machine, h: number): number
    local hs: any = game:GetService("HttpService")
    local v: any = machineDeref(m, h)
    local ok, s = pcall(function(): any return hs:JSONEncode(v) end)
    return machineHandle(m, (ok and s) or "null")
end
local function hostJsonDecode(m: Machine, h: number): number
    local hs: any = game:GetService("HttpService")
    local s: any = machineDeref(m, h)
    local ok, v = pcall(function(): any return hs:JSONDecode(s) end)
    return machineHandle(m, (ok and v) or nil)
end
local function hostLoadAnimation(m: Machine, animatorH: number, animIdH: number): number
    local animator: any = machineDeref(m, animatorH)
    local anim: any = Instance.new("Animation")
    anim.AnimationId = machineDeref(m, animIdH)
    return machineHandle(m, animator:LoadAnimation(anim))
end
local function hostPlayAnimation(m: Machine, trackH: number, fadeMs: number): number
    local track: any = machineDeref(m, trackH)
    track:Play(fadeMs / 1000, 1, 1)
    return 0
end
local function hostApplyImpulse(m: Machine, objH: number, vH: number): number
    local obj: any = machineDeref(m, objH)
    obj:ApplyImpulse(machineDeref(m, vH))
    return 0
end
local function hostJump(m: Machine, humanoidH: number): number
    local h: any = machineDeref(m, humanoidH)
    if h ~= nil then h:Jump() end
    return 0
end
local function hostWalkSpeed(m: Machine, humanoidH: number, speed: number): number
    local h: any = machineDeref(m, humanoidH)
    if h ~= nil then h.WalkSpeed = speed end
    return 0
end
local function hostSetPosition(m: Machine, objH: number, x: number, y: number, z: number): number
    local obj: any = machineDeref(m, objH)
    obj.Position = Vector3.new(s32(x) / 1000, s32(y) / 1000, s32(z) / 1000)
    return 0
end




local function hostMessagingPublish(m: Machine, tPtr: number, tLen: number, msgPtr: number, msgLen: number): number
    local ms: any = game:GetService("MessagingService")
    ms:PublishAsync(machineReadStr(m, tPtr, tLen), machineReadStr(m, msgPtr, msgLen))
    return 0
end
local function hostMessagingSubscribe(m: Machine, tPtr: number, tLen: number): number
    local ms: any = game:GetService("MessagingService")
    ms:SubscribeAsync(machineReadStr(m, tPtr, tLen), function(msg: any): ()
        machineEnqueueEvent(m, 0, msg and msg.Data)
    end)
    return 0
end
local function hostHttpPost(m: Machine, urlPtr: number, urlLen: number, bodyPtr: number, bodyLen: number): number
    local hs: any = game:GetService("HttpService")
    local url = machineReadStr(m, urlPtr, urlLen)
    local body = machineReadStr(m, bodyPtr, bodyLen)
    local ok, resp = pcall(function(): any
        return hs:PostAsync(url, body, (Enum :: any).HttpContentType.ApplicationJson)
    end)
    return machineHandle(m, (ok and type(resp) == "string" and resp) or "")
end


local function hostDataStoreGetString(m: Machine, nPtr: number, nLen: number, kPtr: number, kLen: number): number
    local ok, v = pcall(function(): any
        local ds: any = hostGetDataStore(m, nPtr, nLen)
        return ds:GetAsync(machineReadStr(m, kPtr, kLen))
    end)
    return machineHandle(m, (ok and type(v) == "string" and v) or "")
end

local function hostDataStoreSetString(m: Machine, nPtr: number, nLen: number, kPtr: number, kLen: number, sHandle: number): number
    local s: any = machineDeref(m, sHandle)
    pcall(function(): ()
        local ds: any = hostGetDataStore(m, nPtr, nLen)
        ds:SetAsync(machineReadStr(m, kPtr, kLen), (type(s) == "string" and s) or "")
    end)
    return 0
end

local function hostDataStoreRemove(m: Machine, nPtr: number, nLen: number, kPtr: number, kLen: number): number
    pcall(function(): ()
        local ds: any = hostGetDataStore(m, nPtr, nLen)
        ds:RemoveAsync(machineReadStr(m, kPtr, kLen))
    end)
    return 0
end

local function hostTickMs(_m: Machine): number
    return math.floor(os.clock() * 1000)
end

local function hostPathSegments(path: string): {string}
    local out: {string} = {}
    for seg in path:gmatch("[^\\/]+") do
        if seg ~= "" then
            if #out == 0 and seg:sub(-1) == ":" then
                
            else
                out[#out + 1] = seg
            end
        end
    end
    return out
end

local function hostFsRoot(): any
    local ok, ss = pcall(function(): any
        return game:GetService("ServerScriptService")
    end)
    return (ok and ss) or nil
end

local function hostFsOpen(m: Machine, pathPtr: number, pathLen: number, createFlag: number): number
    local segs: {string} = hostPathSegments(machineReadStr(m, pathPtr, pathLen))
    if #segs == 0 then return 0 end
    local root: any = hostFsRoot()
    if root == nil then return 0 end
    local cur: any = root
    for i = 1, #segs - 1 do
        local next: any = cur:FindFirstChild(segs[i])
        if next == nil then
            if createFlag == 0 then return 0 end
            next = Instance.new("Folder")
            next.Name = segs[i]
            next.Parent = cur
        elseif not next:IsA("Folder") then
            return 0
        end
        cur = next
    end
    local leafName: string = segs[#segs]
    local leaf: any = cur:FindFirstChild(leafName)
    if leaf == nil then
        if createFlag == 0 then return 0 end
        leaf = Instance.new("StringValue")
        leaf.Name = leafName
        leaf.Value = ""
        leaf.Parent = cur
    end
    return machineHandle(m, leaf)
end

local function hostFsRead(m: Machine, objHandle: number): number
    local obj: any = machineDeref(m, objHandle)
    local v: any = (obj ~= nil) and obj.Value or ""
    return machineHandle(m, (type(v) == "string" and v) or "")
end

local function hostFsWrite(m: Machine, objHandle: number, strHandle: number): number
    local obj: any = machineDeref(m, objHandle)
    local s: any = machineDeref(m, strHandle)
    if obj ~= nil then
        obj.Value = (type(s) == "string" and s) or ""
    end
    return 0
end

local function hostFsDelete(m: Machine, pathPtr: number, pathLen: number): number
    local segs: {string} = hostPathSegments(machineReadStr(m, pathPtr, pathLen))
    if #segs == 0 then return 0 end
    local root: any = hostFsRoot()
    if root == nil then return 0 end
    local cur: any = root
    for i = 1, #segs - 1 do
        local next: any = cur:FindFirstChild(segs[i])
        if next == nil then return 0 end
        cur = next
    end
    local leaf: any = cur:FindFirstChild(segs[#segs])
    if leaf ~= nil then leaf:Destroy() end
    return 0
end

local function hostFsExists(m: Machine, pathPtr: number, pathLen: number): number
    local segs: {string} = hostPathSegments(machineReadStr(m, pathPtr, pathLen))
    if #segs == 0 then return 0 end
    local root: any = hostFsRoot()
    if root == nil then return 0 end
    local cur: any = root
    for i = 1, #segs - 1 do
        local next: any = cur:FindFirstChild(segs[i])
        if next == nil then return 0 end
        cur = next
    end
    return (cur:FindFirstChild(segs[#segs]) ~= nil) and 1 or 0
end





local hostCallImport: (Machine, number) -> number

local function roboxDispatch(m: Machine, num: number, args: {number}): (number, number?)
    if num == 0x201 then return hostCreateInstance(m, args[1], args[2]), nil
    elseif num == 0x202 then return hostGetService(m, args[1], args[2]), nil
    elseif num == 0x203 then return hostVector3(m, args[1], args[2], args[3]), nil
    elseif num == 0x204 then return hostColor3(m, args[1], args[2], args[3]), nil
    elseif num == 0x205 then return hostCFrame(m, args[1], args[2], args[3]), nil
    elseif num == 0x206 then return hostString(m, args[1], args[2]), nil
    elseif num == 0x207 then hostSetProperty(m, args[1], args[2], args[3], args[4], args[5]); return 0, nil
    elseif num == 0x208 then return hostGetProperty(m, args[1], args[2], args[3])
    elseif num == 0x209 then hostSetParent(m, args[1], args[2]); return 0, nil
    elseif num == 0x20A then return hostGetChild(m, args[1], args[2], args[3]), nil
    elseif num == 0x20B then return hostChildrenCount(m, args[1]), nil
    elseif num == 0x20C then return hostGetChildAt(m, args[1], args[2]), nil
    elseif num == 0x20D then return hostConnect(m, args[1], args[2], args[3]), nil
    elseif num == 0x20E then hostDisconnect(m, args[1]); return 0, nil
    elseif num == 0x20F then hostDestroy(m, args[1]); return 0, nil
    elseif num == 0x210 then hostWait(m, args[1]); return 0, nil
    elseif num == 0x211 then hostPrint(m, args[1], args[2]); return 0, nil
    elseif num == 0x212 then hostWarn(m, args[1], args[2]); return 0, nil
    elseif num == 0x213 then return hostPoll(m)
    elseif num == 0x214 then return hostRaycast(m, args[1], args[2]), nil
    elseif num == 0x215 then return hostTweenProperty(m, args[1], args[2], args[3], args[4], args[5], args[6]), nil
    elseif num == 0x216 then return hostClone(m, args[1]), nil
    elseif num == 0x217 then return hostWaitForChild(m, args[1], args[2], args[3]), nil
    elseif num == 0x218 then return hostVector3Add(m, args[1], args[2]), nil
    elseif num == 0x219 then return hostVector3Sub(m, args[1], args[2]), nil
    elseif num == 0x21A then return hostVector3MulScalar(m, args[1], args[2]), nil
    elseif num == 0x21B then return hostVector3Dot(m, args[1], args[2]), nil
    elseif num == 0x21C then return hostVector3Cross(m, args[1], args[2]), nil
    elseif num == 0x21D then return hostMagnitude(m, args[1]), nil
    elseif num == 0x21E then return hostCFrameLookAt(m, args[1], args[2]), nil
    elseif num == 0x21F then return hostCFrameMultiply(m, args[1], args[2]), nil
    elseif num == 0x220 then return hostPlaySound(m, args[1], args[2], args[3]), nil
    elseif num == 0x221 then hostAddTag(m, args[1], args[2], args[3]); return 0, nil
    elseif num == 0x222 then return hostGetTagged(m, args[1], args[2], args[3]), nil
    elseif num == 0x223 then return hostRand(m, args[1]), nil
    elseif num == 0x224 then hostPrintInt(m, args[1]); return 0, nil
    elseif num == 0x225 then hostPrintString(m, args[1]); return 0, nil
    elseif num == 0x226 then return hostStringLen(m, args[1]), nil
    elseif num == 0x227 then return hostStringGet(m, args[1], args[2], args[3]), nil
    elseif num == 0x228 then return hostDataStoreGet(m, args[1], args[2], args[3], args[4]), nil
    elseif num == 0x229 then return hostDataStoreSet(m, args[1], args[2], args[3], args[4], args[5]), nil
    elseif num == 0x22A then return hostDataStoreIncrement(m, args[1], args[2], args[3], args[4], args[5]), nil
    elseif num == 0x22B then return hostHttpGet(m, args[1], args[2]), nil
    elseif num == 0x22C then return hostJsonEncode(m, args[1]), nil
    elseif num == 0x22D then return hostJsonDecode(m, args[1]), nil
    elseif num == 0x22E then return hostLoadAnimation(m, args[1], args[2]), nil
    elseif num == 0x22F then return hostPlayAnimation(m, args[1], args[2]), nil
    elseif num == 0x230 then return hostApplyImpulse(m, args[1], args[2]), nil
    elseif num == 0x231 then return hostJump(m, args[1]), nil
    elseif num == 0x232 then return hostWalkSpeed(m, args[1], args[2]), nil
    elseif num == 0x233 then return hostSetPosition(m, args[1], args[2], args[3], args[4]), nil
    elseif num == 0x234 then return hostMessagingPublish(m, args[1], args[2], args[3], args[4]), nil
    elseif num == 0x235 then hostMessagingSubscribe(m, args[1], args[2]); return 0, nil
    elseif num == 0x236 then return hostHttpPost(m, args[1], args[2], args[3], args[4]), nil
    elseif num == 0x237 then return hostDataStoreGetString(m, args[1], args[2], args[3], args[4]), nil
    elseif num == 0x238 then return hostDataStoreSetString(m, args[1], args[2], args[3], args[4], args[5]), nil
    elseif num == 0x239 then return hostDataStoreRemove(m, args[1], args[2], args[3], args[4]), nil
    elseif num == 0x23A then return hostTickMs(m), nil
    elseif num == 0x23B then return hostFsOpen(m, args[1], args[2], args[3]), nil
    elseif num == 0x23C then return hostFsRead(m, args[1]), nil
    elseif num == 0x23D then return hostFsWrite(m, args[1], args[2]), nil
    elseif num == 0x23E then return hostFsDelete(m, args[1], args[2]), nil
    elseif num == 0x23F then return hostFsExists(m, args[1], args[2]), nil
    elseif num == 0x240 then return hostCallImport(m, args[1]), nil
    else
        machineFail(m, "unknown Roblox syscall 0x" .. string.format("%X", num))
        return 0, nil
    end
end

local function doSyscall(m: Machine, num: number, args: {number}): (number, number?)
    if num == 1 then
        m.exitCode = signedw(args[1] or 0, 32)
        m.exited = true
        return 0, nil
    elseif num == 3 then
        local buf, len = args[2], args[3]
        local s = m.stdin or ""
        local pos = m.stdinPos or 1
        local chunk = s:sub(pos, pos + len - 1)
        for i = 1, #chunk do
            local a = band(buf + i - 1, 0xFFFFFFFF)
            if a + 1 > MEM_SIZE then machineFail(m, "segmentation fault in sys_read"); return 0, nil end
            m.mem[a + 1] = string.byte(chunk, i)
        end
        m.stdinPos = pos + #chunk
        return #chunk, nil
    elseif num == 4 then
        local buf, len = args[2], args[3]
        local t: {string} = {}
        for i = 0, len - 1 do
            local a = band(buf + i, 0xFFFFFFFF)
            if a + 1 > MEM_SIZE then machineFail(m, "segmentation fault in sys_write"); return 0, nil end
            t[i + 1] = string.char(m.mem[a + 1])
        end
        machineEmit(m, table.concat(t))
        return len, nil
    elseif num >= 0x200 then
        return roboxDispatch(m, num, args)
    else
        machineFail(m, "unsupported syscall number " .. tostring(num))
        return 0, nil
    end
end


x86Syscall = function(m: Machine): ()
    local R = m.regs
    local r1, r2 = doSyscall(m, R.eax, { R.ebx, R.ecx, R.edx, R.esi, R.edi, R.ebp })
    R.eax = r1
    if r2 ~= nil then R.ebx = r2 end
end


rvSyscall = function(m: Machine): ()
    local r1, r2 = doSyscall(m, m.regs.x17, { m.regs.x10, m.regs.x11, m.regs.x12, m.regs.x13, m.regs.x14, m.regs.x15 })
    m.regs.x10 = r1
    if r2 ~= nil then m.regs.x11 = r2 end
end

local IMPORT_REGISTRY: { [string]: { [string]: { nargs: number, fn: any } } } = {}

local function resolveImportHandler(dll: string, func: string): any
    local d: any = IMPORT_REGISTRY[dll]
    if d == nil then return nil end
    return d[func]
end

hostCallImport = function(m: Machine, idx: number): number
    local info: any = m.imports[idx]
    if info == nil then
        machineFail(m, "unresolved import #" .. tostring(idx))
        return 0
    end
    local nargs: number = (typeof(info.nargs) == "number") and info.nargs or 0
    local arglist: {number} = {}
    if nargs >= 0 then
        for i = 0, nargs - 1 do
            arglist[#arglist + 1] = loadUint(m, band(m.regs.esp + 4 + i * 4, 0xFFFFFFFF), 32)
        end
    end
    local ok, result = pcall(info.fn, m, table.unpack(arglist))
    if not ok then
        machineFail(m, "import handler error: " .. tostring(result))
        return 0
    end
    return result :: number
end

local function fmtCountArgs(fmt: string): number
    local n = 0
    local i = 1
    while i <= #fmt do
        local c = fmt:sub(i, i)
        if c == "%" then
            if fmt:sub(i + 1, i + 1) == "%" then
                i = i + 2
            else
                local j = i + 1
                while j <= #fmt and fmt:sub(j, j):match("[%-+0-9 .#*hlLjzt]") do j = j + 1 end
                n = n + 1
                i = j
            end
        else
            i = i + 1
        end
    end
    return n
end

local function fmtFormat(m: Machine, fmt: string, args: {number}): string
    local out: {string} = {}
    local ai = 1
    local i = 1
    while i <= #fmt do
        local c = fmt:sub(i, i)
        if c == "%" and fmt:sub(i + 1, i + 1) ~= "%" then
            local j = i + 1
            while j <= #fmt and fmt:sub(j, j):match("[%-+0-9 .#*hlLjzt]") do j = j + 1 end
            local spec = fmt:sub(j, j)
            local arg = args[ai] or 0
            ai = ai + 1
            if spec == "d" or spec == "i" then out[#out + 1] = tostring(s32(arg))
            elseif spec == "u" then out[#out + 1] = tostring(band(arg, 0xFFFFFFFF))
            elseif spec == "x" then out[#out + 1] = string.format("%x", band(arg, 0xFFFFFFFF))
            elseif spec == "X" then out[#out + 1] = string.format("%X", band(arg, 0xFFFFFFFF))
            elseif spec == "c" then out[#out + 1] = string.char(band(arg, 0xFF))
            elseif spec == "s" then out[#out + 1] = machineReadStr(m, arg, 4096)
            elseif spec == "p" then out[#out + 1] = string.format("0x%X", band(arg, 0xFFFFFFFF))
            else out[#out + 1] = "%" .. spec end
            i = j + 1
        else
            out[#out + 1] = c
            i = i + 1
        end
    end
    return table.concat(out)
end

IMPORT_REGISTRY["KERNEL32.dll"] = {
    GetTickCount = {
        nargs = 0, cdecl = false,
        fn = function(_m: Machine): number
            return math.floor(os.clock() * 1000)
        end,
    },
    Sleep = {
        nargs = 1, cdecl = false,
        fn = function(_m: Machine, ms: number): number
            task.wait(s32(ms) / 1000)
            return 0
        end,
    },
    ExitProcess = {
        nargs = 1, cdecl = false,
        fn = function(m: Machine, code: number): number
            m.exitCode = s32(code)
            m.exited = true
            return 0
        end,
    },
}

IMPORT_REGISTRY["USER32.dll"] = {
    MessageBoxA = {
        nargs = 4, cdecl = false,
        fn = function(m: Machine, _hwnd: number, textPtr: number, capPtr: number, _flags: number): number
            local text: string = machineReadStr(m, textPtr, 4096)
            local cap: string = machineReadStr(m, capPtr, 4096)
            machineEmit(m, "[" .. cap .. "] " .. text .. "\n")
            return 0
        end,
    },
}

IMPORT_REGISTRY["msvcrt.dll"] = {
    printf = {
        nargs = -1, cdecl = true,
        fn = function(m: Machine): number
            local fmtPtr = loadUint(m, band(m.regs.esp + 4, 0xFFFFFFFF), 32)
            local fmt = machineReadStr(m, fmtPtr, 4096)
            local argc = fmtCountArgs(fmt)
            local args: {number} = {}
            for i = 0, argc - 1 do
                args[#args + 1] = loadUint(m, band(m.regs.esp + 8 + i * 4, 0xFFFFFFFF), 32)
            end
            machineEmit(m, fmtFormat(m, fmt, args))
            return 0
        end,
    },
    strlen = {
        nargs = 1, cdecl = true,
        fn = function(m: Machine, p: number): number
            return #machineReadStr(m, p, 65536)
        end,
    },
    malloc = {
        nargs = 1, cdecl = true,
        fn = function(m: Machine, size: number): number
            size = band(size, 0xFFFFFFFF)
            if size == 0 then size = 1 end
            local p = m.heapTop
            m.heapTop = band(p + size + 16, 0xFFFFFFF0)
            return p
        end,
    },
    free = {
        nargs = 1, cdecl = true,
        fn = function(_m: Machine, _p: number): number
            return 0
        end,
    },
    memcpy = {
        nargs = 3, cdecl = true,
        fn = function(m: Machine, dst: number, src: number, n: number): number
            for i = 0, n - 1 do
                m.mem[band(dst + i, 0xFFFFFFFF) + 1] = m.mem[band(src + i, 0xFFFFFFFF) + 1] or 0
            end
            return dst
        end,
    },
    memset = {
        nargs = 3, cdecl = true,
        fn = function(m: Machine, dst: number, v: number, n: number): number
            for i = 0, n - 1 do
                m.mem[band(dst + i, 0xFFFFFFFF) + 1] = band(v, 0xFF)
            end
            return dst
        end,
    },
    exit = {
        nargs = 1, cdecl = true,
        fn = function(m: Machine, code: number): number
            m.exitCode = s32(code)
            m.exited = true
            return 0
        end,
    },
}

x86.resolveImportHandler = resolveImportHandler
end



local exec: (Machine, any) -> ()

do
local function push32(m: Machine, v: number): ()
    m.regs.esp = band(m.regs.esp - 4, 0xFFFFFFFF)
    storeUint(m, m.regs.esp, 32, v)
end
local function pop32(m: Machine): number
    local v = loadUint(m, m.regs.esp, 32)
    m.regs.esp = band(m.regs.esp + 4, 0xFFFFFFFF)
    return v
end

local function getReg(m: Machine, name: string): number
    local r: RegInfo = REG_BY_NAME[name]
    local v = m.regs[r.field]
    if r.size == 32 then return band(v, 0xFFFFFFFF)
    elseif r.size == 16 then return band(v, 0xFFFF)
    elseif r.hi then return band(rshift(v, 8), 0xFF)
    else return band(v, 0xFF) end
end
local function setReg(m: Machine, name: string, value: number): ()
    local r: RegInfo = REG_BY_NAME[name]
    local cur = m.regs[r.field]
    if r.size == 32 then m.regs[r.field] = band(value, 0xFFFFFFFF)
    elseif r.size == 16 then m.regs[r.field] = bor(band(cur, 0xFFFF0000), band(value, 0xFFFF))
    elseif r.hi then m.regs[r.field] = bor(band(cur, 0xFFFF00FF), lshift(band(value, 0xFF), 8))
    else m.regs[r.field] = bor(band(cur, 0xFFFFFF00), band(value, 0xFF)) end
end

local function effAddr(m: Machine, op: any): number
    local d: number = (typeof(op.disp) == "number") and op.disp or 0
    if op.base ~= nil then d = d + getReg(m, op.base) end
    if op.index ~= nil then d = d + getReg(m, op.index) * (op.scale or 1) end
    return band(d, 0xFFFFFFFF)
end

local function opW(op1: any, op2: any): number?
    if op1 ~= nil and op1.kind == "reg" then return op1.size end
    if op2 ~= nil and op2.kind == "reg" then return op2.size end
    if op1 ~= nil and op1.kind == "mem" and op1.size ~= nil then return op1.size end
    if op2 ~= nil and op2.kind == "mem" and op2.size ~= nil then return op2.size end
    return nil
end

local function readVal(m: Machine, op: any, w: number): number
    if op.kind == "imm" then return band(op.val or 0, MASKS[w])
    elseif op.kind == "reg" then return getReg(m, op.name)
    else return loadUint(m, effAddr(m, op), w) end
end
local function writeVal(m: Machine, op: any, w: number, v: number): ()
    if op.kind == "reg" then setReg(m, op.name, v)
    elseif op.kind == "mem" then storeUint(m, effAddr(m, op), w, v)
    else machineFail(m, "invalid instruction destination") end
end

local function setResFlags(m: Machine, w: number, resM: number): ()
    setf(m, SF, band(resM, MSBS[w]) ~= 0)
    setf(m, ZF, resM == 0)
    setf(m, PF, PARITY[band(resM, 0xFF) + 1])
end
local function setAddFlags(m: Machine, w: number, a: number, b: number, cin: number, resM: number): ()
    setf(m, CF, (a + b + cin) > MASKS[w])
    setf(m, OF, (band(a, MSBS[w]) == band(b, MSBS[w])) and (band(resM, MSBS[w]) ~= band(a, MSBS[w])))
    setf(m, AF, (band(a, 0xF) + band(b, 0xF) + cin) > 0xF)
end
local function setSubFlags(m: Machine, w: number, a: number, b: number, cin: number, resM: number): ()
    setf(m, CF, a < (b + cin))
    setf(m, OF, (band(a, MSBS[w]) ~= band(b, MSBS[w])) and (band(resM, MSBS[w]) == band(b, MSBS[w])))
    setf(m, AF, band(a, 0xF) < (band(b, 0xF) + cin))
end
local function setLogicFlags(m: Machine, w: number, resM: number): ()
    setf(m, CF, false)
    setf(m, OF, false)
    setf(m, AF, false)
    setResFlags(m, w, resM)
end

local function failAt(m: Machine, rec: any, msg: string): ()
    local lineNum: number = rec.line or -1
    machineFail(m, string.format("line %d: %s", lineNum, msg))
end

local function doBin(m: Machine, rec: any, op1: any, op2: any, kind: string): ()
    local w = opW(op1, op2)
    if w == nil then failAt(m, rec, "operation size not specified"); return end
    local a = readVal(m, op1, w)
    local b = readVal(m, op2, w)
    local mask = MASKS[w]
    if kind == "mov" then
        writeVal(m, op1, w, b)
    elseif kind == "xchg" then
        writeVal(m, op1, w, b)
        writeVal(m, op2, w, a)
    elseif kind == "and" or kind == "or" or kind == "xor" or kind == "test" then
        local resM: number
        if kind == "and" or kind == "test" then resM = band(a, b)
        elseif kind == "or" then resM = bor(a, b)
        else resM = bxor(a, b) end
        setLogicFlags(m, w, resM)
        if kind ~= "test" then writeVal(m, op1, w, resM) end
    elseif kind == "add" or kind == "adc" then
        local cin = (kind == "adc" and getf(m, CF)) and 1 or 0
        local resM = band(a + b + cin, mask)
        setAddFlags(m, w, a, b, cin, resM)
        setResFlags(m, w, resM)
        writeVal(m, op1, w, resM)
    elseif kind == "sub" or kind == "sbb" or kind == "cmp" then
        local cin = (kind == "sbb" and getf(m, CF)) and 1 or 0
        local resM = band(a - b - cin, mask)
        setSubFlags(m, w, a, b, cin, resM)
        setResFlags(m, w, resM)
        if kind ~= "cmp" then writeVal(m, op1, w, resM) end
    end
end

local function doShift(m: Machine, rec: any, op1: any, op2: any, mn: string): ()
    local w = opW(op1, op2)
    if w == nil then w = op1.size end
    if w == nil then failAt(m, rec, "operation size not specified"); return end
    local a = readVal(m, op1, w)
    local count: number
    if op2 ~= nil and op2.kind == "imm" then count = band(op2.val or 0, 0xFF)
    else count = band(getReg(m, "cl"), 0xFF) end
    count = band(count, w - 1)
    local mask = MASKS[w]
    local msb = MSBS[w]
    local resM = a
    if count ~= 0 then
        if mn == "shl" or mn == "sal" then
            resM = band(lshift(a, count), mask)
            setf(m, CF, band(rshift(a, w - count), 1) == 1)
            setf(m, OF, (count == 1) and ((band(resM, msb) ~= 0) ~= (band(rshift(a, w - 1), 1) == 1)))
            setResFlags(m, w, resM)
        elseif mn == "shr" then
            resM = band(rshift(a, count), mask)
            setf(m, CF, band(rshift(a, count - 1), 1) == 1)
            setf(m, OF, (count == 1) and (band(a, msb) ~= 0))
            setResFlags(m, w, resM)
        elseif mn == "sar" then
            local sa = signExtend(a, w)
            resM = band(arshift(sa, count), mask)
            setf(m, CF, band(rshift(a, count - 1), 1) == 1)
            setf(m, OF, false)
            setResFlags(m, w, resM)
        elseif mn == "rol" then
            resM = rotl(a, count, w)
            setf(m, CF, band(resM, 1) == 1)
            setf(m, OF, (count == 1) and ((band(resM, msb) ~= 0) ~= (band(resM, 1) == 1)))
        elseif mn == "ror" then
            resM = rotr(a, count, w)
            setf(m, CF, band(resM, msb) ~= 0)
            setf(m, OF, (count == 1) and ((band(resM, msb) ~= 0) ~= (band(resM, rshift(msb, 1)) ~= 0)))
        end
    end
    writeVal(m, op1, w, resM)
end

local function doIncDec(m: Machine, rec: any, op1: any, mn: string): ()
    local w = opW(op1, nil)
    if w == nil then w = op1.size end
    if w == nil then failAt(m, rec, "operation size not specified"); return end
    local a = readVal(m, op1, w)
    local mask = MASKS[w]
    local msb = MSBS[w]
    local resM = (mn == "inc") and band(a + 1, mask) or band(a - 1, mask)
    setf(m, OF, (mn == "inc") and (a == msb - 1) or (a == msb))
    setf(m, AF, (mn == "inc") and (band(a, 0xF) == 0xF) or (band(a, 0xF) == 0))
    setResFlags(m, w, resM)
    writeVal(m, op1, w, resM)
end

local function doMul(m: Machine, rec: any, op1: any, mn: string): ()
    local w = opW(op1, nil)
    if w == nil then w = op1.size end
    if w == nil then failAt(m, rec, "operation size not specified"); return end
    local a = readVal(m, op1, w)
    local R = m.regs
    if mn == "mul" then
        if w == 8 then
            local prod = band(R.eax, 0xFF) * a
            R.eax = bor(band(R.eax, 0xFFFF0000), band(prod, 0xFFFF))
            setf(m, CF, prod > 0xFF); setf(m, OF, prod > 0xFF)
        elseif w == 16 then
            local prod = band(R.eax, 0xFFFF) * a
            R.eax = bor(band(R.eax, 0xFFFF0000), band(prod, 0xFFFF))
            R.edx = bor(band(R.edx, 0xFFFF0000), rshift(prod, 16))
            setf(m, CF, prod > 0xFFFF); setf(m, OF, prod > 0xFFFF)
        else
            local hi, lo = mul32(R.eax, a)
            R.eax, R.edx = lo, hi
            setf(m, CF, hi ~= 0); setf(m, OF, hi ~= 0)
        end
    else 
        if w == 8 then
            local prod = signedw(R.eax, 8) * signedw(a, 8)
            R.eax = bor(band(R.eax, 0xFFFF0000), band(prod, 0xFFFF))
            local fits = (prod == signedw(prod, 8))
            setf(m, CF, not fits); setf(m, OF, not fits)
        elseif w == 16 then
            local prod = signedw(R.eax, 16) * signedw(a, 16)
            R.eax = bor(band(R.eax, 0xFFFF0000), band(prod, 0xFFFF))
            R.edx = bor(band(R.edx, 0xFFFF0000), band(rshift(band(prod, 0xFFFFFFFF), 16), 0xFFFF))
            local fits = (prod == signedw(prod, 16))
            setf(m, CF, not fits); setf(m, OF, not fits)
        else
            local neg = (signedw(R.eax, 32) < 0) ~= (signedw(a, 32) < 0)
            local hi, lo = mul32(band(math.abs(signedw(R.eax, 32)), 0xFFFFFFFF), band(math.abs(signedw(a, 32)), 0xFFFFFFFF))
            if neg then
                lo = band(bnot(lo) + 1, 0xFFFFFFFF)
                hi = band(bnot(hi) + ((lo == 0) and 1 or 0), 0xFFFFFFFF)
            end
            R.eax, R.edx = lo, hi
            local sext = (band(lo, 0x80000000) ~= 0) and 0xFFFFFFFF or 0
            setf(m, CF, hi ~= sext); setf(m, OF, hi ~= sext)
        end
    end
end

local function doImul23(m: Machine, rec: any, ops: {any}): ()
    local w = opW(ops[1], ops[2])
    if w == nil then failAt(m, rec, "operation size not specified"); return end
    local a: number
    local b: number
    if ops[3] ~= nil then
        
        a = signedw(readVal(m, ops[2], w), w)
        b = signedw(band(ops[3].val or 0, MASKS[w]), w)
    else
        
        a = signedw(readVal(m, ops[1], w), w)
        b = signedw(readVal(m, ops[2], w), w)
    end
    local neg = (a < 0) ~= (b < 0)
    local hi, lo = mul32(band(math.abs(a), 0xFFFFFFFF), band(math.abs(b), 0xFFFFFFFF))
    if neg then
        lo = band(bnot(lo) + 1, 0xFFFFFFFF)
        hi = band(bnot(hi) + ((lo == 0) and 1 or 0), 0xFFFFFFFF)
    end
    local resM = band(lo, MASKS[w])
    writeVal(m, ops[1], w, resM)
    local sext = (band(resM, MSBS[w]) ~= 0) and 0xFFFFFFFF or 0
    setf(m, CF, hi ~= sext)
    setf(m, OF, hi ~= sext)
end

local function doDiv(m: Machine, rec: any, op1: any, mn: string): ()
    local w = opW(op1, nil)
    if w == nil then w = op1.size end
    if w == nil then failAt(m, rec, "operation size not specified"); return end
    local divisor = readVal(m, op1, w)
    local R = m.regs
    if divisor == 0 then failAt(m, rec, "divide by zero"); return end
    if mn == "div" then
        if w == 8 then
            local dividend = band(R.eax, 0xFFFF)
            local q = dividend // divisor
            local r = dividend % divisor
            if q > 0xFF then failAt(m, rec, "divide overflow"); return end
            R.eax = bor(band(R.eax, 0xFFFF0000), bor(band(q, 0xFF), lshift(band(r, 0xFF), 8)))
        elseif w == 16 then
            local dividend = band(R.eax, 0xFFFF) + lshift(band(R.edx, 0xFFFF), 16)
            local q = dividend // divisor
            local r = dividend % divisor
            if q > 0xFFFF then failAt(m, rec, "divide overflow"); return end
            R.eax = bor(band(R.eax, 0xFFFF0000), band(q, 0xFFFF))
            R.edx = bor(band(R.edx, 0xFFFF0000), band(r, 0xFFFF))
        else
            if R.edx >= divisor then failAt(m, rec, "divide overflow"); return end
            local q, r = div64_32(R.edx, R.eax, divisor)
            R.eax, R.edx = q, r
        end
    else 
        if w == 8 then
            local dividend = signedw(R.eax, 16)
            local d = signedw(divisor, 8)
            local q = idivq(dividend, d)
            local r = imod(dividend, d)
            if q > 0x7F or q < -0x80 then failAt(m, rec, "divide overflow"); return end
            R.eax = bor(band(R.eax, 0xFFFF0000), bor(band(q, 0xFF), lshift(band(r, 0xFF), 8)))
        elseif w == 16 then
            local dividend = signedw(band(R.eax, 0xFFFF) + lshift(band(R.edx, 0xFFFF), 16), 32)
            local d = signedw(divisor, 16)
            local q = idivq(dividend, d)
            local r = imod(dividend, d)
            if q > 0x7FFF or q < -0x8000 then failAt(m, rec, "divide overflow"); return end
            R.eax = bor(band(R.eax, 0xFFFF0000), band(q, 0xFFFF))
            R.edx = bor(band(R.edx, 0xFFFF0000), band(r, 0xFFFF))
        else
            local hi, lo = R.edx, R.eax
            local d = signedw(divisor, 32)
            local negd = (signedw(hi, 32) < 0)
            if negd then
                lo = band(bnot(lo) + 1, 0xFFFFFFFF)
                hi = band(bnot(hi) + ((lo == 0) and 1 or 0), 0xFFFFFFFF)
            end
            local ad = math.abs(d)
            local q, r = div64_32(hi, lo, ad)
            if signedw(hi, 32) < 0 or hi >= ad then failAt(m, rec, "divide overflow"); return end
            if negd ~= (d < 0) then q = -q end
            if negd then r = -r end
            if q > 0x7FFFFFFF or q < -0x80000000 then failAt(m, rec, "divide overflow"); return end
            R.eax = band(q, 0xFFFFFFFF)
            R.edx = band(r, 0xFFFFFFFF)
        end
    end
end

local function doStringOp(m: Machine, rec: any): ()
    local mn: string = rec.mnemonic :: string
    local w = (mn:sub(-1) == "b") and 8 or (mn:sub(-1) == "w") and 16 or 32
    local step = w // 8
    local dir = getf(m, DF) and -step or step
    local R = m.regs
    local once = function(): ()
        if mn:sub(1, 3) == "mov" then
            storeUint(m, R.edi, w, loadUint(m, R.esi, w))
            R.esi = band(R.esi + dir, 0xFFFFFFFF)
            R.edi = band(R.edi + dir, 0xFFFFFFFF)
        elseif mn:sub(1, 3) == "sto" then
            local v = (w == 8) and band(R.eax, 0xFF) or (w == 16) and band(R.eax, 0xFFFF) or R.eax
            storeUint(m, R.edi, w, v)
            R.edi = band(R.edi + dir, 0xFFFFFFFF)
        elseif mn:sub(1, 3) == "lod" then
            local v = loadUint(m, R.esi, w)
            if w == 8 then R.eax = bor(band(R.eax, 0xFFFFFF00), v)
            elseif w == 16 then R.eax = bor(band(R.eax, 0xFFFF0000), v)
            else R.eax = v end
            R.esi = band(R.esi + dir, 0xFFFFFFFF)
        elseif mn:sub(1, 3) == "cmp" then
            local x = loadUint(m, R.esi, w)
            local y = loadUint(m, R.edi, w)
            local resM = band(x - y, MASKS[w])
            setSubFlags(m, w, x, y, 0, resM)
            setResFlags(m, w, resM)
            R.esi = band(R.esi + dir, 0xFFFFFFFF)
            R.edi = band(R.edi + dir, 0xFFFFFFFF)
        elseif mn:sub(1, 3) == "sca" then
            local x = (w == 8) and band(R.eax, 0xFF) or (w == 16) and band(R.eax, 0xFFFF) or R.eax
            local y = loadUint(m, R.edi, w)
            local resM = band(x - y, MASKS[w])
            setSubFlags(m, w, x, y, 0, resM)
            setResFlags(m, w, resM)
            R.edi = band(R.edi + dir, 0xFFFFFFFF)
        end
    end
    local rep = rec.prefix
    if rep == nil then
        once()
    else
        local c = R.ecx
        while c > 0 do
            once()
            c = c - 1
            if rep == "repe" or rep == "repz" then
                if not getf(m, ZF) then break end
            elseif rep == "repne" or rep == "repnz" then
                if getf(m, ZF) then break end
            end
        end
        R.ecx = band(c, 0xFFFFFFFF)
    end
end

local function condHolds(m: Machine, code: any): boolean
    if code == "e" then return getf(m, ZF)
    elseif code == "ne" then return not getf(m, ZF)
    elseif code == "l" then return getf(m, SF) ~= getf(m, OF)
    elseif code == "ge" then return getf(m, SF) == getf(m, OF)
    elseif code == "le" then return getf(m, ZF) or (getf(m, SF) ~= getf(m, OF))
    elseif code == "g" then return (not getf(m, ZF)) and (getf(m, SF) == getf(m, OF))
    elseif code == "b" then return getf(m, CF)
    elseif code == "ae" then return not getf(m, CF)
    elseif code == "be" then return getf(m, CF) or getf(m, ZF)
    elseif code == "a" then return (not getf(m, CF)) and (not getf(m, ZF))
    elseif code == "o" then return getf(m, OF)
    elseif code == "no" then return not getf(m, OF)
    elseif code == "s" then return getf(m, SF)
    elseif code == "ns" then return not getf(m, SF)
    elseif code == "p" then return getf(m, PF)
    else return not getf(m, PF) end
end

exec = function(m: Machine, rec: any): ()
    local ops: {any} = rec.ops :: {any}
    local R = m.regs
    local mn: any = rec.mnemonic
    local op1 = ops[1]
    local op2 = ops[2]

    if mn == "mov" or mn == "add" or mn == "adc" or mn == "sub" or mn == "sbb"
        or mn == "and" or mn == "or" or mn == "xor" or mn == "cmp" or mn == "test"
        or mn == "xchg" then
        if mn == "mov" and op1 ~= nil and op1.kind == "imm" then failAt(m, rec, "invalid mov destination"); return end
        doBin(m, rec, op1, op2, mn)
    elseif mn == "movzx" or mn == "movsx" then
        local src: any = op2 or op1
        local sw: any = src.size
        if sw == nil then failAt(m, rec, "source size not specified"); return end
        local v = readVal(m, src, sw)
        if mn == "movsx" then v = signExtend(v, sw) end
        if mn == "movsx" then writeVal(m, op1, 32, v) else writeVal(m, op1, 32, band(v, MASKS[sw])) end
    elseif mn == "lea" then
        if op2 == nil or op2.kind ~= "mem" then failAt(m, rec, "lea requires a memory operand"); return end
        writeVal(m, op1, 32, effAddr(m, op2))
    elseif mn == "push" then
        push32(m, readVal(m, op1, 32))
    elseif mn == "pop" then
        writeVal(m, op1, 32, pop32(m))
    elseif mn == "pusha" then
        local s = R.esp
        push32(m, R.eax); push32(m, R.ecx); push32(m, R.edx); push32(m, R.ebx)
        push32(m, s); push32(m, R.ebp); push32(m, R.esi); push32(m, R.edi)
    elseif mn == "popa" then
        R.edi = pop32(m); R.esi = pop32(m); R.ebp = pop32(m)
        R.esp = band(R.esp + 4, 0xFFFFFFFF)
        R.ebx = pop32(m); R.edx = pop32(m); R.ecx = pop32(m); R.eax = pop32(m)
    elseif mn == "inc" or mn == "dec" then
        doIncDec(m, rec, op1, mn)
    elseif mn == "neg" then
        local w = opW(op1, nil)
        if w == nil then w = op1.size end
        if w == nil then failAt(m, rec, "operation size not specified"); return end
        local a = readVal(m, op1, w)
        local resM = band(0 - a, MASKS[w])
        setf(m, CF, a ~= 0)
        setSubFlags(m, w, 0, a, 0, resM)
        setResFlags(m, w, resM)
        writeVal(m, op1, w, resM)
    elseif mn == "not" then
        local w = opW(op1, nil)
        if w == nil then w = op1.size end
        if w == nil then failAt(m, rec, "operation size not specified"); return end
        writeVal(m, op1, w, band(bnot(readVal(m, op1, w)), MASKS[w]))
    elseif SHIFTS[mn] then
        doShift(m, rec, op1, op2, mn)
    elseif mn == "mul" or (mn == "imul" and op2 == nil) then
        doMul(m, rec, op1, mn)
    elseif mn == "imul" then
        doImul23(m, rec, ops)
    elseif mn == "div" or mn == "idiv" then
        doDiv(m, rec, op1, mn)
    elseif mn == "cdq" then
        R.edx = (band(R.eax, 0x80000000) ~= 0) and 0xFFFFFFFF or 0
    elseif mn == "cwd" then
        R.edx = bor(band(R.edx, 0xFFFF0000), (band(R.eax, 0x8000) ~= 0) and 0xFFFF or 0)
    elseif mn == "nop" then
        
    elseif mn == "clc" then setf(m, CF, false)
    elseif mn == "stc" then setf(m, CF, true)
    elseif mn == "cmc" then setf(m, CF, not getf(m, CF))
    elseif mn == "lahf" then
        R.eax = bor(band(R.eax, 0xFFFF00FF), lshift(band(m.eflags, 0xFF), 8))
    elseif mn == "sahf" then
        m.eflags = bor(band(m.eflags, 0xFFFFFF00), band(rshift(R.eax, 8), 0xFF))
    elseif mn == "hlt" then
        m.exited = true
        m.exitCode = 0
    elseif mn == "int" then
        local iv: number = (op1 ~= nil and op1.kind == "imm") and (op1.val or 0) or 0
        if iv == 0x80 then x86Syscall(m)
        elseif iv == 3 then
            m.hitBreakpoint = true
            m.exited = true
            m.exitCode = 0
        else
            failAt(m, rec, "unsupported interrupt 0x" .. string.format("%X", band(iv, 0xFF)))
        end
    elseif mn == "jmp" then
        local target: number
        if op1 ~= nil and op1.kind == "imm" then target = band(op1.val or 0, 0xFFFFFFFF)
        elseif op1 ~= nil and op1.kind == "reg" then target = getReg(m, op1.name)
        else target = loadUint(m, effAddr(m, op1), 32) end
        R.eip = band(target, 0xFFFFFFFF)
    elseif mn == "call" then
        local target: number
        if op1 ~= nil and op1.kind == "imm" then target = band(op1.val or 0, 0xFFFFFFFF)
        elseif op1 ~= nil and op1.kind == "reg" then target = getReg(m, op1.name)
        else target = loadUint(m, effAddr(m, op1), 32) end
        push32(m, R.eip)
        R.eip = band(target, 0xFFFFFFFF)
    elseif mn == "ret" then
        local v = pop32(m)
        if v == 0 then
            m.exited = true
            m.exitCode = 0
        else
            R.eip = band(v, 0xFFFFFFFF)
        end
        if op1 ~= nil and op1.kind == "imm" then R.esp = band(R.esp + band(op1.val or 0, 0xFFFF), 0xFFFFFFFF) end
    elseif JUMPS[mn] then
        local target = band((op1 ~= nil and op1.kind == "imm") and (op1.val or 0) or 0, 0xFFFFFFFF)
        local take = false
        if mn == "jcxz" then take = (band(R.ecx, 0xFFFF) == 0)
        elseif mn == "jecxz" then take = (R.ecx == 0)
        elseif mn == "loop" then
            R.ecx = band(R.ecx - 1, 0xFFFFFFFF)
            take = (R.ecx ~= 0)
        elseif mn == "loope" or mn == "loopz" then
            R.ecx = band(R.ecx - 1, 0xFFFFFFFF)
            take = (R.ecx ~= 0) and getf(m, ZF)
        elseif mn == "loopne" or mn == "loopnz" then
            R.ecx = band(R.ecx - 1, 0xFFFFFFFF)
            take = (R.ecx ~= 0) and not getf(m, ZF)
        elseif mn == "je" or mn == "jz" then take = getf(m, ZF)
        elseif mn == "jne" or mn == "jnz" then take = not getf(m, ZF)
        elseif mn == "jl" or mn == "jnge" then take = getf(m, SF) ~= getf(m, OF)
        elseif mn == "jge" or mn == "jnl" then take = getf(m, SF) == getf(m, OF)
        elseif mn == "jle" or mn == "jng" then take = getf(m, ZF) or (getf(m, SF) ~= getf(m, OF))
        elseif mn == "jg" or mn == "jnle" then take = (not getf(m, ZF)) and (getf(m, SF) == getf(m, OF))
        elseif mn == "jb" or mn == "jc" or mn == "jnae" then take = getf(m, CF)
        elseif mn == "jae" or mn == "jnb" or mn == "jnc" then take = not getf(m, CF)
        elseif mn == "jbe" or mn == "jna" then take = getf(m, CF) or getf(m, ZF)
        elseif mn == "ja" or mn == "jnbe" then take = (not getf(m, CF)) and (not getf(m, ZF))
        elseif mn == "jo" then take = getf(m, OF)
        elseif mn == "jno" then take = not getf(m, OF)
        elseif mn == "js" then take = getf(m, SF)
        elseif mn == "jns" then take = not getf(m, SF)
        elseif mn == "jp" or mn == "jpe" then take = getf(m, PF)
        elseif mn == "jnp" or mn == "jpo" then take = not getf(m, PF)
        end
        if take then R.eip = target end
    elseif STRINGOPS[mn] then
        doStringOp(m, rec)
    elseif SETCC[mn] then
        local code: any = CC[(mn :: string):sub(4)]
        writeVal(m, op1, 8, (code ~= nil and condHolds(m, code)) and 1 or 0)
    elseif CMOVCC[mn] then
        local code: any = CC[(mn :: string):sub(5)]
        local w = opW(op1, op2)
        if w == nil then failAt(m, rec, "operation size not specified"); return end
        if code ~= nil and condHolds(m, code) then
            writeVal(m, op1, w, readVal(m, op2, w))
        end
    elseif mn == "bt" or mn == "bts" or mn == "btr" or mn == "btc" then
        if op2 == nil then failAt(m, rec, "bt/bts/btr/btc needs a bit index"); return end
        local w = opW(op1, nil)
        if w == nil then w = op1.size end
        if w == nil then failAt(m, rec, "operation size not specified"); return end
        local base = readVal(m, op1, w)
        local idx: number
        if op2.kind == "imm" then idx = band(op2.val or 0, 0xFFFF)
        else idx = band(getReg(m, op2.name), 0xFFFF) end
        idx = idx % w
        setf(m, CF, band(rshift(base, idx), 1) == 1)
        if mn == "bts" then writeVal(m, op1, w, bor(base, lshift(1, idx)))
        elseif mn == "btr" then writeVal(m, op1, w, band(base, bnot(lshift(1, idx))))
        elseif mn == "btc" then writeVal(m, op1, w, bxor(base, lshift(1, idx))) end
    elseif mn == "bsf" or mn == "bsr" then
        local w = opW(op1, op2)
        if w == nil then failAt(m, rec, "operation size not specified"); return end
        local src = readVal(m, op2, w)
        if src == 0 then
            setf(m, ZF, true)
            writeVal(m, op1, w, 0)
        else
            setf(m, ZF, false)
            local i = (mn == "bsf") and 0 or (w - 1)
            if mn == "bsf" then
                while band(rshift(src, i), 1) == 0 do i = i + 1 end
            else
                while band(rshift(src, i), 1) == 0 do i = i - 1 end
            end
            writeVal(m, op1, w, i)
        end
    elseif mn == "enter" then
        local sz = (op1 ~= nil and op1.kind == "imm" and op1.val) or 0
        push32(m, R.ebp)
        R.ebp = R.esp
        R.esp = band(R.esp - band(sz, 0xFFFF), 0xFFFFFFFF)
    elseif mn == "leave" then
        R.esp = R.ebp
        R.ebp = pop32(m)
    else
        failAt(m, rec, "unknown instruction: " .. tostring(mn))
    end
end
end



local rvExec: (Machine, any) -> ()

do
local function sext12(v: number): number
    v = band(v, 0xFFF)
    if band(v, 0x800) ~= 0 then v = bor(v, 0xFFFFF000) end
    return v
end

local function rvRead(m: Machine, name: string): number
    return m.regs[name]
end
local function rvWrite(m: Machine, name: string, v: number): ()
    if name ~= "x0" then m.regs[name] = band(v, 0xFFFFFFFF) end
end
local function rvImm(op: any): number
    return band(op.val or 0, 0xFFFFFFFF)
end
local function rvEffAddr(m: Machine, op: any): number
    if op.kind == "imm" then return band(op.val or 0, 0xFFFFFFFF) end  
    local a = (typeof(op.disp) == "number") and op.disp or 0
    if op.base ~= nil then a = a + m.regs[op.base] end
    return band(a, 0xFFFFFFFF)
end


local function mulSignedHi(a: number, b: number): number
    local neg = (signedw(a, 32) < 0) ~= (signedw(b, 32) < 0)
    local hi, lo = mul32(band(math.abs(signedw(a, 32)), 0xFFFFFFFF), band(math.abs(signedw(b, 32)), 0xFFFFFFFF))
    if neg then
        lo = band(bnot(lo) + 1, 0xFFFFFFFF)
        hi = band(bnot(hi) + ((lo == 0) and 1 or 0), 0xFFFFFFFF)
    end
    return hi
end

local function mulHsuHi(a: number, b: number): number
    local neg = signedw(a, 32) < 0
    local hi, lo = mul32(band(math.abs(signedw(a, 32)), 0xFFFFFFFF), b)
    if neg then
        lo = band(bnot(lo) + 1, 0xFFFFFFFF)
        hi = band(bnot(hi) + ((lo == 0) and 1 or 0), 0xFFFFFFFF)
    end
    return hi
end


local function frvRead(m: Machine, name: string): number
    return m.fregs[name]
end
local function frvWrite(m: Machine, name: string, v: number): ()
    m.fregs[name] = v
end
local function fsignOf(x: number): boolean
    return (x < 0) or (x == 0 and (1.0 / x) < 0)
end
local function withFsign(x: number, neg: boolean): number
    local ax = math.abs(x)
    return neg and -ax or ax
end
local function ftrunc(x: number): number
    return (x >= 0) and math.floor(x) or math.ceil(x)
end

local function loadUint64(m: Machine, addr: number): (number, number)
    local lo = loadUint(m, addr, 32)
    local hi = loadUint(m, band(addr + 4, 0xFFFFFFFF), 32)
    return lo, hi
end
local function storeUint64(m: Machine, addr: number, lo: number, hi: number): ()
    storeUint(m, addr, 32, lo)
    storeUint(m, band(addr + 4, 0xFFFFFFFF), 32, hi)
end

rvExec = function(m: Machine, rec: any): ()
    local ops: {any} = rec.ops :: {any}
    local mn: any = rec.mnemonic
    local a: any = ops[1]
    local b: any = ops[2]
    local c: any = ops[3]
    local d: any = ops[4]
    local R = m.regs

    
    if mn == "add" then rvWrite(m, a.name, band(rvRead(m, b.name) + rvRead(m, c.name), 0xFFFFFFFF))
    elseif mn == "sub" then rvWrite(m, a.name, band(rvRead(m, b.name) - rvRead(m, c.name), 0xFFFFFFFF))
    elseif mn == "sll" then rvWrite(m, a.name, band(lshift(rvRead(m, b.name), band(rvRead(m, c.name), 0x1F)), 0xFFFFFFFF))
    elseif mn == "slt" then rvWrite(m, a.name, (signedw(rvRead(m, b.name), 32) < signedw(rvRead(m, c.name), 32)) and 1 or 0)
    elseif mn == "sltu" then rvWrite(m, a.name, (rvRead(m, b.name) < rvRead(m, c.name)) and 1 or 0)
    elseif mn == "xor" then rvWrite(m, a.name, bxor(rvRead(m, b.name), rvRead(m, c.name)))
    elseif mn == "srl" then rvWrite(m, a.name, band(rshift(rvRead(m, b.name), band(rvRead(m, c.name), 0x1F)), 0xFFFFFFFF))
    elseif mn == "sra" then rvWrite(m, a.name, band(arshift(signExtend(rvRead(m, b.name), 32), band(rvRead(m, c.name), 0x1F)), 0xFFFFFFFF))
    elseif mn == "or" then rvWrite(m, a.name, bor(rvRead(m, b.name), rvRead(m, c.name)))
    elseif mn == "and" then rvWrite(m, a.name, band(rvRead(m, b.name), rvRead(m, c.name)))
    elseif mn == "mul" then rvWrite(m, a.name, band(rvRead(m, b.name) * rvRead(m, c.name), 0xFFFFFFFF))
    elseif mn == "mulh" then rvWrite(m, a.name, mulSignedHi(rvRead(m, b.name), rvRead(m, c.name)))
    elseif mn == "mulhsu" then rvWrite(m, a.name, mulHsuHi(rvRead(m, b.name), rvRead(m, c.name)))
    elseif mn == "mulhu" then
        local hi, _ = mul32(rvRead(m, b.name), rvRead(m, c.name))
        rvWrite(m, a.name, hi)
    elseif mn == "div" then
        local x = rvRead(m, b.name)
        local y = rvRead(m, c.name)
        if y == 0 then rvWrite(m, a.name, 0xFFFFFFFF)
        elseif x == 0x80000000 and y == 0xFFFFFFFF then rvWrite(m, a.name, 0x80000000)
        else rvWrite(m, a.name, idivq(signedw(x, 32), signedw(y, 32))) end
    elseif mn == "divu" then
        local x = rvRead(m, b.name)
        local y = rvRead(m, c.name)
        if y == 0 then rvWrite(m, a.name, 0xFFFFFFFF)
        else rvWrite(m, a.name, x // y) end
    elseif mn == "rem" then
        local x = rvRead(m, b.name)
        local y = rvRead(m, c.name)
        if y == 0 then rvWrite(m, a.name, x)
        elseif x == 0x80000000 and y == 0xFFFFFFFF then rvWrite(m, a.name, 0)
        else rvWrite(m, a.name, imod(signedw(x, 32), signedw(y, 32))) end
    elseif mn == "remu" then
        local x = rvRead(m, b.name)
        local y = rvRead(m, c.name)
        if y == 0 then rvWrite(m, a.name, x)
        else rvWrite(m, a.name, x % y) end

    
    elseif mn == "addi" then rvWrite(m, a.name, band(rvRead(m, b.name) + sext12(rvImm(c)), 0xFFFFFFFF))
    elseif mn == "slti" then rvWrite(m, a.name, (signedw(rvRead(m, b.name), 32) < sext12(rvImm(c))) and 1 or 0)
    elseif mn == "sltiu" then rvWrite(m, a.name, (rvRead(m, b.name) < band(sext12(rvImm(c)), 0xFFFFFFFF)) and 1 or 0)
    elseif mn == "xori" then rvWrite(m, a.name, bxor(rvRead(m, b.name), sext12(rvImm(c))))
    elseif mn == "ori" then rvWrite(m, a.name, bor(rvRead(m, b.name), sext12(rvImm(c))))
    elseif mn == "andi" then rvWrite(m, a.name, band(rvRead(m, b.name), sext12(rvImm(c))))
    elseif mn == "slli" then rvWrite(m, a.name, band(lshift(rvRead(m, b.name), band(rvImm(c), 0x1F)), 0xFFFFFFFF))
    elseif mn == "srli" then rvWrite(m, a.name, band(rshift(rvRead(m, b.name), band(rvImm(c), 0x1F)), 0xFFFFFFFF))
    elseif mn == "srai" then rvWrite(m, a.name, band(arshift(signExtend(rvRead(m, b.name), 32), band(rvImm(c), 0x1F)), 0xFFFFFFFF))

    
    elseif mn == "lui" then rvWrite(m, a.name, lshift(band(rvImm(b), 0xFFFFF), 12))
    elseif mn == "auipc" then rvWrite(m, a.name, band(rec.addr + lshift(band(rvImm(b), 0xFFFFF), 12), 0xFFFFFFFF))

    
    elseif mn == "jal" then
        local target = band(rvImm(b), 0xFFFFFFFF)
        if a.name ~= "x0" then rvWrite(m, a.name, band(rec.addr + rec.size, 0xFFFFFFFF)) end
        R.pc = target
    elseif mn == "jalr" then
        local target = band(band(rvRead(m, b.name) + sext12(rvImm(c)), 0xFFFFFFFF), 0xFFFFFFFE)
        if a.name ~= "x0" then rvWrite(m, a.name, band(rec.addr + rec.size, 0xFFFFFFFF)) end
        R.pc = target

    
    elseif mn == "beq" then if rvRead(m, a.name) == rvRead(m, b.name) then R.pc = band(rvImm(c), 0xFFFFFFFF) end
    elseif mn == "bne" then if rvRead(m, a.name) ~= rvRead(m, b.name) then R.pc = band(rvImm(c), 0xFFFFFFFF) end
    elseif mn == "blt" then if signedw(rvRead(m, a.name), 32) < signedw(rvRead(m, b.name), 32) then R.pc = band(rvImm(c), 0xFFFFFFFF) end
    elseif mn == "bge" then if signedw(rvRead(m, a.name), 32) >= signedw(rvRead(m, b.name), 32) then R.pc = band(rvImm(c), 0xFFFFFFFF) end
    elseif mn == "bltu" then if rvRead(m, a.name) < rvRead(m, b.name) then R.pc = band(rvImm(c), 0xFFFFFFFF) end
    elseif mn == "bgeu" then if rvRead(m, a.name) >= rvRead(m, b.name) then R.pc = band(rvImm(c), 0xFFFFFFFF) end

    
    elseif mn == "lb" then rvWrite(m, a.name, signExtend(loadUint(m, rvEffAddr(m, b), 8), 8))
    elseif mn == "lbu" then rvWrite(m, a.name, loadUint(m, rvEffAddr(m, b), 8))
    elseif mn == "lh" then rvWrite(m, a.name, signExtend(loadUint(m, rvEffAddr(m, b), 16), 16))
    elseif mn == "lhu" then rvWrite(m, a.name, loadUint(m, rvEffAddr(m, b), 16))
    elseif mn == "lw" then rvWrite(m, a.name, loadUint(m, rvEffAddr(m, b), 32))

    
    elseif mn == "sb" then storeUint(m, rvEffAddr(m, b), 8, rvRead(m, a.name))
    elseif mn == "sh" then storeUint(m, rvEffAddr(m, b), 16, rvRead(m, a.name))
    elseif mn == "sw" then storeUint(m, rvEffAddr(m, b), 32, rvRead(m, a.name))

    
    elseif mn == "ecall" then rvSyscall(m)
    elseif mn == "ebreak" then
        m.hitBreakpoint = true
        m.exited = true
        m.exitCode = 0
    elseif mn == "fence" or mn == "fence.i" then
        

    
    elseif mn == "csrrw" or mn == "csrrs" or mn == "csrrc" or mn == "csrrwi" or mn == "csrrsi" or mn == "csrrci" then
        local csr: number = rvImm(b)
        local t: number = (m.csr[csr] ~= nil) and m.csr[csr] or 0
        rvWrite(m, a.name, t)
        if mn == "csrrw" then m.csr[csr] = rvRead(m, c.name)
        elseif mn == "csrrs" then m.csr[csr] = bor(t, rvRead(m, c.name))
        elseif mn == "csrrc" then m.csr[csr] = band(t, bnot(rvRead(m, c.name)))
        elseif mn == "csrrwi" then m.csr[csr] = band(rvImm(c), 0x1F)
        elseif mn == "csrrsi" then m.csr[csr] = bor(t, band(rvImm(c), 0x1F))
        elseif mn == "csrrci" then m.csr[csr] = band(t, bnot(band(rvImm(c), 0x1F))) end

    
    elseif mn == "flw" then frvWrite(m, a.name, f32FromBits(loadUint(m, rvEffAddr(m, b), 32)))
    elseif mn == "fsw" then storeUint(m, rvEffAddr(m, b), 32, f32Bits(frvRead(m, a.name)))
    elseif mn == "fadd.s" then frvWrite(m, a.name, f32(frvRead(m, b.name) + frvRead(m, c.name)))
    elseif mn == "fsub.s" then frvWrite(m, a.name, f32(frvRead(m, b.name) - frvRead(m, c.name)))
    elseif mn == "fmul.s" then frvWrite(m, a.name, f32(frvRead(m, b.name) * frvRead(m, c.name)))
    elseif mn == "fdiv.s" then frvWrite(m, a.name, f32(frvRead(m, b.name) / frvRead(m, c.name)))
    elseif mn == "fsqrt.s" then frvWrite(m, a.name, f32(math.sqrt(frvRead(m, b.name))))
    elseif mn == "fmin.s" then
        local x = frvRead(m, b.name)
        local y = frvRead(m, c.name)
        local r: number
        if x ~= x then r = y elseif y ~= y then r = x elseif x <= y then r = x else r = y end
        frvWrite(m, a.name, r)
    elseif mn == "fmax.s" then
        local x = frvRead(m, b.name)
        local y = frvRead(m, c.name)
        local r: number
        if x ~= x then r = y elseif y ~= y then r = x elseif x >= y then r = x else r = y end
        frvWrite(m, a.name, r)
    elseif mn == "fsgnj.s" then frvWrite(m, a.name, withFsign(frvRead(m, b.name), fsignOf(frvRead(m, c.name))))
    elseif mn == "fsgnjn.s" then frvWrite(m, a.name, withFsign(frvRead(m, b.name), not fsignOf(frvRead(m, c.name))))
    elseif mn == "fsgnjx.s" then frvWrite(m, a.name, withFsign(frvRead(m, b.name), fsignOf(frvRead(m, b.name)) ~= fsignOf(frvRead(m, c.name))))
    elseif mn == "fcvt.s.w" then frvWrite(m, a.name, f32(signedw(rvRead(m, b.name), 32)))
    elseif mn == "fcvt.s.wu" then frvWrite(m, a.name, f32(rvRead(m, b.name)))
    elseif mn == "fcvt.w.s" then
        local x = frvRead(m, b.name)
        local r: number
        if x ~= x or x >= 2147483648.0 then r = 0x7FFFFFFF
        elseif x < -2147483648.0 then r = 0x80000000
        else r = ftrunc(x) end
        rvWrite(m, a.name, r)
    elseif mn == "fcvt.wu.s" then
        local x = frvRead(m, b.name)
        local r: number
        if x ~= x or x >= 4294967296.0 then r = 0xFFFFFFFF
        elseif x < 0 then r = 0
        else r = ftrunc(x) end
        rvWrite(m, a.name, r)
    elseif mn == "feq.s" then rvWrite(m, a.name, (frvRead(m, b.name) == frvRead(m, c.name)) and 1 or 0)
    elseif mn == "flt.s" then rvWrite(m, a.name, (frvRead(m, b.name) < frvRead(m, c.name)) and 1 or 0)
    elseif mn == "fle.s" then rvWrite(m, a.name, (frvRead(m, b.name) <= frvRead(m, c.name)) and 1 or 0)
    elseif mn == "fmadd.s" then frvWrite(m, a.name, f32(frvRead(m, b.name) * frvRead(m, c.name) + frvRead(m, d.name)))
    elseif mn == "fmsub.s" then frvWrite(m, a.name, f32(frvRead(m, b.name) * frvRead(m, c.name) - frvRead(m, d.name)))
    elseif mn == "fnmadd.s" then frvWrite(m, a.name, f32(-(frvRead(m, b.name) * frvRead(m, c.name)) - frvRead(m, d.name)))
    elseif mn == "fnmsub.s" then frvWrite(m, a.name, f32(-(frvRead(m, b.name) * frvRead(m, c.name)) + frvRead(m, d.name)))

    
    elseif mn == "fld" then
        local addr = rvEffAddr(m, b)
        local lo, hi = loadUint64(m, addr)
        frvWrite(m, a.name, f64FromBits(lo, hi))
    elseif mn == "fsd" then
        local addr = rvEffAddr(m, b)
        local lo, hi = f64Bits(frvRead(m, a.name))
        storeUint64(m, addr, lo, hi)
    elseif mn == "fadd.d" then frvWrite(m, a.name, frvRead(m, b.name) + frvRead(m, c.name))
    elseif mn == "fsub.d" then frvWrite(m, a.name, frvRead(m, b.name) - frvRead(m, c.name))
    elseif mn == "fmul.d" then frvWrite(m, a.name, frvRead(m, b.name) * frvRead(m, c.name))
    elseif mn == "fdiv.d" then frvWrite(m, a.name, frvRead(m, b.name) / frvRead(m, c.name))
    elseif mn == "fsqrt.d" then frvWrite(m, a.name, math.sqrt(frvRead(m, b.name)))
    elseif mn == "fmin.d" then
        local x = frvRead(m, b.name)
        local y = frvRead(m, c.name)
        local r: number
        if x ~= x then r = y elseif y ~= y then r = x elseif x <= y then r = x else r = y end
        frvWrite(m, a.name, r)
    elseif mn == "fmax.d" then
        local x = frvRead(m, b.name)
        local y = frvRead(m, c.name)
        local r: number
        if x ~= x then r = y elseif y ~= y then r = x elseif x >= y then r = x else r = y end
        frvWrite(m, a.name, r)
    elseif mn == "fsgnj.d" then frvWrite(m, a.name, withFsign(frvRead(m, b.name), fsignOf(frvRead(m, c.name))))
    elseif mn == "fsgnjn.d" then frvWrite(m, a.name, withFsign(frvRead(m, b.name), not fsignOf(frvRead(m, c.name))))
    elseif mn == "fsgnjx.d" then frvWrite(m, a.name, withFsign(frvRead(m, b.name), fsignOf(frvRead(m, b.name)) ~= fsignOf(frvRead(m, c.name))))
    elseif mn == "fcvt.d.s" then frvWrite(m, a.name, frvRead(m, b.name))
    elseif mn == "fcvt.s.d" then frvWrite(m, a.name, f32(frvRead(m, b.name)))
    elseif mn == "fcvt.d.w" then frvWrite(m, a.name, signedw(rvRead(m, b.name), 32))
    elseif mn == "fcvt.d.wu" then frvWrite(m, a.name, rvRead(m, b.name))
    elseif mn == "fcvt.w.d" then
        local x = frvRead(m, b.name)
        local r: number
        if x ~= x or x >= 2147483648.0 then r = 0x7FFFFFFF
        elseif x < -2147483648.0 then r = 0x80000000
        else r = ftrunc(x) end
        rvWrite(m, a.name, r)
    elseif mn == "fcvt.wu.d" then
        local x = frvRead(m, b.name)
        local r: number
        if x ~= x or x >= 4294967296.0 then r = 0xFFFFFFFF
        elseif x < 0 then r = 0
        else r = ftrunc(x) end
        rvWrite(m, a.name, r)
    elseif mn == "feq.d" then rvWrite(m, a.name, (frvRead(m, b.name) == frvRead(m, c.name)) and 1 or 0)
    elseif mn == "flt.d" then rvWrite(m, a.name, (frvRead(m, b.name) < frvRead(m, c.name)) and 1 or 0)
    elseif mn == "fle.d" then rvWrite(m, a.name, (frvRead(m, b.name) <= frvRead(m, c.name)) and 1 or 0)
    elseif mn == "fmadd.d" then frvWrite(m, a.name, frvRead(m, b.name) * frvRead(m, c.name) + frvRead(m, d.name))
    elseif mn == "fmsub.d" then frvWrite(m, a.name, frvRead(m, b.name) * frvRead(m, c.name) - frvRead(m, d.name))
    elseif mn == "fnmadd.d" then frvWrite(m, a.name, -(frvRead(m, b.name) * frvRead(m, c.name)) - frvRead(m, d.name))
    elseif mn == "fnmsub.d" then frvWrite(m, a.name, -(frvRead(m, b.name) * frvRead(m, c.name)) + frvRead(m, d.name))

    
    elseif mn == "lr.w" then
        local addr = rvEffAddr(m, b)
        m.reservation = { addr = addr, valid = true }
        rvWrite(m, a.name, loadUint(m, addr, 32))
    elseif mn == "sc.w" then
        local addr = rvEffAddr(m, c)
        if m.reservation.valid and m.reservation.addr == addr then
            storeUint(m, addr, 32, rvRead(m, b.name))
            rvWrite(m, a.name, 0)
            m.reservation.valid = false
        else
            rvWrite(m, a.name, 1)
        end
    elseif mn == "amoswap.w" or mn == "amoadd.w" or mn == "amoxor.w" or mn == "amoand.w"
        or mn == "amoor.w" or mn == "amomin.w" or mn == "amomax.w" or mn == "amominu.w" or mn == "amomaxu.w" then
        local addr = rvEffAddr(m, c)
        local old = loadUint(m, addr, 32)
        local val = rvRead(m, b.name)
        local newval: number
        if mn == "amoswap.w" then newval = val
        elseif mn == "amoadd.w" then newval = band(old + val, 0xFFFFFFFF)
        elseif mn == "amoxor.w" then newval = bxor(old, val)
        elseif mn == "amoand.w" then newval = band(old, val)
        elseif mn == "amoor.w" then newval = bor(old, val)
        elseif mn == "amomin.w" then newval = (signedw(old, 32) < signedw(val, 32)) and old or val
        elseif mn == "amomax.w" then newval = (signedw(old, 32) > signedw(val, 32)) and old or val
        elseif mn == "amominu.w" then newval = (old < val) and old or val
        else newval = (old > val) and old or val end
        storeUint(m, addr, 32, newval)
        rvWrite(m, a.name, old)

    
    elseif mn == "li" then rvWrite(m, a.name, rvImm(b))
    elseif mn == "la" then rvWrite(m, a.name, rvImm(b))
    elseif mn == "mv" then rvWrite(m, a.name, rvRead(m, b.name))
    elseif mn == "nop" then
        
    elseif mn == "j" then R.pc = band(rvImm(a), 0xFFFFFFFF)
    elseif mn == "jr" then
        local t = rvRead(m, a.name)
        if t == 0 then m.exited = true; m.exitCode = 0 else R.pc = band(t, 0xFFFFFFFF) end
    elseif mn == "ret" then
        if R.x1 == 0 then m.exited = true; m.exitCode = 0 else R.pc = band(R.x1, 0xFFFFFFFF) end
    elseif mn == "call" then
        rvWrite(m, "x1", band(rec.addr + rec.size, 0xFFFFFFFF))
        R.pc = band(rvImm(a), 0xFFFFFFFF)
    elseif mn == "beqz" then if rvRead(m, a.name) == 0 then R.pc = band(rvImm(b), 0xFFFFFFFF) end
    elseif mn == "bnez" then if rvRead(m, a.name) ~= 0 then R.pc = band(rvImm(b), 0xFFFFFFFF) end
    elseif mn == "blez" then if signedw(rvRead(m, a.name), 32) <= 0 then R.pc = band(rvImm(b), 0xFFFFFFFF) end
    elseif mn == "bgez" then if signedw(rvRead(m, a.name), 32) >= 0 then R.pc = band(rvImm(b), 0xFFFFFFFF) end
    elseif mn == "bltz" then if signedw(rvRead(m, a.name), 32) < 0 then R.pc = band(rvImm(b), 0xFFFFFFFF) end
    elseif mn == "bgtz" then if signedw(rvRead(m, a.name), 32) > 0 then R.pc = band(rvImm(b), 0xFFFFFFFF) end
    elseif mn == "ble" then if signedw(rvRead(m, a.name), 32) <= signedw(rvRead(m, b.name), 32) then R.pc = band(rvImm(c), 0xFFFFFFFF) end
    elseif mn == "bgt" then if signedw(rvRead(m, a.name), 32) > signedw(rvRead(m, b.name), 32) then R.pc = band(rvImm(c), 0xFFFFFFFF) end
    elseif mn == "neg" then rvWrite(m, a.name, band(0 - rvRead(m, b.name), 0xFFFFFFFF))
    elseif mn == "not" then rvWrite(m, a.name, band(bnot(rvRead(m, b.name)), 0xFFFFFFFF))
    elseif mn == "seqz" then rvWrite(m, a.name, (rvRead(m, b.name) == 0) and 1 or 0)
    elseif mn == "snez" then rvWrite(m, a.name, (rvRead(m, b.name) ~= 0) and 1 or 0)
    elseif mn == "fmv.s" then frvWrite(m, a.name, frvRead(m, b.name))
    elseif mn == "fabs.s" then frvWrite(m, a.name, math.abs(frvRead(m, b.name)))
    elseif mn == "fneg.s" then frvWrite(m, a.name, -frvRead(m, b.name))
    elseif mn == "fmv.d" then frvWrite(m, a.name, frvRead(m, b.name))
    elseif mn == "fabs.d" then frvWrite(m, a.name, math.abs(frvRead(m, b.name)))
    elseif mn == "fneg.d" then frvWrite(m, a.name, -frvRead(m, b.name))
    else
        local lineNum: number = rec.line or -1
        machineFail(m, string.format("line %d: unknown instruction: %s", lineNum, tostring(mn)))
    end
end
end



local function x86ResetRegs(m: Machine): ()
    m.regs = { eax = 0, ecx = 0, edx = 0, ebx = 0, esp = STACK_TOP, ebp = 0, esi = 0, edi = 0, eip = 0 }
    m.eflags = 0x00000002  
    
    m.regs.esp = band(m.regs.esp - 4, 0xFFFFFFFF)
    m.mem[m.regs.esp + 1], m.mem[m.regs.esp + 2], m.mem[m.regs.esp + 3], m.mem[m.regs.esp + 4] = 0, 0, 0, 0
end

local function rvResetRegs(m: Machine): ()
    m.regs = {}
    for i = 0, 31 do
        m.regs["x" .. tostring(i)] = 0
    end
    m.regs.pc = 0
    m.regs.x2 = STACK_TOP  
    m.eflags = 0
    m.fregs = {}
    for i = 0, 31 do
        m.fregs["f" .. tostring(i)] = 0.0
    end
end

local function machineReset(m: Machine): ()
    m.mem = table.create(MEM_SIZE, 0)
    m.code = {}
    m.codeByAddr = {}
    m.labels = {}
    m.stdout = {}
    m.stdin = ""
    m.stdinPos = 1
    m.onOutput = nil
    m.stepCount = 0
    m.maxSteps = 1000000
    m.exited = false
    m.exitCode = 0
    m.error = nil
    m.hitBreakpoint = false
    m.values = {}
    m.nextHandle = 0
    m.eventQueue = {}
    m.csr = {}
    m.fregs = {}
    m.reservation = { addr = 0, valid = false }
    m.imports = {}
    m.heapTop = 0x80000
    m.paused = false
    m.pauseReason = nil
    m.breakpoints = {}
    if m.target ~= nil then
        m.target.resetRegs(m)
    end
end

local function newMachine(): Machine
    local self: Machine = {
        regs = {}, eflags = 0, mem = {}, code = {}, codeByAddr = {}, labels = {},
        stdout = {}, stdin = "", stdinPos = 1, onOutput = nil,
        stepCount = 0, maxSteps = 1000000, exited = false, exitCode = 0,
        error = nil, hitBreakpoint = false, values = {}, nextHandle = 0, eventQueue = {},
        target = x86Target, csr = {}, fregs = {}, reservation = { addr = 0, valid = false },
        imports = {},
        heapTop = 0x80000,
        paused = false, pauseReason = nil, breakpoints = {},
    }
    machineReset(self)
    return self
end

local function machineStep(m: Machine): ()
    if m.exited then return end
    m.stepCount += 1
    local pc: number = m.target.getPC(m)
    local rec: any = m.codeByAddr[pc]
    if rec == nil then
        machineFail(m, string.format("PC=0x%X points at non-code", band(pc, 0xFFFFFFFF)))
        return
    end
    m.target.setPC(m, band(rec.addr + rec.size, 0xFFFFFFFF))
    m.target.exec(m, rec)
end

local function machineRun(m: Machine, opts: any?): ()
    local o: any = opts or {}
    local maxSteps: number = o.maxSteps or m.maxSteps
    while not m.exited and not m.paused do
        local pc: number = m.target.getPC(m)
        if m.breakpoints[pc] then
            m.paused = true
            m.pauseReason = "breakpoint"
            return
        end
        if m.stepCount >= maxSteps then
            machineFail(m, string.format("step limit reached (%d steps)", maxSteps))
            return
        end
        machineStep(m)
    end
end

local function machineDump(m: Machine): string
    local out: {string} = {}
    if m.target == rv32Target then
        for i = 0, 31 do
            local abi: string = RV_ABI_NAMES[i] or "?"
            out[#out + 1] = string.format("x%-2d %-4s = 0x%08X  (%d)", i, abi, band(m.regs["x" .. tostring(i)], 0xFFFFFFFF), signedw(m.regs["x" .. tostring(i)], 32))
        end
        local fparts: {string} = {}
        for i = 0, 31 do
            local abi: string = RV_FABI_NAMES[i] or ""
            fparts[#fparts + 1] = string.format("f%-2d%s=%.6g", i, (abi ~= "" and ("(" .. abi .. ")") or ""), m.fregs["f" .. tostring(i)])
        end
        for i = 1, #fparts, 4 do
            out[#out + 1] = table.concat(fparts, "  ", i, math.min(i + 3, #fparts))
        end
        out[#out + 1] = string.format("PC   = 0x%08X", band(m.regs.pc, 0xFFFFFFFF))
        local p = m.regs.pc
        for _ = 1, 5 do
            local rec: any = m.codeByAddr[p]
            if rec == nil then break end
            local txt: string = rec.text or rec.mnemonic
            out[#out + 1] = string.format("0x%08X: %s", p, txt)
            p = p + rec.size
        end
        return table.concat(out, "\n")
    end
    
    local names = { "eax", "ecx", "edx", "ebx", "esp", "ebp", "esi", "edi" }
    for _, n in ipairs(names) do
        out[#out + 1] = string.format("%-4s = 0x%08X  (%d)", n, band(m.regs[n], 0xFFFFFFFF), signedw(m.regs[n], 32))
    end
    out[#out + 1] = string.format("EIP  = 0x%08X", band(m.regs.eip, 0xFFFFFFFF))
    local flBits = { CF, PF, AF, ZF, SF, DF, OF }
    local flNames = { "CF", "PF", "AF", "ZF", "SF", "DF", "OF" }
    local s = "EFLAGS: "
    for i = 1, #flBits do
        s = s .. flNames[i] .. "=" .. ((getf(m, flBits[i])) and "1" or "0") .. " "
    end
    out[#out + 1] = s
    local p = m.regs.eip
    for _ = 1, 5 do
        local rec: any = m.codeByAddr[p]
        if rec == nil then break end
        local txt: string = rec.text or rec.mnemonic
        out[#out + 1] = string.format("0x%08X: %s", p, txt)
        p = p + rec.size
    end
    return table.concat(out, "\n")
end




local function dbgAddBreakpoint(m: Machine, where: any): boolean
    local a: number
    if type(where) == "string" then
        local l: number? = m.labels[where]
        if l == nil then return false end
        a = l
    else
        a = where
    end
    m.breakpoints[band(a, 0xFFFFFFFF)] = true
    return true
end

local function dbgRemoveBreakpoint(m: Machine, where: any): ()
    local a: number?
    if type(where) == "string" then a = m.labels[where] else a = where end
    if a ~= nil then m.breakpoints[band(a, 0xFFFFFFFF)] = nil end
end

local function dbgStep(m: Machine): ()
    if m.exited then return end
    m.paused = false
    machineStep(m)
    m.paused = true
    m.pauseReason = "step"
end

local function dbgContinue(m: Machine, maxSteps: number?): ()
    local pc = m.target.getPC(m)
    local hadBreakpoint = m.breakpoints[pc] ~= nil
    if hadBreakpoint then m.breakpoints[pc] = nil end
    m.paused = false
    machineRun(m, { maxSteps = maxSteps or m.maxSteps })
    if hadBreakpoint then m.breakpoints[pc] = true end
end

local function dbgStepOver(m: Machine): ()
    if m.exited then return end
    local rec: any = m.codeByAddr[m.target.getPC(m)]
    local mn: any = (rec ~= nil) and rec.mnemonic or nil
    local isCall = (mn == "call" or mn == "jal" or mn == "jalr")
    local nextAddr: number? = (rec ~= nil) and (rec.addr + rec.size) or nil
    if isCall and nextAddr ~= nil then
        dbgAddBreakpoint(m, nextAddr)
        dbgContinue(m, m.maxSteps)
        dbgRemoveBreakpoint(m, nextAddr)
    else
        dbgStep(m)
    end
end

local function dbgDumpMemory(m: Machine, addr: number, count: number?): string
    addr = band(addr, 0xFFFFFFFF)
    count = count or 128
    local lines: {string} = {}
    local off = 0
    while off < count do
        local hex: {string} = {}
        local asc: {string} = {}
        for i = 0, 15 do
            if off + i >= count then break end
            local b: number = m.mem[addr + off + i + 1] or 0
            hex[#hex + 1] = string.format("%02X", b)
            asc[#asc + 1] = (b >= 32 and b < 127) and string.char(b) or "."
        end
        lines[#lines + 1] = string.format("%08X  %-48s  %s", addr + off, table.concat(hex, " "), table.concat(asc))
        off = off + 16
    end
    return table.concat(lines, "\n")
end

local function dbgBacktrace(m: Machine): string
    local out: {string} = { string.format("%s pc = 0x%08X", m.target.name, band(m.target.getPC(m), 0xFFFFFFFF)) }
    if m.target == x86Target then
        local sp = m.regs.esp
        for i = 0, 63 do
            local a = band(sp + i * 4, 0xFFFFFFFF)
            local v = loadUint(m, a, 32)
            local rec: any = m.codeByAddr[v]
            if rec ~= nil then
                local mnName: string = rec.mnemonic :: string
                local nOut: number = #out
                out[#out + 1] = string.format("  #%d 0x%08X  %s", nOut, v, mnName)
            end
        end
    end
    return table.concat(out, "\n")
end




x86.new = newMachine
x86.reset = machineReset
x86.fail = machineFail
x86.emit = machineEmit
x86.getOutput = machineGetOutput
x86.readStr = machineReadStr
x86.writeStr = machineWriteStr
x86.handle = machineHandle
x86.deref = machineDeref
x86.enqueueEvent = machineEnqueueEvent
x86.step = machineStep
x86.run = machineRun
x86.dump = machineDump
x86.addBreakpoint = dbgAddBreakpoint
x86.removeBreakpoint = dbgRemoveBreakpoint
x86.dbgStep = dbgStep
x86.dbgStepOver = dbgStepOver
x86.dbgContinue = dbgContinue
x86.dumpMemory = dbgDumpMemory
x86.backtrace = dbgBacktrace

local function assemblePublic(m: Machine, source: string): (boolean, string?)
    local ok, err = pcall(assembleImpl, m, source)
    if not ok then
        machineFail(m, tostring(err))
        return false, tostring(err)
    end
    return true, nil
end
x86.assemble = assemblePublic

local function quickRun(source: string, opts: any?): RunResult
    local m = newMachine()
    local ok, err = assemblePublic(m, source)
    if not ok then
        return { ok = false, error = err or "assemble error", machine = m }
    end
    machineRun(m, opts)
    if m.error ~= nil then
        return { ok = false, error = m.error, machine = m }
    end
    return { ok = true, output = machineGetOutput(m), exitCode = m.exitCode, machine = m }
end
x86.quickRun = quickRun




x86Target.name = "x86"
x86Target.resetRegs = x86ResetRegs
x86Target.parseOperand = x86ParseOperand
x86Target.instrSize = x86InstrSize
x86Target.resolve = x86Resolve
x86Target.exec = exec
x86Target.syscall = x86Syscall
x86Target.getPC = function(m: Machine): number return m.regs.eip end
x86Target.setPC = function(m: Machine, v: number): () m.regs.eip = band(v, 0xFFFFFFFF) end

rv32Target.name = "rv32"
rv32Target.resetRegs = rvResetRegs
rv32Target.parseOperand = rvParseOperand
rv32Target.instrSize = rvInstrSize
rv32Target.resolve = rvResolve
rv32Target.exec = rvExec
rv32Target.syscall = rvSyscall
rv32Target.getPC = function(m: Machine): number return m.regs.pc end
rv32Target.setPC = function(m: Machine, v: number): () m.regs.pc = band(v, 0xFFFFFFFF) end
do
local WINAPI_ASM = [====[
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
]====]

BUILTIN_INCLUDES["winapi"] = WINAPI_ASM
BUILTIN_INCLUDES["windows"] = WINAPI_ASM
x86.WINAPI = WINAPI_ASM
end
type PESection = { name: string, vsize: number, vaddr: number, rawSize: number, rawOff: number }
type PEDir = { rva: number, size: number }
type PEInfo = { machine: number, entryRVA: number, imageBase: number, sections: {PESection}, dirs: {PEDir} }
type Decoded = { mnemonic: string, ops: {any}, size: number, text: string }

do
    local R32: {string} = { "eax", "ecx", "edx", "ebx", "esp", "ebp", "esi", "edi" }
    local R8: {string} = { "al", "cl", "dl", "bl", "ah", "ch", "dh", "bh" }
    local GRP1: {string} = { "add", "or", "adc", "sbb", "and", "sub", "xor", "cmp" }
    local SHIFT: {string} = { "", "", "", "", "shl", "shr", "", "sar" }
    local CC8: {string} = { "o", "no", "b", "ae", "e", "ne", "be", "a", "s", "ns", "p", "np", "l", "ge", "le", "g" }

    local function pu8(b: string, off: number): number
        return b:byte(off + 1) or 0
    end
    local function pu16(b: string, off: number): number
        local v: {any} = { string.unpack("<I2", b, off + 1) }
        return v[1] :: number
    end
    local function pu32(b: string, off: number): number
        local v: {any} = { string.unpack("<I4", b, off + 1) }
        return v[1] :: number
    end

    local function sext8(v: number): number
        if v >= 0x80 then return v - 0x100 end
        return v
    end

    local function opText(op: any): string
        if op.kind == "reg" then return op.name end
        if op.kind == "imm" then
            if op.hex then return string.format("0x%X", op.val) end
            return tostring(op.val)
        end
        local s = "["
        local d = op.disp or 0
        if op.base ~= nil then s = s .. op.base end
        if op.index ~= nil then
            if op.base ~= nil then s = s .. "+" end
            s = s .. op.index
            if op.scale ~= nil and op.scale ~= 1 then s = s .. "*" .. tostring(op.scale) end
        end
        if d ~= 0 then
            if op.base ~= nil or op.index ~= nil then
                if d > 0 then s = s .. "+" .. tostring(d) else s = s .. tostring(d) end
            else
                s = s .. string.format("0x%X", d)
            end
        elseif op.base == nil and op.index == nil then
            s = s .. "0x0"
        end
        return s .. "]"
    end

    local function readAddress(b: string, pos: number, mod: number, rm: number, osize: number): (any, number)
        if rm == 4 then
            local sib = pu8(b, pos)
            pos = pos + 1
            local ss = math.floor(sib / 64)
            local idx = math.floor(sib / 8) % 8
            local bse = sib % 8
            local scale = 1
            if ss == 1 then scale = 2 elseif ss == 2 then scale = 4 elseif ss == 3 then scale = 8 end
            local mem: any = { kind = "mem", base = nil, index = nil, scale = scale, disp = 0, size = osize }
            if idx ~= 4 then mem.index = R32[idx + 1] end
            if not (bse == 5 and mod == 0) then mem.base = R32[bse + 1] end
            if mod == 0 then
                if bse == 5 then mem.disp = pu32(b, pos); pos = pos + 4 end
            elseif mod == 1 then
                mem.disp = sext8(pu8(b, pos)); pos = pos + 1
            elseif mod == 2 then
                mem.disp = pu32(b, pos); pos = pos + 4
            end
            return mem, pos
        end
        local mem: any = { kind = "mem", base = nil, index = nil, scale = 1, disp = 0, size = osize }
        if mod == 0 then
            if rm == 5 then
                mem.disp = pu32(b, pos); pos = pos + 4
            else
                mem.base = R32[rm + 1]
            end
        elseif mod == 1 then
            mem.base = R32[rm + 1]
            mem.disp = sext8(pu8(b, pos)); pos = pos + 1
        elseif mod == 2 then
            mem.base = R32[rm + 1]
            mem.disp = pu32(b, pos); pos = pos + 4
        end
        return mem, pos
    end

    local function readModRM(b: string, pos: number, osize: number, regs: {string}): (any, any, number)
        local modrm = pu8(b, pos)
        pos = pos + 1
        local mod = math.floor(modrm / 64)
        local reg = math.floor(modrm / 8) % 8
        local rm = modrm % 8
        local regOp: any = { kind = "reg", name = regs[reg + 1], size = osize }
        local rmOp: any
        if mod == 3 then
            rmOp = { kind = "reg", name = regs[rm + 1], size = osize }
        else
            rmOp, pos = readAddress(b, pos, mod, rm, osize)
        end
        return regOp, rmOp, pos
    end

    local function decodeOne(b: string, pos0: number, rva: number): Decoded?
        local op = pu8(b, pos0)

        local function fin(mn: string, ops: {any}, sz: number): Decoded
            local t: string = mn
            for i = 1, #ops do
                if i == 1 then
                    t = t .. " "
                else
                    t = t .. ", "
                end
                t = t .. opText(ops[i])
            end
            return { mnemonic = mn, ops = ops, size = sz, text = t }
        end

        if op >= 0xB8 and op <= 0xBF then
            return fin("mov", { { kind = "reg", name = R32[op - 0xB7], size = 32 }, { kind = "imm", val = pu32(b, pos0 + 1) } }, 5)
        elseif op >= 0xB0 and op <= 0xB7 then
            return fin("mov", { { kind = "reg", name = R8[op - 0xAF], size = 8 }, { kind = "imm", val = pu8(b, pos0 + 1) } }, 2)
        elseif op >= 0x40 and op <= 0x47 then
            return fin("inc", { { kind = "reg", name = R32[op - 0x3F], size = 32 } }, 1)
        elseif op >= 0x48 and op <= 0x4F then
            return fin("dec", { { kind = "reg", name = R32[op - 0x47], size = 32 } }, 1)
        elseif op >= 0x50 and op <= 0x57 then
            return fin("push", { { kind = "reg", name = R32[op - 0x4F], size = 32 } }, 1)
        elseif op >= 0x58 and op <= 0x5F then
            return fin("pop", { { kind = "reg", name = R32[op - 0x57], size = 32 } }, 1)
        elseif op >= 0x70 and op <= 0x7F then
            local rel = sext8(pu8(b, pos0 + 1))
            return fin(("j" .. CC8[op - 0x6F]), { { kind = "imm", val = band(rva + 2 + rel, 0xFFFFFFFF), hex = true } }, 2)
        elseif op == 0x68 then
            return fin("push", { { kind = "imm", val = pu32(b, pos0 + 1) } }, 5)
        elseif op == 0x6A then
            return fin("push", { { kind = "imm", val = sext8(pu8(b, pos0 + 1)) } }, 2)
        elseif op == 0x90 then
            return fin("nop", {}, 1)
        elseif op == 0xC3 then
            return fin("ret", {}, 1)
        elseif op == 0xC2 then
            return fin("ret", { { kind = "imm", val = pu16(b, pos0 + 1) } }, 3)
        elseif op == 0xC9 then
            return fin("leave", {}, 1)
        elseif op == 0xE8 then
            local rel = pu32(b, pos0 + 1)
            return fin("call", { { kind = "imm", val = band(rva + 5 + rel, 0xFFFFFFFF), hex = true } }, 5)
        elseif op == 0xE9 then
            local rel = pu32(b, pos0 + 1)
            return fin("jmp", { { kind = "imm", val = band(rva + 5 + rel, 0xFFFFFFFF), hex = true } }, 5)
        elseif op == 0xEB then
            local rel = sext8(pu8(b, pos0 + 1))
            return fin("jmp", { { kind = "imm", val = band(rva + 2 + rel, 0xFFFFFFFF), hex = true } }, 2)
        elseif op == 0xCD then
            return fin("int", { { kind = "imm", val = pu8(b, pos0 + 1) } }, 2)
        elseif op == 0xCC then
            return fin("int", { { kind = "imm", val = 3 } }, 1)
        elseif op == 0x0F then
            local op2 = pu8(b, pos0 + 1)
            if op2 >= 0x80 and op2 <= 0x8F then
                local rel = pu32(b, pos0 + 2)
                return fin(("j" .. CC8[op2 - 0x7F]), { { kind = "imm", val = band(rva + 6 + rel, 0xFFFFFFFF), hex = true } }, 6)
            elseif op2 == 0xAF then
                local r, m, np = readModRM(b, pos0 + 2, 32, R32)
                return fin("imul", { r, m }, np - pos0)
            elseif op2 == 0xB6 then
                local r, m, np = readModRM(b, pos0 + 2, 8, R8)
                r.size = 32
                return fin("movzx", { r, m }, np - pos0)
            elseif op2 == 0xBE then
                local r, m, np = readModRM(b, pos0 + 2, 8, R8)
                r.size = 32
                return fin("movsx", { r, m }, np - pos0)
            end
        elseif op == 0x01 or op == 0x03 or op == 0x29 or op == 0x2B or op == 0x21 or op == 0x23
            or op == 0x09 or op == 0x0B or op == 0x31 or op == 0x33 or op == 0x39 or op == 0x3B
            or op == 0x85 or op == 0x89 or op == 0x8B or op == 0x8D then
            local r, m, np = readModRM(b, pos0 + 1, 32, R32)
            local mn: string
            if op == 0x01 or op == 0x03 then mn = "add"
            elseif op == 0x29 or op == 0x2B then mn = "sub"
            elseif op == 0x21 or op == 0x23 then mn = "and"
            elseif op == 0x09 or op == 0x0B then mn = "or"
            elseif op == 0x31 or op == 0x33 then mn = "xor"
            elseif op == 0x39 or op == 0x3B then mn = "cmp"
            elseif op == 0x85 then mn = "test"
            elseif op == 0x89 or op == 0x8B then mn = "mov"
            else mn = "lea" end
            local ops: {any}
            if op == 0x01 or op == 0x29 or op == 0x21 or op == 0x09 or op == 0x31 or op == 0x39 or op == 0x85 or op == 0x89 then
                ops = { m, r }
            else
                ops = { r, m }
            end
            return fin(mn, ops, np - pos0)
        elseif op == 0x88 or op == 0x8A then
            local r, m, np = readModRM(b, pos0 + 1, 8, R8)
            if op == 0x88 then
                return fin("mov", { m, r }, np - pos0)
            else
                return fin("mov", { r, m }, np - pos0)
            end
        elseif op == 0x81 or op == 0x83 or op == 0x80 then
            local osize = (op == 0x80) and 8 or 32
            local regs = (op == 0x80) and R8 or R32
            local r, m, np = readModRM(b, pos0 + 1, osize, regs)
            local name: string = r.name
            local gi = 0
            for i = 0, 7 do
                if regs[i + 1] == name then
                    gi = i
                    break
                end
            end
            local mn2 = GRP1[gi + 1]
            local imm: number
            local sz: number
            if op == 0x81 then imm = pu32(b, np); sz = np + 4 - pos0
            elseif op == 0x83 then imm = sext8(pu8(b, np)); sz = np + 1 - pos0
            else imm = pu8(b, np); sz = np + 1 - pos0 end
            return fin(mn2, { m, { kind = "imm", val = imm } }, sz)
        elseif op == 0xC7 or op == 0xC6 then
            local osize = (op == 0xC7) and 32 or 8
            local regs = (op == 0xC7) and R32 or R8
            local r, m, np = readModRM(b, pos0 + 1, osize, regs)
            local imm: number
            local sz: number
            if op == 0xC7 then imm = pu32(b, np); sz = np + 4 - pos0
            else imm = pu8(b, np); sz = np + 1 - pos0 end
            return fin("mov", { m, { kind = "imm", val = imm } }, sz)
        elseif op == 0xC1 or op == 0xD1 or op == 0xD3 then
            local r, m, np = readModRM(b, pos0 + 1, 32, R32)
            local name: string = r.name
            local gi = 0
            for i = 0, 7 do
                if R32[i + 1] == name then
                    gi = i
                    break
                end
            end
            local mn2 = SHIFT[gi + 1]
            local cnt: any
            local sz: number
            if op == 0xC1 then cnt = { kind = "imm", val = pu8(b, np) }; sz = np + 1 - pos0
            elseif op == 0xD1 then cnt = { kind = "imm", val = 1 }; sz = np - pos0
            else cnt = { kind = "reg", name = "cl", size = 8 }; sz = np - pos0 end
            return fin(mn2, { m, cnt }, sz)
        elseif op == 0xFF or op == 0xFE then
            local osize = (op == 0xFF) and 32 or 8
            local regs = (op == 0xFF) and R32 or R8
            local r, m, np = readModRM(b, pos0 + 1, osize, regs)
            local name: string = r.name
            local gi = 0
            for i = 0, 7 do
                if regs[i + 1] == name then
                    gi = i
                    break
                end
            end
            if op == 0xFF and gi == 2 then
                return fin("call", { m }, np - pos0)
            end
            if op == 0xFF and gi == 4 then
                return fin("jmp", { m }, np - pos0)
            end
            if op == 0xFF and gi == 6 then
                return fin("push", { m }, np - pos0)
            end
            if gi == 0 then
                return fin("inc", { m }, np - pos0)
            end
            if gi == 1 then
                return fin("dec", { m }, np - pos0)
            end
        elseif op == 0xF7 then
            local r, m, np = readModRM(b, pos0 + 1, 32, R32)
            local name: string = r.name
            local gi = 0
            for i = 0, 7 do
                if R32[i + 1] == name then
                    gi = i
                    break
                end
            end
            local mn: string? = nil
            if gi == 2 then mn = "not" elseif gi == 3 then mn = "neg" elseif gi == 4 then mn = "mul"
            elseif gi == 5 then mn = "imul" elseif gi == 6 then mn = "div" elseif gi == 7 then mn = "idiv" end
            if mn ~= nil then
                return fin(mn, { m }, np - pos0)
            end
        elseif op == 0x69 or op == 0x6B then
            local r, m, np = readModRM(b, pos0 + 1, 32, R32)
            local imm: number
            local sz: number
            if op == 0x69 then imm = pu32(b, np); sz = np + 4 - pos0
            else imm = sext8(pu8(b, np)); sz = np + 1 - pos0 end
            return fin("imul", { r, m, { kind = "imm", val = imm } }, sz)
        end
        return nil
    end

    local function parsePE(b: string): PEInfo
        if b:sub(1, 2) ~= "MZ" then error("not a PE file (no MZ header)") end
        local e_lfanew = pu32(b, 0x3C)
        if b:sub(e_lfanew + 1, e_lfanew + 4) ~= "PE\0\0" then error("bad PE signature") end
        local coff = e_lfanew + 4
        local machine = pu16(b, coff)
        local numSections = pu16(b, coff + 2)
        local sizeOpt = pu16(b, coff + 16)
        local opt = coff + 20
        local magic = pu16(b, opt)
        if magic ~= 0x10B then error("only PE32 supported") end
        local entryRVA = pu32(b, opt + 16)
        local imageBase = pu32(b, opt + 28)
        local numDirs = pu32(b, opt + 92)
        local secOff = opt + sizeOpt
        local sections: {PESection} = {}
        for i = 0, numSections - 1 do
            local s = secOff + i * 40
            local nm = b:sub(s + 1, s + 8):gsub("%z+$", "")
            sections[#sections + 1] = {
                name = nm, vsize = pu32(b, s + 8), vaddr = pu32(b, s + 12),
                rawSize = pu32(b, s + 16), rawOff = pu32(b, s + 20),
            }
        end
        local dirs: {PEDir} = {}
        for i = 0, numDirs - 1 do
            dirs[#dirs + 1] = { rva = pu32(b, opt + 96 + i * 8), size = pu32(b, opt + 100 + i * 8) }
        end
        return { machine = machine, entryRVA = entryRVA, imageBase = imageBase, sections = sections, dirs = dirs }
    end

    local function findCodeSection(pe: PEInfo): PESection?
        for _, sec in ipairs(pe.sections) do
            if sec.name == ".text" then return sec end
        end
        return nil
    end

    local function rvaToOff(pe: PEInfo, rva: number): number?
        for _, sec in ipairs(pe.sections) do
            if rva >= sec.vaddr and rva < sec.vaddr + sec.rawSize then
                return sec.rawOff + (rva - sec.vaddr)
            end
        end
        return nil
    end

    local function decodeRegion(m: Machine, b: string, rva: number, codeSec: PESection): number
        local count = 0
        local addr = rva
        local limit = codeSec.vaddr + codeSec.rawSize
        while addr < limit do
            local off = codeSec.rawOff + (addr - codeSec.vaddr)
            local dec = decodeOne(b, off, addr)
            if dec == nil then break end
            m.codeByAddr[addr] = {
                addr = addr, size = dec.size, mnemonic = dec.mnemonic, prefix = nil,
                ops = dec.ops, line = nil, text = dec.text,
            }
            addr = addr + dec.size
            count = count + 1
        end
        return count
    end

    local IMPORT_STUB_BASE = 0x70000
    local cstr: (string, number, number) -> string

    local function installStub(m: Machine, addr: number, idx: number, nargs: number, isCdecl: boolean): ()
        m.codeByAddr[addr] = { addr = addr, size = 5, mnemonic = "mov", prefix = nil, ops = { { kind = "reg", name = "eax", size = 32 }, { kind = "imm", val = 0x240 } }, line = nil, text = "mov eax, 0x240" }
        m.codeByAddr[addr + 5] = { addr = addr + 5, size = 5, mnemonic = "mov", prefix = nil, ops = { { kind = "reg", name = "ebx", size = 32 }, { kind = "imm", val = idx } }, line = nil, text = "mov ebx, " .. tostring(idx) }
        m.codeByAddr[addr + 10] = { addr = addr + 10, size = 2, mnemonic = "int", prefix = nil, ops = { { kind = "imm", val = 0x80 } }, line = nil, text = "int 0x80" }
        if isCdecl or nargs <= 0 then
            m.codeByAddr[addr + 12] = { addr = addr + 12, size = 1, mnemonic = "ret", prefix = nil, ops = {}, line = nil, text = "ret" }
        else
            m.codeByAddr[addr + 12] = { addr = addr + 12, size = 1, mnemonic = "ret", prefix = nil, ops = { { kind = "imm", val = nargs * 4 } }, line = nil, text = "ret " .. tostring(nargs * 4) }
        end
    end

    local function applyRelocations(b: string, pe: PEInfo): (string, number)
        local delta = 0 - pe.imageBase
        if delta == 0 then
            return b, 0
        end
        local patches: {any} = {}
        local count = 0
        for _, sec in ipairs(pe.sections) do
            if sec.name == ".reloc" then
                local off = sec.rawOff
                local endOff = sec.rawOff + sec.rawSize
                while off + 8 <= endOff do
                    local page = pu32(b, off)
                    local blockSize = pu32(b, off + 4)
                    if blockSize == 0 then break end
                    local entries = (blockSize - 8) / 2
                    for i = 0, entries - 1 do
                        local e = pu16(b, off + 8 + i * 2)
                        local etype = math.floor(e / 4096)
                        local eoff = e % 4096
                        if etype == 3 then
                            local target = rvaToOff(pe, page + eoff)
                            if target ~= nil then
                                local oldv = pu32(b, target)
                                patches[#patches + 1] = { off = target, val = band(oldv + delta, 0xFFFFFFFF) }
                                count = count + 1
                            end
                        end
                    end
                    off = off + blockSize
                end
            end
        end
        if #patches == 0 then
            return b, 0
        end
        table.sort(patches, function(a: any, c: any): boolean return a.off < c.off end)
        local out: {string} = {}
        local prev = 0
        for _, p in ipairs(patches) do
            out[#out + 1] = b:sub(prev + 1, p.off)
            out[#out + 1] = string.pack("<I4", p.val)
            prev = p.off + 4
        end
        out[#out + 1] = b:sub(prev + 1)
        return table.concat(out), count
    end

    local function resolveImports(m: Machine, b: string): any
        local pe = parsePE(b)
        local dir = pe.dirs[2]
        if dir == nil or dir.rva == 0 then
            return { resolved = 0, missing = {} }
        end
        local resolved = 0
        local missing: {string} = {}
        local dOff = rvaToOff(pe, dir.rva)
        if dOff == nil then
            return { resolved = 0, missing = {} }
        end
        local i = 0
        while true do
            local e = dOff + i * 20
            local oft = pu32(b, e)
            local nameRVA = pu32(b, e + 12)
            local firstThunk = pu32(b, e + 16)
            if nameRVA == 0 then break end
            local dll = cstr(b, rvaToOff(pe, nameRVA) :: number, 64)
            local nameThunk = oft ~= 0 and oft or firstThunk
            local t = 0
            while true do
                local iatAddr = firstThunk + t * 4
                local nameEntry = pu32(b, rvaToOff(pe, nameThunk + t * 4) :: number)
                if nameEntry == 0 then break end
                local funcName: string
                if band(nameEntry, 0x80000000) == 0 then
                    local hintName = rvaToOff(pe, nameEntry) :: number
                    funcName = cstr(b, hintName + 2, 64)
                else
                    funcName = "ordinal#" .. tostring(band(nameEntry, 0xFFFF))
                end
                local handler = x86.resolveImportHandler(dll, funcName)
                if handler ~= nil then
                    local idx = #m.imports + 1
                    m.imports[idx] = handler
                    local stub = IMPORT_STUB_BASE + (idx - 1) * 16
                    installStub(m, stub, idx, handler.nargs or 0, handler.cdecl == true)
                    storeUint(m, iatAddr, 32, stub)
                    resolved = resolved + 1
                else
                    missing[#missing + 1] = dll .. "!" .. funcName
                end
                t = t + 1
            end
            i = i + 1
        end
        return { resolved = resolved, missing = missing }
    end

    local function loadPE(m: Machine, b: string): any
        local pe = parsePE(b)
        if pe.machine ~= 0x14C then
            error("only i386 machine type supported (got 0x" .. string.format("%X", pe.machine) .. ")")
        end
        local b2, relocs = applyRelocations(b, pe)
        for _, sec in ipairs(pe.sections) do
            for i = 0, sec.rawSize - 1 do
                m.mem[sec.vaddr + 1 + i] = pu8(b2, sec.rawOff + i)
            end
        end
        local codeSec = findCodeSection(pe)
        if codeSec == nil then error("no .text section") end
        local decoded = decodeRegion(m, b2, pe.entryRVA, codeSec)
        local imp = resolveImports(m, b2)
        m.target.setPC(m, pe.entryRVA)
        return { machine = "i386", entryRVA = pe.entryRVA, imageBase = pe.imageBase, sections = pe.sections, decoded = decoded, imports = imp.resolved, missingImports = imp.missing, relocations = relocs }
    end

    cstr = function(b: string, off: number, maxLen: number): string
        local out: {string} = {}
        for i = 0, maxLen - 1 do
            local ch = pu8(b, off + i)
            if ch == 0 then break end
            out[#out + 1] = string.char(ch)
        end
        return table.concat(out)
    end

    local function listExports(b: string): {any}
        local pe = parsePE(b)
        local dir = pe.dirs[1]
        if dir == nil or dir.rva == 0 then return {} end
        local off = rvaToOff(pe, dir.rva)
        if off == nil then return {} end
        local base = pu32(b, off + 16)
        local numFuncs = pu32(b, off + 20)
        local numNames = pu32(b, off + 24)
        local addrFuncs = pu32(b, off + 28)
        local addrNames = pu32(b, off + 32)
        local addrOrds = pu32(b, off + 36)
        local out: {any} = {}
        for i = 0, numNames - 1 do
            local nameRVA = pu32(b, rvaToOff(pe, addrNames + i * 4) :: number)
            local ord = pu16(b, rvaToOff(pe, addrOrds + i * 2) :: number)
            local fnRVA = pu32(b, rvaToOff(pe, addrFuncs + ord * 4) :: number)
            local name = cstr(b, rvaToOff(pe, nameRVA) :: number, 64)
            out[#out + 1] = { name = name, rva = fnRVA, ordinal = base + ord }
        end
        return out
    end

    local function listImports(b: string): {any}
        local pe = parsePE(b)
        local dir = pe.dirs[2]
        if dir == nil or dir.rva == 0 then return {} end
        local out: {any} = {}
        local dOff = rvaToOff(pe, dir.rva)
        if dOff == nil then return {} end
        local i = 0
        while true do
            local e = dOff + i * 20
            local oft = pu32(b, e)
            local nameRVA = pu32(b, e + 12)
            local firstThunk = pu32(b, e + 16)
            if nameRVA == 0 then break end
            local dll = cstr(b, rvaToOff(pe, nameRVA) :: number, 64)
            local funcs: {string} = {}
            local thunk = firstThunk ~= 0 and firstThunk or oft
            local t = 0
            while true do
                local tv = pu32(b, rvaToOff(pe, thunk + t * 4) :: number)
                if tv == 0 then break end
                if band(tv, 0x80000000) == 0 then
                    local hintName = rvaToOff(pe, tv) :: number
                    funcs[#funcs + 1] = cstr(b, hintName + 2, 64)
                else
                    funcs[#funcs + 1] = "ordinal#" .. tostring(band(tv, 0xFFFF))
                end
                t = t + 1
            end
            out[#out + 1] = { dll = dll, functions = funcs }
            i = i + 1
        end
        return out
    end

    local function getExportRVA(b: string, name: string): number?
        for _, ex in ipairs(listExports(b)) do
            if ex.name == name then return ex.rva end
        end
        return nil
    end

    local function callExport(m: Machine, b: string, name: string, ...: number): number
        local rva = getExportRVA(b, name)
        if rva == nil then error("export not found: " .. tostring(name)) end
        local pe = parsePE(b)
        local codeSec = findCodeSection(pe)
        if codeSec == nil then error("no .text section") end
        local b2 = applyRelocations(b, pe)
        for _, sec in ipairs(pe.sections) do
            for i = 0, sec.rawSize - 1 do
                m.mem[sec.vaddr + 1 + i] = pu8(b2, sec.rawOff + i)
            end
        end
        decodeRegion(m, b2, rva, codeSec)
        resolveImports(m, b2)
        local args: {number} = { ... }
        local savedEsp = m.regs.esp
        for i = #args, 1, -1 do
            m.regs.esp = band(m.regs.esp - 4, 0xFFFFFFFF)
            storeUint(m, m.regs.esp, 32, band(args[i], 0xFFFFFFFF))
        end
        local retStub = 0xE000
        m.codeByAddr[retStub] = { addr = retStub, size = 1, mnemonic = "hlt", ops = {}, line = nil, text = "hlt" }
        m.regs.esp = band(m.regs.esp - 4, 0xFFFFFFFF)
        storeUint(m, m.regs.esp, 32, retStub)
        m.target.setPC(m, rva)
        m.exited = false
        x86.run(m, { maxSteps = 100000 })
        local result = m.regs.eax
        m.regs.esp = savedEsp
        m.exited = false
        return result
    end

    local function disasmPE(b: string): string
        local pe = parsePE(b)
        local out: {string} = {
            string.format("PE32 machine=0x%X entry=0x%X imageBase=0x%X sections=%d", pe.machine, pe.entryRVA, pe.imageBase, #pe.sections),
        }
        for _, sec in ipairs(pe.sections) do
            out[#out + 1] = string.format("  section %-8s vaddr=0x%X rawSize=0x%X rawOff=0x%X", sec.name, sec.vaddr, sec.rawSize, sec.rawOff)
        end
        local codeSec = findCodeSection(pe)
        if codeSec ~= nil then
            local addr = codeSec.vaddr
            local limit = codeSec.vaddr + codeSec.rawSize
            while addr < limit do
                local off = codeSec.rawOff + (addr - codeSec.vaddr)
                local dec = decodeOne(b, off, addr)
                if dec == nil then
                    out[#out + 1] = string.format("  0x%08X: db 0x%02X", addr, pu8(b, off))
                    break
                end
                out[#out + 1] = string.format("  0x%08X: %s", addr, dec.text)
                addr = addr + dec.size
            end
        end
        return table.concat(out, "\n")
    end

    local function disasmAt(b: string, rva: number): string
        local pe = parsePE(b)
        local codeSec = findCodeSection(pe)
        if codeSec == nil then return "" end
        local out: {string} = {}
        local addr = rva
        local limit = codeSec.vaddr + codeSec.rawSize
        while addr < limit do
            local off = codeSec.rawOff + (addr - codeSec.vaddr)
            local dec = decodeOne(b, off, addr)
            if dec == nil then
                out[#out + 1] = string.format("0x%08X: db 0x%02X", addr, pu8(b, off))
                break
            end
            out[#out + 1] = string.format("0x%08X: %s", addr, dec.text)
            addr = addr + dec.size
        end
        return table.concat(out, "\n")
    end

    local B64: { [string]: number } = {}
    do
        for i = 0, 25 do B64[string.char(65 + i)] = i end
        for i = 0, 25 do B64[string.char(97 + i)] = 26 + i end
        for i = 0, 9 do B64[string.char(48 + i)] = 52 + i end
        B64["+"] = 62
        B64["/"] = 63
    end

    local function base64Decode(s: string): string
        s = s:gsub("%s", "")
        local out: {string} = {}
        local buf = 0
        local nbits = 0
        for i = 1, #s do
            local c = s:sub(i, i)
            if c == "=" then break end
            local v: number? = B64[c]
            if v == nil then error("bad base64 char: " .. c) end
            buf = buf * 64 + v
            nbits = nbits + 6
            if nbits >= 8 then
                nbits = nbits - 8
                local byte = math.floor(buf / (2 ^ nbits)) % 256
                out[#out + 1] = string.char(byte)
                buf = buf % (2 ^ nbits)
            end
        end
        return table.concat(out)
    end

    local function bytesFromData(data: string): string
        local clean = data:gsub("%s", "")
        if #clean % 2 == 0 and clean:match("^[0-9A-Fa-f]+$") ~= nil and clean:sub(1, 4):upper() == "4D5A" then
            local t: {string} = {}
            for pair in clean:gmatch("%x%x") do
                t[#t + 1] = string.char(tonumber(pair, 16) or 0)
            end
            return table.concat(t)
        end
        return base64Decode(data)
    end

    x86.loadPE = loadPE
    x86.disasmPE = disasmPE
    x86.disasmAt = disasmAt
    x86.parsePE = parsePE
    x86.listExports = listExports
    x86.listImports = listImports
    x86.getExportRVA = getExportRVA
    x86.callExport = callExport
    x86.bytesFromData = bytesFromData
    x86.base64Decode = base64Decode
end

























local asmLabel: string = "asm"

local function tryRunDll(name: string, src: string): boolean
    local okDec, dec = pcall(x86.bytesFromData, src)
    local bytes: string = ""
    if okDec and type(dec) == "string" then
        bytes = dec :: string
    end
    if bytes == "" or bytes:sub(1, 2) ~= "MZ" then
        return false
    end
    local m = newMachine()
    m.onOutput = function(s: string): ()
        print("[" .. asmLabel .. ":" .. name .. "] " .. s)
    end
    local ok, err = pcall(function(): ()
        local info = x86.loadPE(m, bytes)
        if info.missingImports ~= nil and #info.missingImports > 0 then
            warn("[" .. asmLabel .. "] DLL " .. name .. ": неразрешённые импорты " .. table.concat(info.missingImports, ", "))
        end
        local hasMain = false
        for _, e in ipairs(x86.listExports(bytes)) do
            if e.name == "main" then
                hasMain = true
                break
            end
        end
        if hasMain then
            x86.callExport(m, bytes, "main")
        else
            x86.run(m, { maxSteps = 10000000 })
        end
    end)
    if not ok then
        warn("[" .. asmLabel .. "] DLL error in " .. name .. ": " .. tostring(err))
    elseif m.error ~= nil then
        warn("[" .. asmLabel .. "] " .. name .. ": " .. m.error)
    end
    return true
end

local function runMachine(name: string, src: string): ()
    if tryRunDll(name, src) then
        return
    end
    local m = newMachine()
    m.onOutput = function(s: string): ()
        print("[" .. asmLabel .. ":" .. name .. "] " .. s)
    end
    local ok, err = assemblePublic(m, src)
    if not ok then
        warn("[" .. asmLabel .. "] assemble error in " .. name .. ": " .. tostring(err))
        return
    end
    machineRun(m, { maxSteps = 10000000 })
    if m.error ~= nil then
        warn("[" .. asmLabel .. "] " .. name .. ": " .. m.error)
    end
end

local function runFolder(folder: any): ()
    for _, child in ipairs(folder:GetChildren()) do
        if child:IsA("ModuleScript") then
            local ok, src = pcall(require, child)
            if ok and type(src) == "string" then
                task.spawn(runMachine, child.Name, src)
            end
        end
    end
end

x86.runFolder = runFolder
x86.runMachine = runMachine

asmLabel = "serverAsm"

local SCAN_ALL = false

local function bootstrap(): ()
    local ServerScriptService = game:GetService("ServerScriptService")
    local ServerStorage = game:GetService("ServerStorage")
    local ReplicatedStorage = game:GetService("ReplicatedStorage")
    local Workspace = game:GetService("Workspace")
    local CollectionService = game:GetService("CollectionService")

    local seen: {[any]: boolean} = {}

    local function runModule(child: any): ()
        if seen[child] then return end
        seen[child] = true
        if not child:IsA("ModuleScript") then return end
        local ok, src = pcall(require, child)
        if ok and type(src) == "string" then
            task.spawn(runMachine, child.Name, src)
        end
    end

    
    for _, inst in ipairs(CollectionService:GetTagged("assembler")) do
        runModule(inst)
    end

    
    for _, svc in ipairs({ ServerScriptService, ServerStorage, ReplicatedStorage, Workspace }) do
        local folder = svc:FindFirstChild("assembler")
        if folder ~= nil then
            for _, child in ipairs(folder:GetChildren()) do
                runModule(child)
            end
        end
    end

    
    if SCAN_ALL then
        for _, svc in ipairs({ ServerScriptService, ServerStorage, ReplicatedStorage, Workspace }) do
            for _, child in ipairs(svc:GetDescendants()) do
                if not seen[child] and child:IsA("ModuleScript") then
                    local ok, src = pcall(require, child)
                    if ok and type(src) == "string" then
                        local srcStr: string = src :: string
                        if srcStr:find("^%s*%-%-!assembler") ~= nil then
                            seen[child] = true
                            task.spawn(runMachine, child.Name, srcStr)
                        end
                    end
                end
            end
        end
    end
end

x86._bootstrap = bootstrap


if script ~= nil and script:IsA("ModuleScript") then
    return x86
end

bootstrap()
