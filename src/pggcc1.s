# pggcc1.s —— pggcc v1（P1 阶段）自研编译器本体（无蛋 stage-1）
#
# 职责：读入 stdin 程序文本（语句序列，';' 结尾）→ 输出可独立运行的
#      i386 AT&T 汇编（.s 文本），运行时顺序执行并打印最后一条表达式/
#      赋值语句的值（无值语句则打印 0）。构建链 as --32 + ld -m elf_i386（无 crt/libc），
#      全程不调用任何 C/C++ 编译器。本文件由 v0（pggcc0.s）扩展而来。
#
# 语言子集（plan §4.1，ICD 1989:1990 §6.1/§6.3/§6.5/§6.6 词法与声明语义）：
#   decl   := 'int' IDENT (',' IDENT)* ';'
#   stmt   := decl | assign ';' | expr ';'
#   assign := IDENT '=' assign | expr          // 右结合；赋值即表达式，值=右值
#   expr   := term (('+'|'-') term)*
#   term   := unary (('*'|'/') unary)*
#   unary  := '-' unary | primary
#   primary:= NUM | IDENT | '(' expr ')'
# 语义：变量全 int32；使用前须声明（未声明/重复声明/名超16B → 错误 exit 2）；
#       a=b=c 链赋值成立；每语句 ';' 结尾；程序顺序执行，结束打印最后一条
#       值语句的值（无则打印 0）。
#
# 相对 v0 的接口变化（实现时推翻细则处，已在 docs/logs/2026-08-25.md 留痕）：
#   - 输入由 argv[1] 单表达式改为 stdin 程序文本（一次 read ≤4096 字节）；
#   - 栈帧按细则"函数序言预留 4B×变量数"改为**运行时逐声明 subl $4,%esp**
#     （单遍编译无法预知变量总数），第 k 个声明变量槽 = -4(k+1)(%ebp)，语义等价。
#
# 编译器自身寄存器约定（同 v0，改动注意）：
#   %esi=输入游标  %edi=临时  %ebp=词法数字钳制标志
#   %eax/%ecx/%edx=临时；app_* 助手破坏 %ecx/%edx，跨 call 保持值放 %esi/%edi/%ebp 或内存。
#   token 状态、符号表、peek 备份均存内存（递归下降无需编译器栈帧）。

.equ TOK_END,    0
.equ TOK_NUM,    1
.equ TOK_PLUS,   2
.equ TOK_MINUS,  3
.equ TOK_STAR,   4
.equ TOK_SLASH,  5
.equ TOK_LPAREN, 6
.equ TOK_RPAREN, 7
.equ TOK_IDENT,  8
.equ TOK_ASSIGN, 9
.equ TOK_SEMI,   10
.equ TOK_COMMA,  11
.equ TOK_INT,    12

.equ MAX_SYM,    32            # 符号表容量（变量数上限）
.equ MAX_NAMELEN, 16           # 变量名长度上限（细则 §4.1）

.section .rodata
msg_usage:  .asciz "error: usage: pggcc < program.s\n"
s_err_pre:  .asciz "error: "
s_space:    .asciz " "
s_nl:       .asciz "\n"

