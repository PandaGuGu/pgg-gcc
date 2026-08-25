# pggcc0.s —— pggcc v0（P0 阶段）自研编译器本体（无蛋 stage-0）
#
# 职责：读入 argv[1] 单表达式 → 输出一段可独立运行的 i386 AT&T 汇编（.s 文本）
#      该 .s 由 as --32 + ld -m elf_i386（无 crt/libc）后运行，打印表达式十进制值。
#
# 本文件完全自研：词法/语法/代码生成均在汇编底层实现，不调用任何 C/C++ 编译器。
# 参考来源：ISO/IEC 9899:1990（C90）§6.1 词法元素、§6.3 表达式；i386 汇编自产自证。
#
# 输入/输出协议（architecture-v0-eggfree.md §7）：
#   输入：argv[1] 单表达式（token 集：NUM + - * / ( )）
#   输出：汇编 → stdout；错误 → stderr
#   退出码：0 成功 / 2 语法错误 / 1 参数错误或非法字符
#   空白跳过：空格(0x20) \t \n \r；数字与中间结果 int32，解析越界钳制不报
#
# 编译器自身寄存器约定（单页注释，实现期固化）：
#   %esi  = 输入游标（argv[1] 内前进）
#   %ebp  = 临时（词法：数字钳制标志；行内复制循环：计数器）
#   %eax/%ecx/%edx/%edi = 临时值
#   %esp/%ebp 之外不用栈帧：递归下降的 token 状态全部在内存变量（tok_*）
#   输出文本走"行缓冲" out_line/out_len，一行组完一次性 write
#   ⚠ app_* 系列助手会破坏 %ecx/%edx，跨 call 保持的计数/指针须存放
#     在 %esi/%ebp/%edi（本文件已按此约定实现，改动时注意）

.equ TOK_END,    0
.equ TOK_NUM,    1
.equ TOK_PLUS,   2
.equ TOK_MINUS,  3
.equ TOK_STAR,   4
.equ TOK_SLASH,  5
.equ TOK_LPAREN, 6
.equ TOK_RPAREN, 7

.section .rodata
msg_usage:  .asciz "error: usage: pggcc <expr>\n"
s_err_pre:  .asciz "error: "
s_space:    .asciz " "
s_nl:       .asciz "\n"

# ---- 生成程序（.s）固定文本模板 ----
s_head:     .asciz ".section .text\n.globl _start\n_start:\n"
s_push_pre: .asciz "    pushl $"
op_add:     .asciz "    popl %ecx\n    popl %eax\n    addl %ecx, %eax\n    pushl %eax\n"
op_sub:     .asciz "    popl %ecx\n    popl %eax\n    subl %ecx, %eax\n    pushl %eax\n"
op_mul:     .asciz "    popl %ecx\n    popl %eax\n    imull %ecx, %eax\n    pushl %eax\n"
op_div:     .asciz "    popl %ecx\n    popl %eax\n    cltd\n    idivl %ecx\n    pushl %eax\n"
unary_neg:  .asciz "    popl %eax\n    negl %eax\n    pushl %eax\n"
# 生成程序尾部（结果弹 %eax → print_decimal → 换行 → exit；运行时助手与 .bss 同段输出）
s_tail:     .asciz "    popl %eax\n    call print_decimal\n    movl $10, %eax\n    call print_char\n    movl $1, %eax\n    xorl %ebx, %ebx\n    int $0x80\n\nprint_decimal:\n    pushl %ebx\n    pushl %ecx\n    pushl %edx\n    pushl %esi\n    pushl %edi\n    test %eax, %eax\n    jns .Lpd_pos\n    movl %eax, %esi\n    movl $'-', %eax\n    call print_char\n    movl %esi, %eax\n    negl %eax\n.Lpd_pos:\n    movl %eax, %edi\n    leal runt_buf+15, %esi\n    movb $0, (%esi)\n.Lpd_loop:\n    movl %edi, %eax\n    xorl %edx, %edx\n    movl $10, %ebx\n    divl %ebx\n    movl %eax, %edi\n    addb $'0', %dl\n    decl %esi\n    movb %dl, (%esi)\n    test %edi, %edi\n    jnz .Lpd_loop\n    movl $4, %eax\n    movl $1, %ebx\n    movl %esi, %ecx\n    leal runt_buf+15, %edx\n    subl %esi, %edx\n    int $0x80\n    popl %edi\n    popl %esi\n    popl %edx\n    popl %ecx\n    popl %ebx\n    ret\n\nprint_char:\n    pushl %eax\n    pushl %ebx\n    pushl %ecx\n    pushl %edx\n    leal runt_cbuf, %ecx\n    movb %al, (%ecx)\n    movl $1, %edx\n    movl $1, %ebx\n    movl $4, %eax\n    int $0x80\n    popl %edx\n    popl %ecx\n    popl %ebx\n    popl %eax\n    ret\n\n.section .bss\nrunt_buf:  .space 16\nrunt_cbuf: .space 1\n"

