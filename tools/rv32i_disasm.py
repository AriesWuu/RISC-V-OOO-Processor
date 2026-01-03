#!/usr/bin/env python3
"""
RISC-V RV32I 反汇编器 - 验证 .mem 文件中的机器码
支持指令: ADDI, LUI, ORI, SLTIU, SRA, SUB, AND, LBU, LW, SH, SW, BNE, JALR
"""

import sys

# 寄存器名称
REG_NAMES = [f"x{i}" for i in range(32)]

def sign_extend(value, bits):
    """符号扩展"""
    sign_bit = 1 << (bits - 1)
    return (value & (sign_bit - 1)) - (value & sign_bit)

def decode_r_type(instr):
    """R-type: funct7[31:25] rs2[24:20] rs1[19:15] funct3[14:12] rd[11:7] opcode[6:0]"""
    rd = (instr >> 7) & 0x1F
    funct3 = (instr >> 12) & 0x7
    rs1 = (instr >> 15) & 0x1F
    rs2 = (instr >> 20) & 0x1F
    funct7 = (instr >> 25) & 0x7F
    return rd, funct3, rs1, rs2, funct7

def decode_i_type(instr):
    """I-type: imm[31:20] rs1[19:15] funct3[14:12] rd[11:7] opcode[6:0]"""
    rd = (instr >> 7) & 0x1F
    funct3 = (instr >> 12) & 0x7
    rs1 = (instr >> 15) & 0x1F
    imm = sign_extend((instr >> 20) & 0xFFF, 12)
    return rd, funct3, rs1, imm

def decode_s_type(instr):
    """S-type: imm[11:5] rs2[24:20] rs1[19:15] funct3[14:12] imm[4:0] opcode[6:0]"""
    funct3 = (instr >> 12) & 0x7
    rs1 = (instr >> 15) & 0x1F
    rs2 = (instr >> 20) & 0x1F
    imm = ((instr >> 7) & 0x1F) | (((instr >> 25) & 0x7F) << 5)
    imm = sign_extend(imm, 12)
    return funct3, rs1, rs2, imm

def decode_b_type(instr):
    """B-type: imm[12|10:5] rs2[24:20] rs1[19:15] funct3[14:12] imm[4:1|11] opcode[6:0]"""
    funct3 = (instr >> 12) & 0x7
    rs1 = (instr >> 15) & 0x1F
    rs2 = (instr >> 20) & 0x1F
    imm = (((instr >> 8) & 0xF) << 1) | \
          (((instr >> 25) & 0x3F) << 5) | \
          (((instr >> 7) & 0x1) << 11) | \
          (((instr >> 31) & 0x1) << 12)
    imm = sign_extend(imm, 13)
    return funct3, rs1, rs2, imm

def decode_u_type(instr):
    """U-type: imm[31:12] rd[11:7] opcode[6:0]"""
    rd = (instr >> 7) & 0x1F
    imm = instr & 0xFFFFF000
    return rd, imm >> 12

