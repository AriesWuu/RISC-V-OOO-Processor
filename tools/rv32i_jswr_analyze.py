#!/usr/bin/env python3
"""Disassemble and (optionally) emulate the RV32I program stored as bytes-per-line hex.

This is intentionally self-contained: no external packages.

Assumptions for emulation:
- RV32I only (subset as needed)
- x0 hard-wired to 0
- all other regs start at 0
- memory is sparse and defaults to 0
- program memory beyond the provided bytes reads as 0x00000000
- halt when fetching 0x00000000 (matches many simple testbenches)

If your RTL uses different initial conditions (stack pointer, data memory init, halt condition),
then the dynamic commit count will differ.
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Optional, Tuple


def u32(x: int) -> int:
    return x & 0xFFFFFFFF


def s32(x: int) -> int:
    x &= 0xFFFFFFFF
    return x if x < 0x80000000 else x - 0x100000000


def sext(value: int, bits: int) -> int:
    sign = 1 << (bits - 1)
    mask = (1 << bits) - 1
    value &= mask
    return (value ^ sign) - sign


REG_NAMES = [
    "x0/zero",
    "x1/ra",
    "x2/sp",
    "x3/gp",
    "x4/tp",
    "x5/t0",
    "x6/t1",
    "x7/t2",
    "x8/s0",
    "x9/s1",
    "x10/a0",
    "x11/a1",
    "x12/a2",
    "x13/a3",
    "x14/a4",
    "x15/a5",
    "x16/a6",
    "x17/a7",
    "x18/s2",
    "x19/s3",
    "x20/s4",
    "x21/s5",
    "x22/s6",
    "x23/s7",
    "x24/s8",
    "x25/s9",
    "x26/s10",
    "x27/s11",
    "x28/t3",
    "x29/t4",
    "x30/t5",
    "x31/t6",
]


def rname(reg: int) -> str:
    if 0 <= reg < 32:
        base = REG_NAMES[reg]
        # Keep it compact in listing
        return base.split("/")[0]
    return f"x{reg}"


@dataclass(frozen=True)
class Decoded:
    pc: int
    insn: int
    mnemonic: str
    operands: str
    is_control: bool = False


def load_bytes(mem_path: Path) -> List[int]:
    lines = mem_path.read_text(encoding="utf-8").splitlines()
    out: List[int] = []
    for ln in lines:
        s = ln.strip()
        if not s:
            continue
        if len(s) != 2:
            continue
        try:
            out.append(int(s, 16))
        except ValueError:
            continue
    return out


def bytes_to_words_le(data: List[int]) -> List[int]:
    assert len(data) % 4 == 0
    words: List[int] = []
    for i in range(0, len(data), 4):
        w = data[i] | (data[i + 1] << 8) | (data[i + 2] << 16) | (data[i + 3] << 24)
        words.append(u32(w))
    return words


def imm_i(insn: int) -> int:
    return sext((insn >> 20) & 0xFFF, 12)


def imm_u(insn: int) -> int:
    return insn & 0xFFFFF000


def imm_s(insn: int) -> int:
    imm = ((insn >> 7) & 0x1F) | (((insn >> 25) & 0x7F) << 5)
    return sext(imm, 12)


def imm_b(insn: int) -> int:
    # [12|10:5|4:1|11] << 1
    imm = ((insn >> 31) & 0x1) << 12
    imm |= ((insn >> 25) & 0x3F) << 5
    imm |= ((insn >> 8) & 0xF) << 1
    imm |= ((insn >> 7) & 0x1) << 11
    return sext(imm, 13)


def imm_j(insn: int) -> int:
    # [20|10:1|11|19:12] << 1
    imm = ((insn >> 31) & 0x1) << 20
    imm |= ((insn >> 21) & 0x3FF) << 1
    imm |= ((insn >> 20) & 0x1) << 11
    imm |= ((insn >> 12) & 0xFF) << 12
    return sext(imm, 21)


def decode_one(pc: int, insn: int) -> Decoded:
    opcode = insn & 0x7F
    rd = (insn >> 7) & 0x1F
    funct3 = (insn >> 12) & 0x7
    rs1 = (insn >> 15) & 0x1F
    rs2 = (insn >> 20) & 0x1F
    funct7 = (insn >> 25) & 0x7F

    # Default
    mnemonic = f".word 0x{insn:08x}"
    operands = ""
    is_control = False

    if opcode == 0x37:  # LUI
        mnemonic = "lui"
        operands = f"{rname(rd)}, 0x{imm_u(insn) >> 12:x}"
    elif opcode == 0x17:  # AUIPC
        mnemonic = "auipc"
        operands = f"{rname(rd)}, 0x{imm_u(insn) >> 12:x}"
    elif opcode == 0x13:  # OP-IMM
        imm = imm_i(insn)
        if funct3 == 0x0:
            mnemonic = "addi"
            operands = f"{rname(rd)}, {rname(rs1)}, {imm}"
        elif funct3 == 0x2:
            mnemonic = "slti"
            operands = f"{rname(rd)}, {rname(rs1)}, {imm}"
        elif funct3 == 0x3:
            mnemonic = "sltiu"
            operands = f"{rname(rd)}, {rname(rs1)}, {imm}"
        elif funct3 == 0x4:
            mnemonic = "xori"
            operands = f"{rname(rd)}, {rname(rs1)}, {imm}"
        elif funct3 == 0x6:
            mnemonic = "ori"
            operands = f"{rname(rd)}, {rname(rs1)}, {imm}"
        elif funct3 == 0x7:
            mnemonic = "andi"
            operands = f"{rname(rd)}, {rname(rs1)}, {imm}"
        elif funct3 == 0x1 and funct7 == 0x00:
            sh = (insn >> 20) & 0x1F
            mnemonic = "slli"
            operands = f"{rname(rd)}, {rname(rs1)}, {sh}"
        elif funct3 == 0x5:
            sh = (insn >> 20) & 0x1F
            if funct7 == 0x00:
                mnemonic = "srli"
                operands = f"{rname(rd)}, {rname(rs1)}, {sh}"
            elif funct7 == 0x20:
                mnemonic = "srai"
                operands = f"{rname(rd)}, {rname(rs1)}, {sh}"
    elif opcode == 0x33:  # OP
        if funct3 == 0x0 and funct7 == 0x00:
            mnemonic = "add"
            operands = f"{rname(rd)}, {rname(rs1)}, {rname(rs2)}"
        elif funct3 == 0x0 and funct7 == 0x20:
            mnemonic = "sub"
            operands = f"{rname(rd)}, {rname(rs1)}, {rname(rs2)}"
        elif funct3 == 0x1 and funct7 == 0x00:
            mnemonic = "sll"
            operands = f"{rname(rd)}, {rname(rs1)}, {rname(rs2)}"
        elif funct3 == 0x2 and funct7 == 0x00:
            mnemonic = "slt"
            operands = f"{rname(rd)}, {rname(rs1)}, {rname(rs2)}"
        elif funct3 == 0x3 and funct7 == 0x00:
            mnemonic = "sltu"
            operands = f"{rname(rd)}, {rname(rs1)}, {rname(rs2)}"
        elif funct3 == 0x4 and funct7 == 0x00:
            mnemonic = "xor"
            operands = f"{rname(rd)}, {rname(rs1)}, {rname(rs2)}"
        elif funct3 == 0x5 and funct7 == 0x00:
            mnemonic = "srl"
            operands = f"{rname(rd)}, {rname(rs1)}, {rname(rs2)}"
        elif funct3 == 0x5 and funct7 == 0x20:
            mnemonic = "sra"
            operands = f"{rname(rd)}, {rname(rs1)}, {rname(rs2)}"
        elif funct3 == 0x6 and funct7 == 0x00:
            mnemonic = "or"
            operands = f"{rname(rd)}, {rname(rs1)}, {rname(rs2)}"
        elif funct3 == 0x7 and funct7 == 0x00:
            mnemonic = "and"
            operands = f"{rname(rd)}, {rname(rs1)}, {rname(rs2)}"
    elif opcode == 0x03:  # LOAD
        imm = imm_i(insn)
        if funct3 == 0x0:
            mnemonic = "lb"
            operands = f"{rname(rd)}, {imm}({rname(rs1)})"
        elif funct3 == 0x1:
            mnemonic = "lh"
            operands = f"{rname(rd)}, {imm}({rname(rs1)})"
        elif funct3 == 0x2:
            mnemonic = "lw"
            operands = f"{rname(rd)}, {imm}({rname(rs1)})"
        elif funct3 == 0x4:
            mnemonic = "lbu"
            operands = f"{rname(rd)}, {imm}({rname(rs1)})"
        elif funct3 == 0x5:
            mnemonic = "lhu"
            operands = f"{rname(rd)}, {imm}({rname(rs1)})"
    elif opcode == 0x23:  # STORE
        imm = imm_s(insn)
        if funct3 == 0x0:
            mnemonic = "sb"
            operands = f"{rname(rs2)}, {imm}({rname(rs1)})"
        elif funct3 == 0x1:
            mnemonic = "sh"
            operands = f"{rname(rs2)}, {imm}({rname(rs1)})"
        elif funct3 == 0x2:
            mnemonic = "sw"
            operands = f"{rname(rs2)}, {imm}({rname(rs1)})"
    elif opcode == 0x63:  # BRANCH
        off = imm_b(insn)
        is_control = True
        if funct3 == 0x0:
            mnemonic = "beq"
        elif funct3 == 0x1:
            mnemonic = "bne"
        elif funct3 == 0x4:
            mnemonic = "blt"
        elif funct3 == 0x5:
            mnemonic = "bge"
        elif funct3 == 0x6:
            mnemonic = "bltu"
        elif funct3 == 0x7:
            mnemonic = "bgeu"
        operands = f"{rname(rs1)}, {rname(rs2)}, {pc + off:#x}"
    elif opcode == 0x6F:  # JAL
        off = imm_j(insn)
        is_control = True
        mnemonic = "jal"
        operands = f"{rname(rd)}, {pc + off:#x}"
    elif opcode == 0x67:  # JALR
        imm = imm_i(insn)
        is_control = True
        mnemonic = "jalr"
        operands = f"{rname(rd)}, {imm}({rname(rs1)})"
        # Friendly pseudo names
        if rd == 0 and rs1 == 1 and imm == 0:
            mnemonic = "ret"
            operands = ""
        elif rd == 1 and imm == 0:
            mnemonic = "jalr"  # a call via register
    elif opcode == 0x73:  # SYSTEM (ecall/ebreak)
        is_control = True
        if insn == 0x00000073:
            mnemonic = "ecall"
        elif insn == 0x00100073:
            mnemonic = "ebreak"

    return Decoded(pc=pc, insn=insn, mnemonic=mnemonic, operands=operands, is_control=is_control)


class SparseMem:
    def __init__(self) -> None:
        self.mem: Dict[int, int] = {}

    def lb(self, addr: int) -> int:
        return self.mem.get(u32(addr), 0)

    def sb(self, addr: int, val: int) -> None:
        self.mem[u32(addr)] = val & 0xFF

    def lw(self, addr: int) -> int:
        a = u32(addr)
        b0 = self.lb(a)
        b1 = self.lb(a + 1)
        b2 = self.lb(a + 2)
        b3 = self.lb(a + 3)
        return u32(b0 | (b1 << 8) | (b2 << 16) | (b3 << 24))

    def sw(self, addr: int, val: int) -> None:
        a = u32(addr)
        v = u32(val)
        self.sb(a, v)
        self.sb(a + 1, v >> 8)
        self.sb(a + 2, v >> 16)
        self.sb(a + 3, v >> 24)


def emulate(words: List[int], max_steps: int = 200000) -> Tuple[int, Dict[int, int], List[int], List[int], str]:
    regs = [0] * 32
    pc = 0
    mem = SparseMem()
    exec_hist: Dict[int, int] = {}
    committed_pcs: List[int] = []

    def fetch(pc_val: int) -> int:
        idx = pc_val // 4
        if pc_val % 4 != 0:
            return 0
        if 0 <= idx < len(words):
            return words[idx]
        return 0

    stop_reason = "unknown"

    for step in range(max_steps):
        insn = fetch(pc)
        if insn == 0:
            stop_reason = "fetch==0"
            break

        committed_pcs.append(pc)
        exec_hist[pc] = exec_hist.get(pc, 0) + 1

        opcode = insn & 0x7F
        rd = (insn >> 7) & 0x1F
        funct3 = (insn >> 12) & 0x7
        rs1 = (insn >> 15) & 0x1F
        rs2 = (insn >> 20) & 0x1F
        funct7 = (insn >> 25) & 0x7F

        next_pc = u32(pc + 4)

        def write(rd_idx: int, val: int) -> None:
            if rd_idx != 0:
                regs[rd_idx] = u32(val)

        if opcode == 0x37:  # LUI
            write(rd, imm_u(insn))
        elif opcode == 0x17:  # AUIPC
            write(rd, u32(pc + imm_u(insn)))
        elif opcode == 0x13:  # OP-IMM
            imm = imm_i(insn)
            a = regs[rs1]
            if funct3 == 0x0:  # addi
                write(rd, u32(a + imm))
            elif funct3 == 0x2:  # slti
                write(rd, 1 if s32(a) < imm else 0)
            elif funct3 == 0x3:  # sltiu
                write(rd, 1 if a < u32(imm) else 0)
            elif funct3 == 0x4:  # xori
                write(rd, a ^ u32(imm))
            elif funct3 == 0x6:  # ori
                write(rd, a | u32(imm))
            elif funct3 == 0x7:  # andi
                write(rd, a & u32(imm))
            elif funct3 == 0x1 and funct7 == 0x00:  # slli
                sh = (insn >> 20) & 0x1F
                write(rd, u32(a << sh))
            elif funct3 == 0x5:
                sh = (insn >> 20) & 0x1F
                if funct7 == 0x00:  # srli
                    write(rd, (a >> sh) & 0xFFFFFFFF)
                elif funct7 == 0x20:  # srai
                    write(rd, u32(s32(a) >> sh))
        elif opcode == 0x33:  # OP
            a = regs[rs1]
            b = regs[rs2]
            if funct3 == 0x0 and funct7 == 0x00:
                write(rd, u32(a + b))
            elif funct3 == 0x0 and funct7 == 0x20:
                write(rd, u32(a - b))
            elif funct3 == 0x4 and funct7 == 0x00:
                write(rd, a ^ b)
            elif funct3 == 0x6 and funct7 == 0x00:
                write(rd, a | b)
            elif funct3 == 0x7 and funct7 == 0x00:
                write(rd, a & b)
            elif funct3 == 0x1 and funct7 == 0x00:
                write(rd, u32(a << (b & 0x1F)))
            elif funct3 == 0x5 and funct7 == 0x00:
                write(rd, (a >> (b & 0x1F)) & 0xFFFFFFFF)
            elif funct3 == 0x5 and funct7 == 0x20:
                write(rd, u32(s32(a) >> (b & 0x1F)))
            elif funct3 == 0x2 and funct7 == 0x00:
                write(rd, 1 if s32(a) < s32(b) else 0)
            elif funct3 == 0x3 and funct7 == 0x00:
                write(rd, 1 if a < b else 0)
        elif opcode == 0x03:  # LOAD
            imm = imm_i(insn)
            addr = u32(regs[rs1] + imm)
            if funct3 == 0x2:  # lw
                write(rd, mem.lw(addr))
            elif funct3 == 0x0:  # lb
                write(rd, sext(mem.lb(addr), 8))
            elif funct3 == 0x4:  # lbu
                write(rd, mem.lb(addr))
            elif funct3 == 0x1:  # lh
                lo = mem.lb(addr) | (mem.lb(addr + 1) << 8)
                write(rd, sext(lo, 16))
            elif funct3 == 0x5:  # lhu
                lo = mem.lb(addr) | (mem.lb(addr + 1) << 8)
                write(rd, lo)
        elif opcode == 0x23:  # STORE
            imm = imm_s(insn)
            addr = u32(regs[rs1] + imm)
            if funct3 == 0x2:  # sw
                mem.sw(addr, regs[rs2])
            elif funct3 == 0x0:  # sb
                mem.sb(addr, regs[rs2])
            elif funct3 == 0x1:  # sh
                v = regs[rs2]
                mem.sb(addr, v)
                mem.sb(addr + 1, v >> 8)
        elif opcode == 0x63:  # BRANCH
            off = imm_b(insn)
            a = regs[rs1]
            b = regs[rs2]
            take = False
            if funct3 == 0x0:
                take = a == b
            elif funct3 == 0x1:
                take = a != b
            elif funct3 == 0x4:
                take = s32(a) < s32(b)
            elif funct3 == 0x5:
                take = s32(a) >= s32(b)
            elif funct3 == 0x6:
                take = a < b
            elif funct3 == 0x7:
                take = a >= b
            if take:
                next_pc = u32(pc + off)
        elif opcode == 0x6F:  # JAL
            off = imm_j(insn)
            write(rd, u32(pc + 4))
            next_pc = u32(pc + off)
        elif opcode == 0x67:  # JALR
            imm = imm_i(insn)
            t = u32(regs[rs1] + imm) & ~1
            write(rd, u32(pc + 4))
            next_pc = t
        elif opcode == 0x73:  # SYSTEM
            # treat ecall/ebreak as halt
            stop_reason = "system"
            break

        pc = next_pc
        regs[0] = 0

    else:
        stop_reason = "max_steps"

    return len(committed_pcs), exec_hist, committed_pcs, regs, stop_reason


def main() -> None:
    import argparse

    ap = argparse.ArgumentParser()
    ap.add_argument("mem", type=Path, help="path to *.mem (byte-per-line hex)")
    ap.add_argument("--run", action="store_true", help="also emulate and print expected dynamic commits")
    ap.add_argument("--max-steps", type=int, default=200000)
    args = ap.parse_args()

    data = load_bytes(args.mem)
    if len(data) % 4 != 0:
        raise SystemExit(f"Byte count {len(data)} not multiple of 4")

    words = bytes_to_words_le(data)

    print(f"Static bytes={len(data)} words(instructions)={len(words)}")
    print("\nDisassembly:")
    for i, w in enumerate(words):
        pc = i * 4
        d = decode_one(pc, w)
        ctrl = "CTRL" if d.is_control else "    "
        ops = (" " + d.operands) if d.operands else ""
        print(f"{pc:04x}: {w:08x}  {ctrl}  {d.mnemonic}{ops}")

    if args.run:
        commits, hist, pcs, regs, stop_reason = emulate(words, max_steps=args.max_steps)
        print("\nEmulation (assumptions: regs=0, mem=0, halt on fetch==0):")
        print(f"Committed instructions = {commits}")
        print(f"Stop reason = {stop_reason}")
        if commits:
            print(f"Final PC = 0x{pcs[-1]:08x} (last committed)")
        print(f"Final a0(x10)=0x{regs[10]:08x} ({s32(regs[10])})")
        print(f"Final a1(x11)=0x{regs[11]:08x} ({s32(regs[11])})")
        # show top executed PCs (hot spots)
        top = sorted(hist.items(), key=lambda kv: (-kv[1], kv[0]))[:10]
        print("Top executed PCs:")
        for pc, cnt in top:
            print(f"  0x{pc:08x}: {cnt}")


if __name__ == "__main__":
    main()