# ---- 编译器自身工作内存（.bss） ----
.section .bss
input_start: .long 0      # argv[1] 起始地址（错误位置 = tok_start - input_start）
tok_kind:    .long 0      # 当前 token 种类
tok_ival:    .long 0      # NUM 的字面值
tok_start:   .long 0      # token 起始字节地址
tok_len:     .long 0      # token 文本长度（数字串长度/运算符=1）
out_len:     .long 0      # 行缓冲已用字节数
out_line:    .space 128   # 行缓冲：一行组完再写
dec_buf:     .space 16    # 十进制转换缓冲（右对齐，末位 NUL，最多 10 位数字）

.section .text
.globl _start
_start:
    movl (%esp), %ecx             # argc
    cmpl $2, %ecx
    jne Larg_err                  # 参数个数错误 → 退出 1
    movl 8(%esp), %esi            # argv[1] = 表达式
    movl %esi, input_start
    leal s_head, %ecx
    call emit_template            # 输出生成程序头部
    call next_token
    call parse_expr
    movl tok_kind, %eax
    cmpl $TOK_END, %eax
    jne Lsyn_err                  # 表达式后还有非 END 内容 → 语法错误
    leal s_tail, %ecx
    call emit_template            # 输出生成程序尾部（print_decimal/print_char/.bss）
    xorl %ebx, %ebx
    movl $1, %eax
    int $0x80                     # exit(0)

# ---- 参数错误：退出 1 ----
Larg_err:
    leal msg_usage, %ecx
    call strlen
    call wr_stderr
    xorl %ebx, %ebx
    incl %ebx
    movl $1, %eax
    int $0x80

# ---- 语法错误：退出 2 ----
Lsyn_err:
    movl $2, %ebx
    jmp err_msg

# ---- 通用错误输出：stderr 打 "error: <位置> <token>\n"，然后按 %ebx 退出 ----
err_msg:
    pushl %ebx                    # 暂存退出码（后续打印会用到 %ebx）
    leal s_err_pre, %ecx
    call strlen
    call wr_stderr
    # 位置 = tok_start - input_start（字节偏移，0 起）
    movl tok_start, %eax
    subl input_start, %eax
    call dec_to_str               # → %ecx=指针 %edx=长度
    call wr_stderr
    leal s_space, %ecx
    call strlen
    call wr_stderr
    # token 文本：数字串截断 8 字符；END 为空
    movl tok_len, %edx
    cmpl $8, %edx
    jbe 1f
    movl $8, %edx
1:
    movl tok_start, %ecx
    call wr_stderr
    leal s_nl, %ecx
    call strlen
    call wr_stderr
    popl %ebx
    movl $1, %eax
    int $0x80

# ===== 词法：取下一个 token =====
# 输入：%esi 游标；输出：tok_kind/tok_ival/tok_start/tok_len，%esi 前进
next_token:
.Lnt_skip:
    movzbl (%esi), %eax
    testl %eax, %eax
    jz .Lnt_end
    cmpb $0x20, %al               # 空格
    je .Lnt_adv
    cmpb $9, %al                  # \t
    je .Lnt_adv
    cmpb $10, %al                 # \n
    je .Lnt_adv
    cmpb $13, %al                 # \r
    je .Lnt_adv
    jmp .Lnt_char
.Lnt_adv:
    incl %esi
    jmp .Lnt_skip
.Lnt_end:
    movl %esi, tok_start
    movl $TOK_END, tok_kind
    movl $0, tok_len
    movl $0, tok_ival
    ret
.Lnt_char:
    movzbl (%esi), %eax
    cmpb $'0', %al
    jb .Lnt_single
    cmpb $'9', %al
    ja .Lnt_single
    # ---- 数字：十进制 ≥1 位，int32 越界钳制不报 ----
    movl %esi, tok_start
    xorl %ecx, %ecx               # 累加值
    xorl %edi, %edi               # 长度
    xorl %ebp, %ebp               # 钳制标志
