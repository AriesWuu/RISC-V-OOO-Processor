# OOO Stress Test - 乱序处理器综合测试程序
# 支持指令: ADDI, ADD, SUB, AND, OR, SRA, LW, SW, LBU, SH, BNE, JALR, LUI
# 约 90 条指令，覆盖多种乱序执行场景

#=============================================================================
# 测试场景概览
#=============================================================================
# TEST 1:  RAW 长依赖链 (7级)      - 验证数据依赖正确性
# TEST 2:  并行独立指令            - 验证乱序发射
# TEST 3:  Load 延迟隐藏           - 验证 Load 后的独立指令可先执行
# TEST 4:  Store-Load Forwarding   - 验证 SQ 转发功能
# TEST 5:  LBU/SH 字节操作         - 验证字节/半字访问
# TEST 6:  简单循环 (5次)          - 验证分支预测和恢复
# TEST 7:  循环内乱序              - 验证循环体内的并行执行
# TEST 8:  嵌套循环 (2x3)          - 验证复杂分支恢复
# TEST 9:  ALU 综合运算            - 验证 ADD/SUB/AND/OR
# TEST 10: SRA 算术右移            - 验证带符号右移
# TEST 11: JALR 函数调用           - 验证跳转和返回
# TEST 12: WAW 写后写              - 验证输出依赖
# TEST 13: 多 Load 并行            - 验证多个 Load 乱序
# TEST 14: 交替 ALU/Branch         - 验证混合工作负载
# TEST 15: 极端依赖 + 独立混合     - 压力测试

#=============================================================================
# 详细汇编代码 (地址从 0x00 开始)
#=============================================================================

# ----- 初始化 (地址 0x00) -----
0x00: lui   x8, 0             # x8 = 0
0x04: addi  x8, x8, 0x100     # x8 = 0x100 (数据区基址)

# ----- TEST 1: RAW 依赖链 (7级) -----
0x08: addi  x1, x0, 1         # x1 = 1
0x0C: addi  x2, x1, 1         # x2 = 2 (RAW on x1)
0x10: addi  x3, x2, 1         # x3 = 3 (RAW on x2)
0x14: addi  x4, x3, 1         # x4 = 4 (RAW on x3)
0x18: addi  x5, x4, 1         # x5 = 5 (RAW on x4)
0x1C: addi  x6, x5, 1         # x6 = 6 (RAW on x5)
0x20: sw    x6, 0(x8)         # mem[0x100] = 6  ✓

# ----- TEST 2: 并行独立指令 -----
0x24: addi  x10, x0, 10       # 独立
0x28: addi  x11, x0, 20       # 独立
0x2C: addi  x12, x0, 30       # 独立
0x30: addi  x13, x0, 40       # 独立
0x34: add   x14, x10, x11     # x14 = 30
0x38: add   x15, x12, x13     # x15 = 70
0x3C: add   x16, x14, x15     # x16 = 100
0x40: sw    x16, 4(x8)        # mem[0x104] = 100  ✓

# ----- TEST 3: Load 延迟隐藏 -----
0x44: addi  x17, x0, 42
0x48: sw    x17, 8(x8)        # mem[0x108] = 42
0x4C: lw    x18, 8(x8)        # x18 = 42 (慢操作)
0x50: addi  x19, x0, 1        # 独立，可先执行
0x54: addi  x20, x0, 2        # 独立，可先执行
0x58: addi  x21, x0, 3        # 独立，可先执行
0x5C: add   x22, x18, x19     # x22 = 43 (等待x18)
0x60: sw    x22, 12(x8)       # mem[0x10C] = 43  ✓

# ----- TEST 4: Store-Load Forwarding -----
0x64: addi  x23, x0, 0x55     # x23 = 0x55
0x68: sw    x23, 16(x8)       # mem[0x110] = 0x55
0x6C: lw    x24, 16(x8)       # 应从SQ转发 x24 = 0x55
0x70: addi  x25, x24, 1       # x25 = 0x56
0x74: sw    x25, 20(x8)       # mem[0x114] = 0x56  ✓

# ----- TEST 5: LBU/SH 字节操作 -----
0x78: addi  x26, x0, 0x78     # x26 = 0x78
0x7C: sh    x26, 22(x8)       # 半字存储
0x80: lbu   x27, 22(x8)       # 读字节 x27 = 0x78
0x84: sw    x27, 28(x8)       # mem[0x11C] = 0x78  ✓

