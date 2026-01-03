#!/usr/bin/env python3
"""
RISC-V RV32I 汇编器 - 生成 .mem 文件
支持指令: ADDI, LUI, ORI, SLTIU, SRA, SUB, AND, LBU, LW, SH, SW, BNE, JALR
"""

def encode_r_type(rd, funct3, rs1, rs2, funct7, opcode):
    return (funct7 << 25) | (rs2 << 20) | (rs1 << 15) | (funct3 << 12) | (rd << 7) | opcode

def encode_i_type(rd, funct3, rs1, imm, opcode):
    return ((imm & 0xFFF) << 20) | (rs1 << 15) | (funct3 << 12) | (rd << 7) | opcode

def encode_s_type(funct3, rs1, rs2, imm, opcode):
    imm_11_5 = (imm >> 5) & 0x7F
    imm_4_0 = imm & 0x1F
    return (imm_11_5 << 25) | (rs2 << 20) | (rs1 << 15) | (funct3 << 12) | (imm_4_0 << 7) | opcode

def encode_b_type(funct3, rs1, rs2, imm, opcode):
    # imm[12|10:5|4:1|11]
    imm_12 = (imm >> 12) & 0x1
    imm_11 = (imm >> 11) & 0x1
    imm_10_5 = (imm >> 5) & 0x3F
    imm_4_1 = (imm >> 1) & 0xF
    return (imm_12 << 31) | (imm_10_5 << 25) | (rs2 << 20) | (rs1 << 15) | \
           (funct3 << 12) | (imm_4_1 << 8) | (imm_11 << 7) | opcode

def encode_u_type(rd, imm, opcode):
    return (imm << 12) | (rd << 7) | opcode

# 指令编码函数
def lui(rd, imm):    return encode_u_type(rd, imm & 0xFFFFF, 0x37)
def addi(rd, rs1, imm): return encode_i_type(rd, 0, rs1, imm, 0x13)
def ori(rd, rs1, imm):  return encode_i_type(rd, 6, rs1, imm, 0x13)
def sltiu(rd, rs1, imm): return encode_i_type(rd, 3, rs1, imm, 0x13)
def sub(rd, rs1, rs2):  return encode_r_type(rd, 0, rs1, rs2, 0x20, 0x33)
def and_(rd, rs1, rs2): return encode_r_type(rd, 7, rs1, rs2, 0x00, 0x33)
def sra(rd, rs1, rs2):  return encode_r_type(rd, 5, rs1, rs2, 0x20, 0x33)
def lw(rd, rs1, imm):   return encode_i_type(rd, 2, rs1, imm, 0x03)
def lbu(rd, rs1, imm):  return encode_i_type(rd, 4, rs1, imm, 0x03)
def sw(rs2, rs1, imm):  return encode_s_type(2, rs1, rs2, imm, 0x23)
def sh(rs2, rs1, imm):  return encode_s_type(1, rs1, rs2, imm, 0x23)
def bne(rs1, rs2, imm): return encode_b_type(1, rs1, rs2, imm, 0x63)
def jalr(rd, rs1, imm): return encode_i_type(rd, 0, rs1, imm, 0x67)

def to_bytes(instr):
    """转换为小端序字节"""
    return [(instr >> 0) & 0xFF, (instr >> 8) & 0xFF, 
            (instr >> 16) & 0xFF, (instr >> 24) & 0xFF]

# 寄存器别名
x0, x1, x2, x3, x4, x5, x6, x7 = 0, 1, 2, 3, 4, 5, 6, 7
x8, x9, x10, x11, x12, x13, x14, x15 = 8, 9, 10, 11, 12, 13, 14, 15
x16, x17, x18, x19, x20, x21, x22, x23 = 16, 17, 18, 19, 20, 21, 22, 23
x24, x25, x26, x27, x28, x29, x30, x31 = 24, 25, 26, 27, 28, 29, 30, 31

instructions = []

# ========== 初始化 ==========
instructions.append(lui(x8, 0x10))        # 0x000: lui x8, 0x10
instructions.append(addi(x8, x8, 0x100))  # 0x004: addi x8, x8, 0x100