.Lnt_num:
    movzbl (%esi), %eax
    cmpb $'0', %al
    jb .Lnt_num_done
    cmpb $'9', %al
    ja .Lnt_num_done
    testl %ebp, %ebp
    jnz .Lnt_num_adv              # 已钳制：只前进扫位
    subb $'0', %al
    cmpl $214748364, %ecx         # 214748364 = (2^31-1-7)/10 上界
    jb .Lnt_mul_ok
    je .Lnt_chk7
    jmp .Lnt_clamp
.Lnt_chk7:
    cmpl $7, %eax
    ja .Lnt_clamp
.Lnt_mul_ok:
    imull $10, %ecx, %ecx
    addl %eax, %ecx
    jmp .Lnt_num_adv
.Lnt_clamp:
    movl $1, %ebp
.Lnt_num_adv:
    incl %esi
    incl %edi
    jmp .Lnt_num
.Lnt_num_done:
    movl $TOK_NUM, tok_kind
    testl %ebp, %ebp
    jz .Lnt_store
    movl $2147483647, %ecx        # 取最大值钳制
.Lnt_store:
    movl %ecx, tok_ival
    movl %edi, tok_len
    ret
# ---- 单字符算子 ----
.Lnt_single:
    movl %esi, tok_start
    movl $1, tok_len
    movzbl (%esi), %eax
    cmpb $'+', %al
    je .Lnt_sp
    cmpb $'-', %al
    je .Lnt_sm
    cmpb $'*', %al
    je .Lnt_ss
    cmpb $'/', %al
    je .Lnt_sd
    cmpb $'(', %al
    je .Lnt_sl
    cmpb $')', %al
    je .Lnt_sr
    # 非法字符 → 参数错误（退出 1）
    movl $1, %ebx
    jmp err_msg
.Lnt_sp:  movl $TOK_PLUS,   tok_kind; jmp .Lnt_adv1
.Lnt_sm:  movl $TOK_MINUS,  tok_kind; jmp .Lnt_adv1
.Lnt_ss:  movl $TOK_STAR,   tok_kind; jmp .Lnt_adv1
.Lnt_sd:  movl $TOK_SLASH,  tok_kind; jmp .Lnt_adv1
.Lnt_sl:  movl $TOK_LPAREN, tok_kind; jmp .Lnt_adv1
.Lnt_sr:  movl $TOK_RPAREN, tok_kind; jmp .Lnt_adv1
.Lnt_adv1:
    incl %esi
    ret

# ===== 语法：expr → term (('+'|'-') term)* =====
parse_expr:
    call parse_term
.Lpe_top:
    movl tok_kind, %eax
    cmpl $TOK_PLUS, %eax
    je .Lpe_op
    cmpl $TOK_MINUS, %eax
    je .Lpe_op
    ret
.Lpe_op:
    movl tok_kind, %eax
    pushl %eax                    # 待发码算子压栈（递归解析会重入，不能存单一内存槽）
    call next_token
    call parse_term
    popl %eax                     # 弹回本层算子
    cmpl $TOK_PLUS, %eax
    jne .Lpe_sub
    leal op_add, %ecx
    jmp .Lpe_emit
.Lpe_sub:
    leal op_sub, %ecx
.Lpe_emit:
    call emit_template
    jmp .Lpe_top

# ===== 语法：term → unary (('*'|'/') unary)* =====
parse_term:
    call parse_unary
.Lpt_top:
    movl tok_kind, %eax
    cmpl $TOK_STAR, %eax
    je .Lpt_op
    cmpl $TOK_SLASH, %eax
    je .Lpt_op
    ret
.Lpt_op:
    movl tok_kind, %eax
    pushl %eax                    # 同 .Lpe_op：算子压栈，避免内层重入覆盖
    call next_token
    call parse_unary
    popl %eax
    cmpl $TOK_STAR, %eax
    jne .Lpt_div
    leal op_mul, %ecx
    jmp .Lpt_emit
.Lpt_div:
    leal op_div, %ecx
.Lpt_emit:
    call emit_template
    jmp .Lpt_top

# ===== 语法：unary → '-' unary | primary =====
parse_unary:
    movl tok_kind, %eax
    cmpl $TOK_MINUS, %eax
    jne parse_primary              # 尾调用：直接进 primary，由它的 ret 返回上一级
    call next_token
    call parse_unary
    leal unary_neg, %ecx
    call emit_template
    ret

