#!/usr/bin/env python3
"""
简单测试程序 - 验证 BNE 循环
"""

def encode_i_type(rd, funct3, rs1, imm, opcode):
    return ((imm & 0xFFF) << 20) | (rs1 << 15) | (funct3 << 12) | (rd << 7) | opcode

def encode_b_type(funct3, rs1, rs2, imm, opcode):
    imm_12 = (imm >> 12) & 0x1
    imm_11 = (imm >> 11) & 0x1
    imm_10_5 = (imm >> 5) & 0x3F
    imm_4_1 = (imm >> 1) & 0xF
    return (imm_12 << 31) | (imm_10_5 << 25) | (rs2 << 20) | (rs1 << 15) | \
           (funct3 << 12) | (imm_4_1 << 8) | (imm_11 << 7) | opcode

def encode_u_type(rd, imm, opcode):
    return (imm << 12) | (rd << 7) | opcode

def addi(rd, rs1, imm): return encode_i_type(rd, 0, rs1, imm, 0x13)
def lui(rd, imm):       return encode_u_type(rd, imm & 0xFFFFF, 0x37)
def bne(rs1, rs2, imm): return encode_b_type(1, rs1, rs2, imm, 0x63)
def jalr(rd, rs1, imm): return encode_i_type(rd, 0, rs1, imm, 0x67)

def to_bytes(instr):
    return [(instr >> 0) & 0xFF, (instr >> 8) & 0xFF, 
            (instr >> 16) & 0xFF, (instr >> 24) & 0xFF]

x0, x1, x2, x3, x10, x11 = 0, 1, 2, 3, 10, 11

instructions = []

# 简单循环测试
# 0x000: addi x1, x0, 0    # counter = 0
# 0x004: addi x2, x0, 5    # limit = 5
# loop:
# 0x008: addi x1, x1, 1    # counter++
# 0x00c: bne x1, x2, -4    # if counter != limit, goto loop
# 0x010: addi x10, x1, 0   # a0 = counter (should be 5)
# 0x014: addi x11, x0, 0   # a1 = 0
# 0x018: jalr x0, 0(x0)    # halt

instructions.append(addi(x1, x0, 0))    # 0x000
instructions.append(addi(x2, x0, 5))    # 0x004
instructions.append(addi(x1, x1, 1))    # 0x008 loop:
instructions.append(bne(x1, x2, -4))    # 0x00c -> 0x008
instructions.append(addi(x10, x1, 0))   # 0x010
instructions.append(addi(x11, x0, 0))   # 0x014
# 用全零指令作为 halt，fetch 会检测到并停止
instructions.append(0x00000000)          # 0x018 halt (NOP/invalid = program end)

# 验证编码
print("简单循环测试程序:")
for i, instr in enumerate(instructions):
    print(f"0x{i*4:03x}: 0x{instr:08x}")

# 输出
output_path = r"d:\Vivado_Project\116C_Honor\189_ooo_processor_top\189_ooo_processor_top.srcs\sources_1\new\simple_loop_test.mem"

with open(output_path, 'w') as f:
    for instr in instructions:
        for b in to_bytes(instr):
            f.write(f"{b:02x}\n")

print(f"\n输出到: {output_path}")
print(f"预期结果: a0=5, a1=0, commits=12 (7静态 + 5次循环 = 7 + 4*4 + 3 ≈ 12)")