# ========== TEST 1: 长RAW依赖链 (12级) ==========
instructions.append(addi(x1, x0, 1))      # 0x008
instructions.append(addi(x2, x1, 1))      # 0x00c
instructions.append(addi(x3, x2, 1))      # 0x010
instructions.append(addi(x4, x3, 1))      # 0x014
instructions.append(addi(x5, x4, 1))      # 0x018
instructions.append(addi(x6, x5, 1))      # 0x01c
instructions.append(addi(x7, x6, 1))      # 0x020
instructions.append(addi(x9, x7, 1))      # 0x024
instructions.append(addi(x10, x9, 1))     # 0x028
instructions.append(addi(x11, x10, 1))    # 0x02c
instructions.append(addi(x12, x11, 1))    # 0x030
instructions.append(addi(x13, x12, 1))    # 0x034
instructions.append(sw(x13, x8, 0))       # 0x038

# ========== TEST 2: 并行独立ALU (8条独立ADDI) ==========
instructions.append(addi(x14, x0, 0x111)) # 0x03c
instructions.append(addi(x15, x0, 0x222)) # 0x040
instructions.append(addi(x16, x0, 0x333)) # 0x044
instructions.append(addi(x17, x0, 0x444)) # 0x048
instructions.append(addi(x18, x0, 0x555)) # 0x04c
instructions.append(addi(x19, x0, 0x666)) # 0x050
instructions.append(addi(x20, x0, 0x777)) # 0x054
instructions.append(addi(x21, x0, 0x100)) # 0x058
instructions.append(sw(x14, x8, 4))       # 0x05c
instructions.append(sw(x15, x8, 8))       # 0x060
instructions.append(sw(x16, x8, 12))      # 0x064
instructions.append(sw(x17, x8, 16))      # 0x068

# ========== TEST 3: LUI + ORI 立即数构造 ==========
instructions.append(lui(x22, 0x12345))    # 0x06c
instructions.append(ori(x22, x22, 0x678)) # 0x070
instructions.append(sw(x22, x8, 20))      # 0x074
instructions.append(lui(x23, 0xFEDCB))    # 0x078
instructions.append(ori(x23, x23, 0xA98)) # 0x07c
instructions.append(sw(x23, x8, 24))      # 0x080

# ========== TEST 4: 简单循环 (20次迭代) ==========
instructions.append(addi(x1, x0, 0))      # 0x084
instructions.append(addi(x2, x0, 20))     # 0x088
# loop1: 0x08c
instructions.append(addi(x1, x1, 1))      # 0x08c
instructions.append(bne(x1, x2, -4))      # 0x090 -> 0x08c
instructions.append(sw(x1, x8, 28))       # 0x094

# ========== TEST 5: 嵌套循环 (8 x 6 = 48次内部) ==========
instructions.append(addi(x3, x0, 0))      # 0x098
instructions.append(addi(x4, x0, 8))      # 0x09c
instructions.append(addi(x5, x0, 6))      # 0x0a0
# outer1: 0x0a4
instructions.append(addi(x3, x3, 1))      # 0x0a4
instructions.append(addi(x5, x5, -1))     # 0x0a8
instructions.append(bne(x5, x0, -8))      # 0x0ac -> 0x0a4
instructions.append(addi(x4, x4, -1))     # 0x0b0
instructions.append(addi(x5, x0, 6))      # 0x0b4 重置内层计数器
instructions.append(bne(x4, x0, -20))     # 0x0b8 -> 0x0a4
instructions.append(sw(x3, x8, 32))       # 0x0bc

# ========== TEST 6: 多Store并发 ==========
instructions.append(addi(x6, x0, 0xAA))   # 0x0c0
instructions.append(addi(x7, x0, 0xBB))   # 0x0c4
instructions.append(addi(x9, x0, 0xCC))   # 0x0c8
instructions.append(addi(x10, x0, 0xDD))  # 0x0cc
instructions.append(sh(x6, x8, 36))       # 0x0d0
instructions.append(sh(x7, x8, 38))       # 0x0d4
instructions.append(sh(x9, x8, 40))       # 0x0d8
instructions.append(sh(x10, x8, 42))      # 0x0dc