def disassemble(instr, pc):
    """反汇编单条指令"""
    opcode = instr & 0x7F
    
    if opcode == 0x37:  # LUI
        rd, imm = decode_u_type(instr)
        return f"lui {REG_NAMES[rd]}, 0x{imm:x}"
    
    elif opcode == 0x13:  # I-type ALU (ADDI, ORI, SLTIU, etc.)
        rd, funct3, rs1, imm = decode_i_type(instr)
        if funct3 == 0x0:  # ADDI
            return f"addi {REG_NAMES[rd]}, {REG_NAMES[rs1]}, {imm}"
        elif funct3 == 0x6:  # ORI
            return f"ori {REG_NAMES[rd]}, {REG_NAMES[rs1]}, 0x{imm & 0xFFF:x}"
        elif funct3 == 0x3:  # SLTIU
            return f"sltiu {REG_NAMES[rd]}, {REG_NAMES[rs1]}, {imm & 0xFFF}"
        else:
            return f"??? I-type funct3={funct3}"
    
    elif opcode == 0x33:  # R-type ALU (ADD, SUB, AND, SRA, etc.)
        rd, funct3, rs1, rs2, funct7 = decode_r_type(instr)
        if funct3 == 0x0 and funct7 == 0x00:  # ADD
            return f"add {REG_NAMES[rd]}, {REG_NAMES[rs1]}, {REG_NAMES[rs2]}"
        elif funct3 == 0x0 and funct7 == 0x20:  # SUB
            return f"sub {REG_NAMES[rd]}, {REG_NAMES[rs1]}, {REG_NAMES[rs2]}"
        elif funct3 == 0x7 and funct7 == 0x00:  # AND
            return f"and {REG_NAMES[rd]}, {REG_NAMES[rs1]}, {REG_NAMES[rs2]}"
        elif funct3 == 0x5 and funct7 == 0x20:  # SRA
            return f"sra {REG_NAMES[rd]}, {REG_NAMES[rs1]}, {REG_NAMES[rs2]}"
        else:
            return f"??? R-type funct3={funct3} funct7={funct7}"
    
    elif opcode == 0x03:  # Load (LW, LBU, etc.)
        rd, funct3, rs1, imm = decode_i_type(instr)
        if funct3 == 0x2:  # LW
            return f"lw {REG_NAMES[rd]}, {imm}({REG_NAMES[rs1]})"
        elif funct3 == 0x4:  # LBU
            return f"lbu {REG_NAMES[rd]}, {imm}({REG_NAMES[rs1]})"
        else:
            return f"??? Load funct3={funct3}"
    
    elif opcode == 0x23:  # Store (SW, SH, SB)
        funct3, rs1, rs2, imm = decode_s_type(instr)
        if funct3 == 0x2:  # SW
            return f"sw {REG_NAMES[rs2]}, {imm}({REG_NAMES[rs1]})"
        elif funct3 == 0x1:  # SH
            return f"sh {REG_NAMES[rs2]}, {imm}({REG_NAMES[rs1]})"
        elif funct3 == 0x0:  # SB
            return f"sb {REG_NAMES[rs2]}, {imm}({REG_NAMES[rs1]})"
        else:
            return f"??? Store funct3={funct3}"
    
    elif opcode == 0x63:  # Branch (BNE, BEQ, etc.)
        funct3, rs1, rs2, imm = decode_b_type(instr)
        target = pc + imm
        if funct3 == 0x1:  # BNE
            return f"bne {REG_NAMES[rs1]}, {REG_NAMES[rs2]}, {imm} (-> 0x{target:03x})"
        elif funct3 == 0x0:  # BEQ
            return f"beq {REG_NAMES[rs1]}, {REG_NAMES[rs2]}, {imm} (-> 0x{target:03x})"
        else:
            return f"??? Branch funct3={funct3}"
    
    elif opcode == 0x67:  # JALR
        rd, funct3, rs1, imm = decode_i_type(instr)
        if rd == 0 and rs1 == 1 and imm == 0:
            return f"ret  # jalr x0, 0(x1)"
        elif rd == 0 and imm == 0:
            return f"jr {REG_NAMES[rs1]}  # jalr x0, 0({REG_NAMES[rs1]})"
        else:
            return f"jalr {REG_NAMES[rd]}, {imm}({REG_NAMES[rs1]})"
    
    elif opcode == 0x6F:  # JAL
        rd = (instr >> 7) & 0x1F
        imm = (((instr >> 21) & 0x3FF) << 1) | \
              (((instr >> 20) & 0x1) << 11) | \
              (((instr >> 12) & 0xFF) << 12) | \
              (((instr >> 31) & 0x1) << 20)
        imm = sign_extend(imm, 21)
        target = pc + imm
        return f"jal {REG_NAMES[rd]}, {imm} (-> 0x{target:03x})"
    
    else:
        return f"??? opcode=0x{opcode:02x}"

def read_mem_file(filepath):
    """读取 .mem 文件，返回字节列表"""
    bytes_list = []
    with open(filepath, 'r') as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith('//'):
                try:
                    bytes_list.append(int(line, 16))
                except ValueError:
                    pass
    return bytes_list

def main():
    if len(sys.argv) < 2:
        # 默认路径
        filepath = r"d:\Vivado_Project\116C_Honor\189_ooo_processor_top\189_ooo_processor_top.srcs\sources_1\new\complex_test.mem"
    else:
        filepath = sys.argv[1]
    
    print(f"读取文件: {filepath}")
    print("=" * 70)
    
    bytes_list = read_mem_file(filepath)
    print(f"共读取 {len(bytes_list)} 字节 ({len(bytes_list) // 4} 条指令)")
    print("=" * 70)
    print(f"{'地址':>8}  {'机器码':>10}  {'反汇编':<40}")
    print("-" * 70)
    
    pc = 0
    while pc < len(bytes_list):
        if pc + 3 < len(bytes_list):
            # 小端序: byte0 是最低位
            instr = bytes_list[pc] | (bytes_list[pc+1] << 8) | \
                    (bytes_list[pc+2] << 16) | (bytes_list[pc+3] << 24)
            
            disasm = disassemble(instr, pc)
            print(f"0x{pc:03x}:    0x{instr:08x}  {disasm}")
            pc += 4
        else:
            break
    
    print("=" * 70)
    print("反汇编完成！")

if __name__ == "__main__":
    main()