# ---- 生成程序（.s）固定文本模板 ----
s_head:     .asciz ".section .text\n.globl _start\n_start:\n    pushl %ebp\n    movl %esp, %ebp\n"
s_push_pre: .asciz "    pushl $"
op_add:     .asciz "    popl %ecx\n    popl %eax\n    addl %ecx, %eax\n    pushl %eax\n"
op_sub:     .asciz "    popl %ecx\n    popl %eax\n    subl %ecx, %eax\n    pushl %eax\n"
op_mul:     .asciz "    popl %ecx\n    popl %eax\n    imull %ecx, %eax\n    pushl %eax\n"
op_div:     .asciz "    popl %ecx\n    popl %eax\n    cltd\n    idivl %ecx\n    pushl %eax\n"
unary_neg:  .asciz "    popl %eax\n    negl %eax\n    pushl %eax\n"
decl_alloc: .asciz "    subl $4, %esp\n"                       # 声明：运行时分配一个变量槽
s_vread1:   .asciz "    movl -"                                # +off+ "(%ebp), %eax\n    pushl %eax\n"
s_vread2:   .asciz "(%ebp), %eax\n    pushl %eax\n"
s_bind1:    .asciz "    popl %eax\n    movl %eax, -"           # +off+ "(%ebp)\n    pushl %eax\n"
s_bind2:    .asciz "(%ebp)\n    pushl %eax\n"
s_stmt_end: .asciz "    popl %eax\n"                           # 语句值规整到 %eax
s_xor_eax:  .asciz "    xorl %eax, %eax\n"
s_epilog:   .asciz "    call print_decimal\n    movl $10, %eax\n    call print_char\n    movl $1, %eax\n    xorl %ebx, %ebx\n    int $0x80\n"
# 生成程序运行时助手 + .bss（与 v0 相同；v1 结果由 _start 尾部直接放 %eax，不再 popl）
s_runtime:  .asciz "print_decimal:\n    pushl %ebx\n    pushl %ecx\n    pushl %edx\n    pushl %esi\n    pushl %edi\n    test %eax, %eax\n    jns .Lpd_pos\n    movl %eax, %esi\n    movl $'-', %eax\n    call print_char\n    movl %esi, %eax\n    negl %eax\n.Lpd_pos:\n    movl %eax, %edi\n    leal runt_buf+15, %esi\n    movb $0, (%esi)\n.Lpd_loop:\n    movl %edi, %eax\n    xorl %edx, %edx\n    movl $10, %ebx\n    divl %ebx\n    movl %eax, %edi\n    addb $'0', %dl\n    decl %esi\n    movb %dl, (%esi)\n    test %edi, %edi\n    jnz .Lpd_loop\n    movl $4, %eax\n    movl $1, %ebx\n    movl %esi, %ecx\n    leal runt_buf+15, %edx\n    subl %esi, %edx\n    int $0x80\n    popl %edi\n    popl %esi\n    popl %edx\n    popl %ecx\n    popl %ebx\n    ret\n\nprint_char:\n    pushl %eax\n    pushl %ebx\n    pushl %ecx\n    pushl %edx\n    leal runt_cbuf, %ecx\n    movb %al, (%ecx)\n    movl $1, %edx\n    movl $1, %ebx\n    movl $4, %eax\n    int $0x80\n    popl %edx\n    popl %ecx\n    popl %ebx\n    popl %eax\n    ret\n\n.section .bss\nrunt_buf:  .space 16\nrunt_cbuf: .space 1\n"

# ---- 编译器自身工作内存（.bss） ----
.section .bss
in_buf:      .space 4097    # stdin 读入缓冲（+1 供 NUL 哨兵）
input_start: .long 0        # 程序文本起始地址（错误位置基准）
tok_kind:    .long 0
tok_ival:    .long 0
tok_start:   .long 0
tok_len:     .long 0
save_kind:   .long 0        # peek 备份
save_ival:   .long 0
save_start:  .long 0
save_len:    .long 0
save_cur:    .long 0        # %esi 游标备份
sym_name:    .space MAX_SYM*MAX_NAMELEN   # 变量名表（NUL 结尾）
sym_off:     .space MAX_SYM*4             # 变量槽偏移表（8/12/16... 实际 = 4*(k+1)）
sym_count:   .long 0
scratch_name:.space MAX_NAMELEN+1         # 当前标识符副本
last_valued: .long 0        # 1 = 最新语句是值语句（expr/assign）；0 = decl 或空
out_len:     .long 0
out_line:    .space 128
dec_buf:     .space 16

.section .text
.globl _start
_start:
    # 读入 stdin：read(0, in_buf, 4096)
    movl $3, %eax
    xorl %ebx, %ebx
    leal in_buf, %ecx
    movl $4096, %edx
    int $0x80
    testl %eax, %eax
    js .Lrd_bad
    jmp .Lrd_ok
.Lrd_bad:
    xorl %eax, %eax          # 读失败视为空程序
.Lrd_ok:
    leal in_buf, %esi        # 输入游标 = 缓冲起点
    movl %esi, input_start
    movb $0, in_buf(%eax)    # 文本尾 NUL 哨兵（%eax ≤ 4096，缓冲 4097 安全）
    leal s_head, %ecx
    call emit_template       # 输出生成程序头部 + 序言
    call next_token
    call parse_stmt_loop
    # 生成程序尾部：无值语句时先清零 %eax，再打印
    movl last_valued, %eax
    testl %eax, %eax
    jnz .Lpg_valued
    leal s_xor_eax, %ecx
    call emit_template