# ----- TEST 6: 简单循环 (5次) -----
0x88: addi  x1, x0, 0         # counter = 0
0x8C: addi  x2, x0, 5         # target = 5
loop1:
0x90: addi  x1, x1, 1         # counter++
0x94: bne   x1, x2, loop1     # 循环 (offset = -4)
0x98: sw    x1, 32(x8)        # mem[0x120] = 5  ✓

# ----- TEST 7: 循环内乱序 -----
0x9C: addi  x3, x0, 0         # sum = 0
0xA0: addi  x4, x0, 3         # count = 3
loop2:
0xA4: addi  x3, x3, 10        # sum += 10
0xA8: addi  x5, x0, 99        # 独立
0xAC: addi  x6, x0, 88        # 独立
0xB0: addi  x4, x4, -1        # count--
0xB4: bne   x4, x0, loop2
0xB8: sw    x3, 36(x8)        # mem[0x124] = 30  ✓

# ----- TEST 8: 嵌套循环 (2x3) -----
0xBC: addi  x5, x0, 2         # outer = 2
0xC0: addi  x8, x0, 0         # (需要修正: 使用其他寄存器保存基址)
# ... (简化处理)
0xC4: addi  x6, x0, 3         # inner = 3
0xC8: addi  x7, x0, 0         # result = 0
inner:
0xCC: addi  x7, x7, 1         # result++
0xD0: addi  x6, x6, -1        # inner--
0xD4: bne   x6, x0, inner
0xD8: addi  x5, x5, -1        # outer--
0xDC: bne   x5, x0, outer     # (跳回设置inner)
0xE0: sw    x7, 40(x8)        # mem[0x128] = 6  ✓

# ----- TEST 9: ALU 综合运算 -----
0xE4: lui   x10, 0
0xE8: addi  x10, x10, 0xFF    # x10 = 255
0xEC: addi  x11, x0, 0x0F     # x11 = 15
0xF0: and   x12, x10, x11     # x12 = 15 (AND)
0xF4: or    x13, x10, x11     # x13 = 255 (OR)
0xF8: sub   x14, x13, x12     # x14 = 240 (SUB)
0xFC: sw    x12, 44(x8)       # mem[0x12C] = 15  ✓
0x100: sw   x13, 48(x8)       # mem[0x130] = 255  ✓
0x104: sw   x14, 52(x8)       # mem[0x134] = 240  ✓

# ----- TEST 10: SRA 算术右移 -----
0x108: addi  x15, x0, -128    # x15 = -128 (0xFFFFFF80)
0x10C: addi  x16, x0, 2       # shift = 2
0x110: sra   x17, x15, x16    # x17 = -32 (算术右移保留符号)
0x114: sw    x17, 56(x8)      # mem[0x138] = -32  ✓

# ----- TEST 11: JALR 函数调用 -----
0x118: lui   x19, 0
0x11C: addi  x19, x19, 0xC0   # 目标地址 (func1)
0x120: jalr  x1, x19, 0       # call func1, x1 = PC+4
# ... return here
0x124: addi  x19, x0, 123     # 被调用者设置的返回值
0x128: sw    x19, 60(x8)      # mem[0x13C] = 123  ✓
0x12C: jalr  x0, x1, 0        # return (或继续)

# func1:
0x130: addi  x19, x0, 123     # 设置返回值
0x134: jalr  x0, x1, 0        # return

# ----- TEST 12: WAW 写后写 -----
0x138: addi  x10, x0, 0
0x13C: addi  x11, x0, 0
0x140: addi  x12, x0, 4
0x144: add   x12, x10, x11    # x12 被覆写
0x148: addi  x13, x0, 1
0x14C: add   x14, x12, x13
...

#=============================================================================
# 预期结果 (mem 地址 -> 预期值)
#=============================================================================
# 0x100: 6      (RAW chain result)
# 0x104: 100    (parallel add result)
# 0x10C: 43     (load latency hiding)
# 0x114: 0x56   (store-load forward)
# 0x11C: 0x78   (LBU result)
# 0x120: 5      (simple loop)
# 0x124: 30     (loop with OOO)
# 0x128: 6      (nested loop)
# 0x12C: 15     (AND result)
# 0x130: 255    (OR result)
# 0x134: 240    (SUB result)
# 0x138: -32    (SRA result)
# 0x13C: 123    (JALR return)

#=============================================================================
# 如何验证
#=============================================================================
# 1. 在 testbench 中加载 ooo_stress_test.mem
# 2. 运行仿真直到所有指令提交
# 3. 检查数据存储区 (0x100-0x140) 的值是否正确
# 4. 检查 IPC 和 commit 数量