# ===== 语法：primary → NUM | '(' expr ')' =====
parse_primary:
    movl tok_kind, %eax
    cmpl $TOK_NUM, %eax
    je .Lpp_num
    cmpl $TOK_LPAREN, %eax
    je .Lpp_lp
    # 其余（运算符/END）均为语法错误
    jmp Lsyn_err
.Lpp_num:
    call emit_push_imm
    call next_token
    ret
.Lpp_lp:
    call next_token
    call parse_expr
    movl tok_kind, %eax
    cmpl $TOK_RPAREN, %eax
    jne Lsyn_err                   # 缺右括号
    call next_token
    ret

# ===== 代码生成：字面量 pushl $imm（一行组完一次写） =====
emit_push_imm:
    leal s_push_pre, %ecx
    call app_str
    movl tok_ival, %eax
    call app_dec
    movl $10, %eax
    call app_char
    call emit_line
    ret

# ===== 输出助手 =====
# emit_template: %ecx=NUL 字符串（可含多行）→ 追加+一次写
emit_template:
    call app_str
    call emit_line
    ret

# app_str: %ecx=NUL 字符串 → 逐字符追加到 out_line
app_str:
    pushl %esi
    movl %ecx, %esi
.Las_loop:
    cmpb $0, (%esi)
    je .Las_done
    movzbl (%esi), %eax
    call app_char
    incl %esi
    jmp .Las_loop
.Las_done:
    popl %esi
    ret

# app_dec: %eax=十进制数 → 追加到 out_line
# 注意：app_char 破坏 %ecx/%edx，计数放 %ebp（安全）、源指针放 %esi（自存自取）
app_dec:
    call dec_to_str               # → %ecx=指针 %edx=长度
    pushl %esi
    pushl %ebp
    movl %ecx, %esi
    movl %edx, %ebp
.Lad_loop:
    testl %ebp, %ebp
    jz .Lad_done
    movzbl (%esi), %eax
    call app_char
    incl %esi
    decl %ebp
    jmp .Lad_loop
.Lad_done:
    popl %ebp
    popl %esi
    ret

# app_char: %al → 追加单个字节到 out_line[out_len]（破坏 %ecx/%edx）
app_char:
    movl out_len, %ecx
    leal out_line(%ecx), %edx
    movb %al, (%edx)
    incl %ecx
    movl %ecx, out_len
    ret

# emit_line: write(1, out_line, out_len)；随后清空 out_len
emit_line:
    pushl %eax
    pushl %ebx
    pushl %ecx
    pushl %edx
    movl $4, %eax
    movl $1, %ebx
    leal out_line, %ecx
    movl out_len, %edx
    int $0x80
    movl $0, out_len
    popl %edx
    popl %ecx
    popl %ebx
    popl %eax
    ret

# wr_stderr: write(2, %ecx, %edx)
wr_stderr:
    pushl %eax
    pushl %ebx
    pushl %ecx
    pushl %edx
    movl $4, %eax
    movl $2, %ebx
    int $0x80
    popl %edx
    popl %ecx
    popl %ebx
    popl %eax
    ret

# strlen: %ecx=NUL 字符串 → %edx=长度（%ecx 保持）
strlen:
    movl %ecx, %eax
.Lsl_loop:
    cmpb $0, (%eax)
    je .Lsl_done
    incl %eax
    jmp .Lsl_loop
.Lsl_done:
    subl %ecx, %eax
    movl %eax, %edx
    ret

# dec_to_str: %eax=非负十进制数 → %ecx=dec_buf 内指针 %edx=数字长度
# dec_buf 右对齐：NUL 固定于 dec_buf+15，数字自 dec_buf+14 向左生长
# 注意：本过程使用 %ebx 作除数，调用方若需 %ebx 须自行保存（当前调用方均不依赖）
dec_to_str:
    pushl %esi
    pushl %edi
    leal dec_buf+15, %esi
    movb $0, (%esi)
    movl %eax, %edi
    movl $10, %ebx
.Lds_loop:
    movl %edi, %eax
    xorl %edx, %edx
    divl %ebx
    movl %eax, %edi
    addb $'0', %dl
    decl %esi
    movb %dl, (%esi)
    testl %edi, %edi
    jnz .Lds_loop
    movl %esi, %ecx
    leal dec_buf+15, %edx
    subl %esi, %edx
    popl %edi
    popl %esi
    ret