.Lpg_valued:
    leal s_epilog, %ecx
    call emit_template
    leal s_runtime, %ecx
    call emit_template
    xorl %ebx, %ebx
    movl $1, %eax
    int $0x80                 # exit(0)

# ---- 语法错误/语义错误：退出 2 ----
Lsyn_err:
    movl $2, %ebx
    jmp err_msg

# ---- 通用错误输出：stderr 打 "error: <位置> <token>\n"，按 %ebx 退出 ----
err_msg:
    pushl %ebx
    leal s_err_pre, %ecx
    call strlen
    call wr_stderr
    movl tok_start, %eax
    subl input_start, %eax
    call dec_to_str
    call wr_stderr
    leal s_space, %ecx
    call strlen
    call wr_stderr
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

# ================= 程序级语法 =================
# parse_stmt_loop: stmt*（遇 END 结束）
parse_stmt_loop:
    # 非法字符已在词法层拦截；此处只接受 END / INT / 表达式或赋值起始
    movl tok_kind, %eax
    cmpl $TOK_END, %eax
    je .Lpsl_done
    cmpl $TOK_INT, %eax
    je parse_decl
    cmpl $TOK_IDENT, %eax
    je .Lpsl_maybe_assign
    # 其余：表达式语句
    jmp .Lpsl_expr
.Lpsl_maybe_assign:
    # IDENT：peek 下一 token 判定赋值（IDENT '='）还是表达式（IDENT 读值）
    call peek_token
    movl tok_kind, %eax
    cmpl $TOK_ASSIGN, %eax
    je .Lpsl_assign
    call restore_token
    jmp .Lpsl_expr
.Lpsl_assign:
    call restore_token
    call parse_assign
    # 要求 ';'（当前 token）
    movl tok_kind, %eax
    cmpl $TOK_SEMI, %eax
    jne Lsyn_err
    call next_token
    call emit_stmt_end
    movl $1, last_valued
    jmp parse_stmt_loop
.Lpsl_expr:
    call parse_expr
    movl tok_kind, %eax
    cmpl $TOK_SEMI, %eax
    jne Lsyn_err
    call next_token
    call emit_stmt_end
    movl $1, last_valued
    jmp parse_stmt_loop
.Lpsl_done:
    ret

# parse_decl: 'int' IDENT (',' IDENT)* ';'（当前 token 为 TOK_INT）
parse_decl:
    movl $0, last_valued       # 声明语句非值语句
    call next_token            # → 第一个 IDENT
    jmp .Lpd_ident
.Lpd_ident:
    movl tok_kind, %eax
    cmpl $TOK_IDENT, %eax
    jne Lsyn_err               # 'int' 后必须是标识符
    call declare_var           # 符号表登记 + 发码 subl $4,%esp
    call next_token
    movl tok_kind, %eax
    cmpl $TOK_COMMA, %eax
    je .Lpd_comma
    cmpl $TOK_SEMI, %eax
    jne Lsyn_err               # 缺 ';'
    call next_token
    jmp parse_stmt_loop
.Lpd_comma:
    call next_token
    jmp .Lpd_ident

# ================= 表达式语法（同 v0 + primary 增 IDENT） =================
parse_assign:                  # 值（在栈顶）返回；当前 token = IDENT 或表达式起始
    movl tok_kind, %eax
    cmpl $TOK_IDENT, %eax
    jne parse_expr
    call peek_token
    movl tok_kind, %eax
    cmpl $TOK_ASSIGN, %eax
    je .Lpa_bind
    call restore_token
    jmp parse_expr