# ========== TEST 7: Load后运算 ==========
instructions.append(lw(x11, x8, 36))      # 0x0e0
instructions.append(lw(x12, x8, 40))      # 0x0e4
instructions.append(and_(x13, x11, x12))  # 0x0e8
instructions.append(sw(x13, x8, 44))      # 0x0ec

# ========== TEST 8: LBU 字节加载测试 ==========
instructions.append(addi(x14, x0, 0x12))  # 0x0f0
instructions.append(sw(x14, x8, 48))      # 0x0f4
instructions.append(lbu(x15, x8, 48))     # 0x0f8
instructions.append(lbu(x16, x8, 49))     # 0x0fc
instructions.append(lbu(x17, x8, 50))     # 0x100
instructions.append(lbu(x18, x8, 51))     # 0x104
instructions.append(sw(x15, x8, 52))      # 0x108

# ========== TEST 9: SRA 算术右移测试 ==========
instructions.append(lui(x14, 0x80000))    # 0x10c
instructions.append(addi(x17, x0, 4))     # 0x110
instructions.append(sra(x19, x14, x17))   # 0x114
instructions.append(sw(x19, x8, 56))      # 0x118
instructions.append(addi(x18, x0, 8))     # 0x11c
instructions.append(sra(x21, x14, x18))   # 0x120
instructions.append(sw(x21, x8, 60))      # 0x124

# ========== TEST 10: SLTIU 无符号比较测试 ==========
instructions.append(addi(x1, x0, 10))     # 0x128
instructions.append(sltiu(x2, x1, 20))    # 0x12c
instructions.append(sltiu(x3, x1, 5))     # 0x130
instructions.append(sltiu(x4, x1, 10))    # 0x134
instructions.append(sw(x2, x8, 64))       # 0x138
instructions.append(sw(x3, x8, 68))       # 0x13c

# ========== TEST 11: SUB 减法测试 ==========
instructions.append(addi(x5, x0, 100))    # 0x140
instructions.append(addi(x6, x0, 30))     # 0x144
instructions.append(sub(x7, x5, x6))      # 0x148
instructions.append(sw(x7, x8, 72))       # 0x14c
instructions.append(sub(x9, x6, x5))      # 0x150
instructions.append(sw(x9, x8, 76))       # 0x154

# 计算函数地址 (当前位置 + N条指令后)
# func1 在 0x1ec, func2 在 0x200, func3 在 0x214, func4 在 0x234

# ========== TEST 12: 函数调用 1 ==========
instructions.append(lui(x29, 0))          # 0x158
instructions.append(addi(x29, x29, 0x1ec))# 0x15c func1地址
instructions.append(jalr(x1, x29, 0))     # 0x160
instructions.append(sw(x10, x8, 80))      # 0x164

# ========== TEST 13: 函数调用 2 ==========
instructions.append(lui(x29, 0))          # 0x168
instructions.append(addi(x29, x29, 0x200))# 0x16c func2地址
instructions.append(jalr(x1, x29, 0))     # 0x170
instructions.append(sw(x10, x8, 84))      # 0x174

# ========== TEST 14: 函数调用 3 ==========
instructions.append(lui(x29, 0))          # 0x178
instructions.append(addi(x29, x29, 0x214))# 0x17c func3地址
instructions.append(jalr(x1, x29, 0))     # 0x180
instructions.append(sw(x10, x8, 88))      # 0x184

# ========== TEST 15: 函数调用 4 ==========
instructions.append(lui(x29, 0))          # 0x188
instructions.append(addi(x29, x29, 0x234))# 0x18c func4地址
instructions.append(jalr(x1, x29, 0))     # 0x190
instructions.append(sw(x10, x8, 92))      # 0x194

# ========== TEST 16: 长循环 (50次) ==========
instructions.append(addi(x11, x0, 0))     # 0x198
instructions.append(addi(x12, x0, 50))    # 0x19c
# loop3: 0x1a0
instructions.append(addi(x11, x11, 1))    # 0x1a0
instructions.append(bne(x11, x12, -4))    # 0x1a4 -> 0x1a0
instructions.append(sw(x11, x8, 96))      # 0x1a8