.Lpa_bind:
    call restore_token         # 当前 = IDENT
    call lookup_var            # 未声明 → Lsyn_err；%eax = 槽偏移
    pushl %eax                 # 本层目标槽偏移压栈（递归右值会重入，不能存单一内存槽）
    call next_token            # → '='
    movl tok_kind, %eax
    cmpl $TOK_ASSIGN, %eax
    jne Lsyn_err
    call next_token            # → 右值起始
    call parse_assign          # 右值（递归，链式 a=b=c）→ 值在栈顶
    popl %edi                  # 弹回本层槽偏移（%edi 跨 app_* 调用安全）
    # 赋值：弹右值 → 存槽 → 值压回栈（赋值表达式之值）
    leal s_bind1, %ecx
    call app_str
    movl %edi, %eax
    call app_dec
    leal s_bind2, %ecx
    call app_str
    call emit_line
    ret

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
    pushl %eax
    call next_token
    call parse_term
    popl %eax
    cmpl $TOK_PLUS, %eax
    jne .Lpe_sub
    leal op_add, %ecx
    jmp .Lpe_emit
.Lpe_sub:
    leal op_sub, %ecx
.Lpe_emit:
    call emit_template
    jmp .Lpe_top

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
    pushl %eax
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

parse_unary:
    movl tok_kind, %eax
    cmpl $TOK_MINUS, %eax
    jne parse_primary
    call next_token
    call parse_unary
    leal unary_neg, %ecx
    call emit_template
    ret

parse_primary:
    movl tok_kind, %eax
    cmpl $TOK_NUM, %eax
    je .Lpp_num
    cmpl $TOK_IDENT, %eax
    je .Lpp_ident
    cmpl $TOK_LPAREN, %eax
    je .Lpp_lp
    jmp Lsyn_err
.Lpp_num:
    call emit_push_imm
    call next_token
    ret
.Lpp_ident:
    call lookup_var            # 未声明 → Lsyn_err；值在栈顶
    movl %eax, %edi
    leal s_vread1, %ecx
    call app_str
    movl %edi, %eax
    call app_dec
    leal s_vread2, %ecx
    call app_str
    call emit_line
    call next_token
    ret
.Lpp_lp:
    call next_token
    call parse_expr
    movl tok_kind, %eax
    cmpl $TOK_RPAREN, %eax
    jne Lsyn_err
    call next_token
    ret

# ================= 符号表 =================
# lookup_var: 当前 token = IDENT，查表求槽偏移。
#   未声明 → Lsyn_err（exit 2）；成功 %eax = 槽偏移（如 8）
lookup_var:
    call copy_name
    call sym_find               # %eax = -1 未找到 / 槽偏移
    cmpl $-1, %eax
    je Lsyn_err
    ret

# declare_var: 当前 token = IDENT，登记新变量 + 发码分配槽。
#   重复声明 → Lsyn_err（exit 2）；表满 → Lsyn_err
declare_var:
    call copy_name
    call sym_find
    cmpl $-1, %eax
    jne Lsyn_err                # 已存在 → 重复声明
    movl sym_count, %ecx
    cmpl $MAX_SYM, %ecx
    jge Lsyn_err                # 表满
    # 槽偏移 = 4*(count+1)
    leal 1(%ecx), %eax
    shll $2, %eax
    movl %eax, sym_off(,%ecx,4)
    # 复制 scratch_name → sym_name+count*16（≤16 字节；遇 NUL 补零终止）
    # 注意：以 %esi 作临时源指针（输入游标），须自存自取
    pushl %esi
    movl %ecx, %edi
    shll $4, %edi
    leal sym_name(%edi), %edi
    leal scratch_name, %esi
    xorl %edx, %edx
.Ldv_copy:
    cmpl $MAX_NAMELEN, %edx
    jge .Ldv_emit               # 满 16 字节：无 NUL，sym_find 按 16 字节比较命中
    movb (%esi,%edx), %al
    testb %al, %al
    jz .Ldv_done
    movb %al, (%edi,%edx)
    incl %edx
    jmp .Ldv_copy
.Ldv_done:
    movb $0, (%edi,%edx)
.Ldv_emit:
    popl %esi
    incl sym_count
    leal decl_alloc, %ecx
    call emit_template          # 发码：subl $4,%esp（运行时分配该变量槽）
    ret

# copy_name: 当前 IDENT（tok_start/tok_len）→ scratch_name（NUL 结尾）。
#   名超长（>16）→ Lsyn_err
#   注意：本过程以 %esi 作临时源指针（输入游标），须自存自取
copy_name:
    pushl %esi
    movl tok_len, %ecx
    cmpl $MAX_NAMELEN, %ecx
    jg 1f
    jmp 2f
1:
    # 超长（错误路径直接退出，无需再恢复 %esi）
    jmp Lsyn_err
2:
    leal scratch_name, %edi
    movl tok_start, %esi
    xorl %edx, %edx
.Lcn_loop:
    cmpl %ecx, %edx
    jge .Lcn_done
    movb (%esi,%edx), %al
    movb %al, (%edi,%edx)
    incl %edx
    jmp .Lcn_loop
.Lcn_done:
    movb $0, (%edi,%edx)
    popl %esi
    ret

# sym_find: 比较 scratch_name 与符号表；%eax = 槽偏移 / -1 未找到
#   注意：本过程以 %esi 作槽指针（输入游标），须自存自取
sym_find:
    pushl %esi
    movl $0, %edi                # i
.Lsf_test:
    cmpl sym_count, %edi
    jge .Lsf_miss
    # strcmp(sym_name + i*16, scratch_name)
    movl %edi, %ecx
    shll $4, %ecx
    leal sym_name(%ecx), %esi
    leal scratch_name, %edx
    xorl %eax, %eax              # j
.Lsf_cmp:
    movb (%eax,%esi), %cl
    movb (%eax,%edx), %ch
    cmpb %ch, %cl
    jne .Lsf_next
    testb %ch, %ch
    jz .Lsf_hit
    incl %eax
    cmpl $MAX_NAMELEN, %eax
    jb .Lsf_cmp
    jmp .Lsf_hit                 # 满 16 字节全等
.Lsf_next:
    incl %edi
    jmp .Lsf_test
.Lsf_hit:
    popl %esi
    movl %edi, %eax
    movl sym_off(,%eax,4), %eax
    ret
.Lsf_miss:
    popl %esi
    movl $-1, %eax
    ret

# ================= 词法 =================
next_token:
.Lnt_skip:
    movzbl (%esi), %eax
    testl %eax, %eax
    jz .Lnt_end
    cmpb $0x20, %al
    je .Lnt_adv
    cmpb $9, %al
    je .Lnt_adv
    cmpb $10, %al
    je .Lnt_adv
    cmpb $13, %al
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
    # 数字
    cmpb $'0', %al
    jb .Lnt_alpha
    cmpb $'9', %al
    jbe .Lnt_num
    jmp .Lnt_alpha
.Lnt_num:
    jmp .Lnt_num_parse
# 数字解析（复用 v0 逻辑）
.Lnt_num_parse:
    movl %esi, tok_start
    xorl %ecx, %ecx
    xorl %edi, %edi
    xorl %ebp, %ebp
.Lnn_loop:
    movzbl (%esi), %eax
    cmpb $'0', %al
    jb .Lnn_done
    cmpb $'9', %al
    ja .Lnn_done
    testl %ebp, %ebp
    jnz .Lnn_adv
    subb $'0', %al
    cmpl $214748364, %ecx
    jb .Lnn_mul
    je .Lnn_chk7
    jmp .Lnn_clamp
.Lnn_chk7:
    cmpl $7, %eax
    ja .Lnn_clamp
.Lnn_mul:
    imull $10, %ecx, %ecx
    addl %eax, %ecx
    jmp .Lnn_adv
.Lnn_clamp:
    movl $1, %ebp
.Lnn_adv:
    incl %esi
    incl %edi
    jmp .Lnn_loop
.Lnn_done:
    movl $TOK_NUM, tok_kind
    testl %ebp, %ebp
    jz .Lnn_store
    movl $2147483647, %ecx
.Lnn_store:
    movl %ecx, tok_ival
    movl %edi, tok_len
    ret
# 标识符 / 关键字
.Lnt_alpha:
    movzbl (%esi), %eax
    call is_alpha
    jnc .Lnt_nonid
    # IDENT
    movl %esi, tok_start
    xorl %edi, %edi
.Lna_loop:
    movzbl (%esi), %eax
    call is_alpha
    jc .Lna_idchr
    call is_digit
    jc .Lna_idchr
    jmp .Lna_done
.Lna_idchr:
    incl %esi
    incl %edi
    jmp .Lna_loop