# ========== TEST 17: 循环内混合操作 (10次) ==========
instructions.append(addi(x13, x0, 0))     # 0x1ac
instructions.append(addi(x14, x0, 10))    # 0x1b0
# loop4: 0x1b4
instructions.append(addi(x13, x13, 5))    # 0x1b4
instructions.append(addi(x16, x0, 0xFF))  # 0x1b8
instructions.append(and_(x17, x13, x16))  # 0x1bc
instructions.append(addi(x14, x14, -1))   # 0x1c0
instructions.append(bne(x14, x0, -16))    # 0x1c4 -> 0x1b4
instructions.append(sw(x13, x8, 100))     # 0x1c8

# ========== TEST 18: 嵌套循环 (5 x 5 = 25次) ==========
instructions.append(addi(x18, x0, 0))     # 0x1cc
instructions.append(addi(x19, x0, 5))     # 0x1d0
# loop5_outer: 0x1d4
instructions.append(addi(x21, x0, 5))     # 0x1d4
# loop5_inner: 0x1d8
instructions.append(addi(x18, x18, 1))    # 0x1d8
instructions.append(addi(x21, x21, -1))   # 0x1dc
instructions.append(bne(x21, x0, -8))     # 0x1e0 -> 0x1d8
instructions.append(addi(x19, x19, -1))   # 0x1e4
instructions.append(bne(x19, x0, -20))    # 0x1e8 -> 0x1d4

# ========== 程序结束 (跳转到函数区域前) ==========
func_start = len(instructions) * 4  # 当前地址

# func1: 读取并加10
# 地址 0x1ec
instructions.append(lw(x5, x8, 0))        # 0x1ec
instructions.append(addi(x5, x5, 10))     # 0x1f0
instructions.append(addi(x10, x5, 0))     # 0x1f4
instructions.append(jalr(x0, x1, 0))      # 0x1f8: ret

# func2: 读取两个值并AND
# 地址 0x200 (需要调整)
instructions.append(lw(x5, x8, 4))        # 0x1fc
instructions.append(lw(x6, x8, 8))        # 0x200
instructions.append(and_(x5, x5, x6))     # 0x204
instructions.append(addi(x10, x5, 0))     # 0x208
instructions.append(jalr(x0, x1, 0))      # 0x20c: ret

# func3: 含循环的函数
# 地址 0x214 (需要调整)
instructions.append(addi(x5, x0, 0))      # 0x210
instructions.append(addi(x6, x0, 5))      # 0x214
# func3_loop: 0x218
instructions.append(addi(x5, x5, 3))      # 0x218
instructions.append(addi(x6, x6, -1))     # 0x21c
instructions.append(bne(x6, x0, -8))      # 0x220 -> 0x218
instructions.append(addi(x10, x5, 0))     # 0x224
instructions.append(jalr(x0, x1, 0))      # 0x228: ret

# func4: 复杂运算
# 地址 0x234 (需要调整)
instructions.append(lw(x5, x8, 12))       # 0x22c
instructions.append(lw(x6, x8, 16))       # 0x230
instructions.append(and_(x10, x5, x6))    # 0x234
instructions.append(addi(x12, x0, 0xF0))  # 0x238
instructions.append(and_(x10, x10, x12))  # 0x23c
instructions.append(jalr(x0, x1, 0))      # 0x240: ret

# 程序结束标记
instructions.append(addi(x10, x0, 0x42))  # 0x244 返回值
instructions.append(addi(x11, x0, 0))     # 0x248
instructions.append(0x00000000)            # 0x24c halt (全零指令表示程序结束)

# 输出到文件
output_path = r"d:\Vivado_Project\116C_Honor\189_ooo_processor_top\189_ooo_processor_top.srcs\sources_1\new\complex_test.mem"

with open(output_path, 'w') as f:
    for instr in instructions:
        bytes_list = to_bytes(instr)
        for b in bytes_list:
            f.write(f"{b:02x}\n")

print(f"生成 {len(instructions)} 条指令 ({len(instructions)*4} 字节)")
print(f"输出到: {output_path}")

# 验证输出
print("\n前20条指令:")
for i, instr in enumerate(instructions[:20]):
    print(f"0x{i*4:03x}: 0x{instr:08x}")