.Lna_done:
    movl %edi, tok_len
    # 关键字 int：len==3 且 "int"
    cmpl $3, %edi
    jne .Lna_ident
    movl tok_start, %edx
    cmpb $'i', (%edx)
    jne .Lna_ident
    cmpb $'n', 1(%edx)
    jne .Lna_ident
    cmpb $'t', 2(%edx)
    jne .Lna_ident
    movl $TOK_INT, tok_kind
    ret
.Lna_ident:
    movl $TOK_IDENT, tok_kind
    ret
.Lnt_nonid:
    # 单字符符号
    movl %esi, tok_start
    movl $1, tok_len
    movzbl (%esi), %eax
    cmpb $'+', %al
    je .Lns_plus
    cmpb $'-', %al
    je .Lns_minus
    cmpb $'*', %al
    je .Lns_star
    cmpb $'/', %al
    je .Lns_slash
    cmpb $'(', %al
    je .Lns_lp
    cmpb $')', %al
    je .Lns_rp
    cmpb $'=', %al
    je .Lns_eq
    cmpb $';', %al
    je .Lns_semi
    cmpb $',', %al
    je .Lns_comma
    movl $1, %ebx               # 非法字符 → exit 1
    jmp err_msg
.Lns_plus:  movl $TOK_PLUS,   tok_kind; jmp .Lns_adv
.Lns_minus: movl $TOK_MINUS,  tok_kind; jmp .Lns_adv
.Lns_star:  movl $TOK_STAR,   tok_kind; jmp .Lns_adv
.Lns_slash: movl $TOK_SLASH,  tok_kind; jmp .Lns_adv
.Lns_lp:    movl $TOK_LPAREN, tok_kind; jmp .Lns_adv
.Lns_rp:    movl $TOK_RPAREN, tok_kind; jmp .Lns_adv
.Lns_eq:    movl $TOK_ASSIGN, tok_kind; jmp .Lns_adv
.Lns_semi:  movl $TOK_SEMI,   tok_kind; jmp .Lns_adv
.Lns_comma: movl $TOK_COMMA,  tok_kind; jmp .Lns_adv
.Lns_adv:
    incl %esi
    ret

# is_alpha: %al → CF=1 若 [a-zA-Z_]
is_alpha:
    cmpb $'a', %al
    jb .Lia1
    cmpb $'z', %al
    jbe .Lia_yes
.Lia1:
    cmpb $'A', %al
    jb .Lia_no
    cmpb $'Z', %al
    jbe .Lia_yes
.Lia_no:
    cmpb $'_', %al
    jne .Lia_ret
.Lia_yes:
    stc
    ret
.Lia_ret:
    clc
    ret

# is_digit: %al → CF=1 若 [0-9]
is_digit:
    cmpb $'0', %al
    jb .Lid_no
    cmpb $'9', %al
    ja .Lid_no
    stc
    ret
.Lid_no:
    clc
    ret

# ================= peek/restore（1-token 前瞻）=================
peek_token:
    movl tok_kind, %eax
    movl %eax, save_kind
    movl tok_ival, %eax
    movl %eax, save_ival
    movl tok_start, %eax
    movl %eax, save_start
    movl tok_len, %eax
    movl %eax, save_len
    movl %esi, save_cur
    call next_token
    ret
restore_token:
    movl save_kind, %eax
    movl %eax, tok_kind
    movl save_ival, %eax
    movl %eax, tok_ival
    movl save_start, %eax
    movl %eax, tok_start
    movl save_len, %eax
    movl %eax, tok_len
    movl save_cur, %esi
    ret

# ================= 代码生成助手 =================
emit_push_imm:
    leal s_push_pre, %ecx
    call app_str
    movl tok_ival, %eax
    call app_dec
    movl $10, %eax
    call app_char
    call emit_line
    ret

emit_stmt_end:
    leal s_stmt_end, %ecx
    call emit_template
    ret

emit_template:
    call app_str
    call emit_line
    ret

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

app_dec:
    call dec_to_str
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

app_char:
    movl out_len, %ecx
    leal out_line(%ecx), %edx
    movb %al, (%edx)
    incl %ecx
    movl %ecx, out_len
    ret

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
