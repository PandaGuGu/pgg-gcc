# pggcc3.s —— pggcc v3（P3 阶段）自研编译器本体（无蛋 stage-3）
#
# 职责：读入 stdin 程序文本（函数定义序列）→ 输出可独立运行的 i386 AT&T 汇编（.s），
#      入口固定 main：_start 调用 f_main 并打印其返回值（换行后 exit）。
#      构建链 as --32 + ld -m elf_i386（无 crt/libc），全程不调用任何 C/C++ 编译器。
#      本文件由 v2（pggcc2.s）扩展而来。
#
# 语言子集（plan §4.3，ISO/IEC 9899:1990 §6.1/§6.3/§6.6/§6.7）：
#   func   := 'int' IDENT '(' params ')' '{' stmt* '}'     // 允许递归
#   params := ε | IDENT (',' IDENT)*                       // 全 int，按值传递
#   stmt   := decl | assign ';' | expr ';' | 'return' expr ';'
#           | 'if' '(' expr ')' stmt ('else' stmt)?
#           | 'while' '(' expr ')' stmt
#           | 'for' '(' opt ';' opt ';' opt ')' stmt      // opt := ε | expr
#           | '{' stmt* '}'                               // 块（块作用域）
#   cmp    := expr (('=='|'!='|'<'|'<='|'>'|'>=') expr)*  // 置于 expr 最低优先级
#   call/decl/assign/expr/term/unary := 同 v2
# 语义：真值 0 假非 0 真；比较结果 int 0/1；整数截断除法/溢出不限（同前）；
#      cdecl 调用约定；函数作用域 + 嵌套块作用域（内层同名变量遮蔽外层，不同栈槽）；
#      入口函数固定 main（_start 打印其返回值）。
#
# 代码生成（复述）：
#   - _start: call f_main → print_decimal → 换行 → exit
#   - 函数：f_<name>: pushl %ebp; movl %esp,%ebp；尾声 movl %ebp,%esp; popl %ebp; ret
#   - 局部变量沿用 v1 机制：逐声明运行时 subl $4,%esp（第 l 个局部槽 -4(l+1)(%ebp)）
#   - 块作用域：``{`` 进入压作用域标记，出块时符号表弹回块基址；**出块发码
#     addl $4k,%esp 回收块内 k 个变量的栈空间**（否则循环体内块声明会每轮递增栈，
#     语义·栈平衡双错）——这是对 plan §4.3 的实现细化，日志会话 8 留痕
#   - 比较：popl %ecx; popl %eax; cmpl %ecx,%eax; setCC %al; movzbl %al,%eax; pushl %eax
#     （sete/setne/setl/setle/setg/setge 有符号，天然对齐 C 语义；不引入分支）
#   - 条件语句：值压栈 → popl %eax; testl %eax,%eax; jz Lxxx
#   - 标号：L%d 计数器 label_cnt（L 前缀大写字面，与运行时 .L 点号标号不冲突）
#
# 较 v2 的关键改造（日志会话 8 留痕）：
#   - 语句层重构：parse_func_body（特化循环）→ parse_stmt 统一分派
#     （decl/return/block/if/while/for/expr），函数体与块共用 parse_stmt_list
#   - 符号表支持块作用域：blk_mark[] 栈（每块保存基址 sym_count）+ scope_base；
#     出块恢复 sym_count（表弹回）；sym_find 改为**自末倒序扫描**（遮蔽=最近优先）；
#     declare_* 重名检查改用 sym_find_current（仅查 [scope_base, sym_count) 当前块，
#     允许遮蔽外层不与外层判重——对齐 C 语义）
#   - 表达式层：新增 parse_cmp 比较层（置于赋值之下、expr 之上）；条件/括号/实参
#     一律经 parse_assign（比较与赋值皆可进入）
#   - 词法：关键字 if/int/for/else/while/return（按长度分派）；多字符算子
#     == != < <= > >=（'='/'<'/'>' 后瞻一字符）
#   - 自证要点覆盖：if/else 双分支、while/for 计数、嵌套块遮蔽出块恢复、
#     比较返回 0/1（含作为普通表达式参与运算）、递归自证 fact(5)==120（B0 硬门槛）
#
# 编译器自身寄存器约定（同前，硬性）：
#   %esi=输入游标（所有内部 helper 自存自取）；%edi=%ebp=跨 call 安全临时；
#   app_* 助手破坏 %ecx/%edx（dec_to_str 还破坏 %ebx，跨 call 不得依赖 %ebx）；
#   递归重入的中间状态（标签基址等）一律压编译栈或存 edi/内存局部。

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
.equ TOK_RETURN, 13
.equ TOK_LBRACE, 14
.equ TOK_RBRACE, 15
.equ TOK_IF,     16
.equ TOK_ELSE,   17
.equ TOK_WHILE,  18
.equ TOK_FOR,    19
.equ TOK_EQ,     20
.equ TOK_NE,     21
.equ TOK_LT,     22
.equ TOK_LE,     23
.equ TOK_GT,     24
.equ TOK_GE,     25

.equ MAX_SYM,     32            # 每函数变量/参数总数上限（跨块累计）
.equ MAX_NAMELEN, 16            # 名长上限
.equ MAX_FUNC,    16            # 函数数上限
.equ MAX_BLK,     64            # 块嵌套深度上限

.section .rodata
msg_usage:  .asciz "error: usage: pggcc < program\n"
s_err_pre:  .asciz "error: "
s_space:    .asciz " "
s_nl:       .asciz "\n"
s_main_name:.asciz "main"

# ---- 生成程序（.s）固定文本模板 ----
s_head_start: .asciz ".section .text\n.globl _start\n_start:\n    call f_main\n"
s_main_epi:   .asciz "    call print_decimal\n    movl $10, %eax\n    call print_char\n    movl $1, %eax\n    xorl %ebx, %ebx\n    int $0x80\n"
s_push_pre:   .asciz "    pushl $"
op_add:     .asciz "    popl %ecx\n    popl %eax\n    addl %ecx, %eax\n    pushl %eax\n"
op_sub:     .asciz "    popl %ecx\n    popl %eax\n    subl %ecx, %eax\n    pushl %eax\n"
op_mul:     .asciz "    popl %ecx\n    popl %eax\n    imull %ecx, %eax\n    pushl %eax\n"
op_div:     .asciz "    popl %ecx\n    popl %eax\n    cltd\n    idivl %ecx\n    pushl %eax\n"
unary_neg:  .asciz "    popl %eax\n    negl %eax\n    pushl %eax\n"
decl_alloc: .asciz "    subl $4, %esp\n"
s_dealloc:  .asciz "    addl $"          # +4k+ s_dealloc2（块出栈回收）
s_dealloc2: .asciz ", %esp\n"
s_vread1:   .asciz "    movl "                    # +signed_off+ "(%ebp), %eax\n    pushl %eax\n"
s_vread2:   .asciz "(%ebp), %eax\n    pushl %eax\n"
s_bind1:    .asciz "    popl %eax\n    movl %eax, "  # +signed_off+ "(%ebp)\n    pushl %eax\n"
s_bind2:    .asciz "(%ebp)\n    pushl %eax\n"
s_stmt_end: .asciz "    popl %eax\n"
s_ret_seq:  .asciz "    popl %eax\n    movl %ebp, %esp\n    popl %ebp\n    ret\n"
s_func_epi: .asciz "    movl %ebp, %esp\n    popl %ebp\n    ret\n"
s_flabel1:  .asciz "f_"                          # +name+ ":\n    pushl %ebp\n    movl %esp, %ebp\n"
s_flabel2:  .asciz ":\n    pushl %ebp\n    movl %esp, %ebp\n"
s_call1:    .asciz "    call f_"                 # +name+ "\n"
s_call3:    .asciz "    addl $"                  # +4n+
s_call4:    .asciz ", %esp\n    pushl %eax\n"
# v3 控制流模板
s_cnd_test: .asciz "    popl %eax\n    testl %eax, %eax\n"
s_jz_pre:   .asciz "    jz L"
s_jmp_pre:  .asciz "    jmp L"
s_lab_pre:  .asciz "L"
cmp_eq:     .asciz "    popl %ecx\n    popl %eax\n    cmpl %ecx, %eax\n    sete %al\n    movzbl %al, %eax\n    pushl %eax\n"
cmp_ne:     .asciz "    popl %ecx\n    popl %eax\n    cmpl %ecx, %eax\n    setne %al\n    movzbl %al, %eax\n    pushl %eax\n"
cmp_lt:     .asciz "    popl %ecx\n    popl %eax\n    cmpl %ecx, %eax\n    setl %al\n    movzbl %al, %eax\n    pushl %eax\n"
cmp_le:     .asciz "    popl %ecx\n    popl %eax\n    cmpl %ecx, %eax\n    setle %al\n    movzbl %al, %eax\n    pushl %eax\n"
cmp_gt:     .asciz "    popl %ecx\n    popl %eax\n    cmpl %ecx, %eax\n    setg %al\n    movzbl %al, %eax\n    pushl %eax\n"
cmp_ge:     .asciz "    popl %ecx\n    popl %eax\n    cmpl %ecx, %eax\n    setge %al\n    movzbl %al, %eax\n    pushl %eax\n"
# 生成程序运行时助手 + .bss（同 v0/v1/v2）
s_runtime:  .asciz "print_decimal:\n    pushl %ebx\n    pushl %ecx\n    pushl %edx\n    pushl %esi\n    pushl %edi\n    test %eax, %eax\n    jns .Lpd_pos\n    movl %eax, %esi\n    movl $'-', %eax\n    call print_char\n    movl %esi, %eax\n    negl %eax\n.Lpd_pos:\n    movl %eax, %edi\n    leal runt_buf+15, %esi\n    movb $0, (%esi)\n.Lpd_loop:\n    movl %edi, %eax\n    xorl %edx, %edx\n    movl $10, %ebx\n    divl %ebx\n    movl %eax, %edi\n    addb $'0', %dl\n    decl %esi\n    movb %dl, (%esi)\n    test %edi, %edi\n    jnz .Lpd_loop\n    movl $4, %eax\n    movl $1, %ebx\n    movl %esi, %ecx\n    leal runt_buf+15, %edx\n    subl %esi, %edx\n    int $0x80\n    popl %edi\n    popl %esi\n    popl %edx\n    popl %ecx\n    popl %ebx\n    ret\n\nprint_char:\n    pushl %eax\n    pushl %ebx\n    pushl %ecx\n    pushl %edx\n    leal runt_cbuf, %ecx\n    movb %al, (%ecx)\n    movl $1, %edx\n    movl $1, %ebx\n    movl $4, %eax\n    int $0x80\n    popl %edx\n    popl %ecx\n    popl %ebx\n    popl %eax\n    ret\n\n.section .bss\nrunt_buf:  .space 16\nrunt_cbuf: .space 1\n"

# ---- 编译器自身工作内存（.bss） ----
.section .bss
in_buf:      .space 4097
input_start: .long 0
tok_kind:    .long 0
tok_ival:    .long 0
tok_start:   .long 0
tok_len:     .long 0
sym_name:    .space MAX_SYM*MAX_NAMELEN
sym_off:     .space MAX_SYM*4
sym_count:   .long 0
fn_nparams:  .long 0          # 当前函数参数个数（局部槽偏移基数）
func_name:   .space MAX_FUNC*MAX_NAMELEN
func_count:  .long 0
scratch_name:.space MAX_NAMELEN+1
pk_depth:    .long 0          # peek 备份深度（内存栈）
pk_kind:     .space 8*4
pk_ival:     .space 8*4
pk_start:    .space 8*4
pk_len:      .space 8*4
pk_cur:      .space 8*4
blk_mark:    .space MAX_BLK*4  # 块作用域标记栈：blk_mark[d]=第 d+1 层块基址(sym_count)
blk_depth:   .long 0          # 当前嵌套块数（0=函数体顶层作用域）
scope_base:  .long 0          # 当前块基址（重名检查下限；0=函数作用域）
label_cnt:   .long 0          # 生成程序标号计数器（L%d）
out_len:     .long 0
out_line:    .space 128
dec_buf:     .space 16
arg_count:   .long 0      # 调用实参扫描计数（回放期已压栈保存，防嵌套覆盖）
scan_depth:  .long 0      # 实参扫描括号深度（内存槽，扫描期无嵌套）
scan_idx:    .long 0      # 实参起点数组游标（扫描期用）
scan_end:    .long 0      # 顶层 ')' 位置（调用收尾重置游标用）
arg_pos:     .space 16*4  # 实参起点数组（≤16 实参；扫描期写入，回放期读取）

.section .text
.globl _start
_start:
    # 读入 stdin
    movl $3, %eax
    xorl %ebx, %ebx
    leal in_buf, %ecx
    movl $4096, %edx
    int $0x80
    testl %eax, %eax
    js .Lrd_bad
    jmp .Lrd_ok
.Lrd_bad:
    xorl %eax, %eax
.Lrd_ok:
    leal in_buf, %esi
    movl %esi, input_start
    movb $0, in_buf(%eax)
    # 输出生成程序头部：_start 调用 f_main + 打印返回值
    leal s_head_start, %ecx
    call emit_template
    leal s_main_epi, %ecx
    call emit_template
    call next_token
    call parse_top            # func*
    # 检查入口 main 存在
    call func_has_main
    testl %eax, %eax
    jz Lsyn_err               # 缺 main → exit 2
    leal s_runtime, %ecx
    call emit_template
    xorl %ebx, %ebx
    movl $1, %eax
    int $0x80

Lsyn_err:
    movl $2, %ebx
    jmp err_msg

# ---- 通用错误输出：stderr "error: <位置> <token>\n"，按 %ebx 退出 ----
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

# ================= 程序结构：func* =================
parse_top:
.pt_top:
    movl tok_kind, %eax
    cmpl $TOK_END, %eax
    je .Lpt_done
    cmpl $TOK_INT, %eax
    je .Lpt_func
    jmp Lsyn_err              # 顶层只允许函数定义
.Lpt_func:
    call parse_func           # 必须 call（parse_func 尾部 ret 回到这里继续循环）
    jmp .pt_top
.Lpt_done:
    ret

# ================= 函数定义 =================
# parse_func: 当前 token = TOK_INT；'int' IDENT '(' params ')' '{' stmt* '}'
#   函数体顶层 `{` 不建块标记（函数作用域：参数与函数体首层声明同域，C 语义）
parse_func:
    call next_token           # → 函数名 IDENT
    movl tok_kind, %eax
    cmpl $TOK_IDENT, %eax
    jne Lsyn_err
    call copy_name            # scratch_name = 函数名
    call func_find
    cmpl $-1, %eax
    jne Lsyn_err              # 函数重复定义
    call func_add             # 登记函数；表满 → Lsyn_err
    # 发码标号 + 序言
    leal s_flabel1, %ecx
    call app_str
    leal scratch_name, %ecx
    call app_str
    leal s_flabel2, %ecx
    call app_str
    call emit_line
    # 函数上下文：变量表重置、参数计数清零、作用域清零
    movl $0, sym_count
    movl $0, fn_nparams
    movl $0, blk_depth
    movl $0, scope_base
    call next_token           # → '('
    movl tok_kind, %eax
    cmpl $TOK_LPAREN, %eax
    jne Lsyn_err
    call next_token
    movl tok_kind, %eax
    cmpl $TOK_RPAREN, %eax
    je .Lpf_after_params
.Lpf_param_loop:
    # 参数声明（当前可为 'int' 类型说明符（可选）或直接 IDENT）
    movl tok_kind, %eax
    cmpl $TOK_INT, %eax
    jne .Lpfp_noint
    call next_token
.Lpfp_noint:
    movl tok_kind, %eax
    cmpl $TOK_IDENT, %eax
    jne Lsyn_err
    call declare_param        # 查重 + 登记（off=8+4k）+ 参数计数
    call next_token
    movl tok_kind, %eax
    cmpl $TOK_COMMA, %eax
    je .Lpf_param_comma
    cmpl $TOK_RPAREN, %eax
    jne Lsyn_err
    jmp .Lpf_after_params
.Lpf_param_comma:
    call next_token
    jmp .Lpf_param_loop
.Lpf_after_params:
    call next_token           # → '{'
    movl tok_kind, %eax
    cmpl $TOK_LBRACE, %eax
    jne Lsyn_err
    call next_token
    call parse_stmt_list      # stmt* 至 '}'（当前 = '}'）
    movl tok_kind, %eax
    cmpl $TOK_RBRACE, %eax
    jne Lsyn_err
    call next_token
    # 函数尾声
    leal s_func_epi, %ecx
    call emit_template
    ret

# ================= 语句列表 / 语句分派 =================
# parse_stmt_list: 循环 parse_stmt 至 TOK_RBRACE（不消费 '}'）
parse_stmt_list:
.Lpsl_top:
    movl tok_kind, %eax
    cmpl $TOK_RBRACE, %eax
    je .Lpsl_done
    call parse_stmt
    jmp .Lpsl_top
.Lpsl_done:
    ret

# parse_stmt: 当前 token 为语句首 token；返回时 token 为语句后的第一个 token
parse_stmt:
    movl tok_kind, %eax
    cmpl $TOK_INT, %eax
    je parse_decl
    cmpl $TOK_RETURN, %eax
    je .Lpst_ret
    cmpl $TOK_LBRACE, %eax
    je parse_block
    cmpl $TOK_IF, %eax
    je parse_if
    cmpl $TOK_WHILE, %eax
    je parse_while
    cmpl $TOK_FOR, %eax
    je parse_for
    # 表达式 / 赋值语句
    call parse_assign
    movl tok_kind, %eax
    cmpl $TOK_SEMI, %eax
    jne Lsyn_err
    call next_token
    leal s_stmt_end, %ecx
    call emit_template
    ret
.Lpst_ret:
    call next_token            # → expr
    call parse_assign          # 值压栈（允许 return a==3; 等）
    movl tok_kind, %eax
    cmpl $TOK_SEMI, %eax
    jne Lsyn_err
    call next_token
    leal s_ret_seq, %ecx
    call emit_template         # popl %eax + 尾声
    ret

# ================= 声明（函数内，用法同 v2） =================
parse_decl:
    call next_token
    jmp .Lpd_ident
.Lpd_ident:
    movl tok_kind, %eax
    cmpl $TOK_IDENT, %eax
    jne Lsyn_err
    call declare_local         # 局部声明：符号表 + subl 发码
    call next_token
    movl tok_kind, %eax
    cmpl $TOK_COMMA, %eax
    je .Lpd_comma
    cmpl $TOK_SEMI, %eax
    jne Lsyn_err
    call next_token
    ret
.Lpd_comma:
    call next_token
    jmp .Lpd_ident

# ================= 块语句（块作用域） =================
# parse_block: 当前 token = '{'；进块压作用域标记，出块符号表弹回 + 栈空间回收
parse_block:
    # 进块：blk_mark[blk_depth] = 当前 sym_count（本块基址）；scope_base 随之更新
    movl blk_depth, %ecx
    cmpl $MAX_BLK, %ecx
    jge Lsyn_err               # 嵌套过深
    movl sym_count, %eax
    movl %eax, blk_mark(,%ecx,4)
    incl blk_depth
    movl %eax, scope_base
    call next_token
    call parse_stmt_list
    movl tok_kind, %eax
    cmpl $TOK_RBRACE, %eax
    jne Lsyn_err
    # 出块前：运行时回收本块声明 k 个变量的栈空间（k = sym_count - scope_base）
    #   循环体内块声明若只靠符号表弹回，会每轮 subl 递增运行时栈 → 语义/栈双错；
    #   出块 addl $4k,%esp 使块栈每轮平衡（细则 §4.3 实现细化，日志会话 8 留痕）
    movl sym_count, %edi
    subl scope_base, %edi
    testl %edi, %edi
    jz .Lpb_noalloc
    leal s_dealloc, %ecx
    call app_str
    movl %edi, %eax
    shll $2, %eax
    call app_dec
    leal s_dealloc2, %ecx
    call app_str
    call emit_line
.Lpb_noalloc:
    # 出块：符号表弹回块基址；scope_base 恢复为外层（0 或无块层）
    decl blk_depth
    movl blk_depth, %ecx
    movl blk_mark(,%ecx,4), %eax
    movl %eax, sym_count
    testl %ecx, %ecx
    jz .Lpb_base0
    movl %ecx, %eax
    decl %eax
    movl blk_mark(,%eax,4), %eax  # 外层块基址 = blk_mark[深度-1]
    movl %eax, scope_base
    jmp .Lpb_after
.Lpb_base0:
    movl $0, scope_base
.Lpb_after:
    call next_token           # 消费 '}'
    ret

# ================= if 语句 =================
# parse_if: 'if' '(' cond ')' stmt ('else' stmt)?  真值：0 假、非 0 真
#   代码形态：cond 推值 → popl/testl/jz LF → then → jmp LE → LF: else → LE:
parse_if:
    call next_token           # → '('
    movl tok_kind, %eax
    cmpl $TOK_LPAREN, %eax
    jne Lsyn_err
    call next_token
    call parse_assign          # 条件（值压栈）
    movl tok_kind, %eax
    cmpl $TOK_RPAREN, %eax
    jne Lsyn_err
    call next_token
    # 标号：LF = label_cnt，LE = label_cnt+1（编译栈保存 LF，跨嵌套安全）
    movl label_cnt, %eax
    pushl %eax
    addl $2, label_cnt
    leal s_cnd_test, %ecx
    call emit_template
    movl 0(%esp), %eax         # LF
    call emit_jz
    call parse_stmt            # then 分支
    movl tok_kind, %eax
    cmpl $TOK_ELSE, %eax
    je .Lpi_else
    movl 0(%esp), %eax         # 无 else：LF = 跳过 then 后直接落点
    call emit_label
    popl %eax
    ret
.Lpi_else:
    movl 0(%esp), %eax
    addl $1, %eax              # 跳过 else 用 LE 作无条件跳
    call emit_jmp
    movl 0(%esp), %eax         # LF: else 分支入口
    call emit_label
    call next_token            # 消费 'else'
    call parse_stmt            # else 分支
    movl 0(%esp), %eax
    addl $1, %eax              # LE:
    call emit_label
    popl %eax
    ret

# ================= while 语句 =================
# parse_if: 'while' '(' cond ')' stmt
#   代码形态：LW: cond → jz LE → body → jmp LW → LE:
parse_while:
    call next_token
    movl tok_kind, %eax
    cmpl $TOK_LPAREN, %eax
    jne Lsyn_err
    movl label_cnt, %eax
    pushl %eax                 # 栈保 LW
    addl $2, label_cnt
    movl 0(%esp), %eax         # LW:
    call emit_label
    call next_token
    call parse_assign          # cond
    movl tok_kind, %eax
    cmpl $TOK_RPAREN, %eax
    jne Lsyn_err
    call next_token
    leal s_cnd_test, %ecx
    call emit_template
    movl 0(%esp), %eax
    addl $1, %eax              # LE
    call emit_jz
    call parse_stmt            # body
    movl 0(%esp), %eax         # jmp LW
    call emit_jmp
    movl 0(%esp), %eax
    addl $1, %eax              # LE:
    call emit_label
    popl %eax
    ret

# ================= for 语句 =================
# parse_for: 'for' '(' opt ';' opt ';' opt ')' stmt   opt := ε | expr
#   代码形态：init → LB: cond(→jz LE) → body → LI: inc → jmp LB → LE:
#   inc 的源码位于 body 之前，但代码须排在 body 之后 → 沿用 v2 实参
#   "扫描+回放"模式：解析至 inc 段时记录 inc 起点、扫描跳过至顶层 ')'，
#   先解析 body，在 LI 处回放 inc（重置游标重解析发码），再恢复 body 后 token。
#   空 inc 时当前 token 即 ')'，扫描立即命中，inc_start==rparen 判空。
#   编译栈布局：[..][LB][inc_start][rparen_pos]（LB 在 8(%esp)）。
parse_for:
    call next_token
    movl tok_kind, %eax
    cmpl $TOK_LPAREN, %eax
    jne Lsyn_err
    movl label_cnt, %eax
    pushl %eax                 # 栈保 LB（LE=LB+2，LI=LB+1）
    addl $3, label_cnt
    call next_token
    # ---- init（以 ';' 结束）----
    movl tok_kind, %eax
    cmpl $TOK_SEMI, %eax
    je .Lpfo_init_empty
    call parse_assign
    movl tok_kind, %eax
    cmpl $TOK_SEMI, %eax
    jne Lsyn_err
    call next_token
    leal s_stmt_end, %ecx
    call emit_template
    jmp .Lpfo_cond
.Lpfo_init_empty:
    call next_token
    # ---- cond（以 ';' 结束）----
.Lpfo_cond:
    movl 0(%esp), %eax         # LB:
    call emit_label
    movl tok_kind, %eax
    cmpl $TOK_SEMI, %eax
    je .Lpfo_cond_empty
    call parse_assign
    movl tok_kind, %eax
    cmpl $TOK_SEMI, %eax
    jne Lsyn_err
    call next_token            # → inc 首 token
    leal s_cnd_test, %ecx
    call emit_template
    movl 0(%esp), %eax
    addl $2, %eax              # jz LE
    call emit_jz
    jmp .Lpfo_inc              # 非空 cond 已消费完，不得落入空分支的 next_token
.Lpfo_cond_empty:              # 空条件 = 恒真（for(;;) 无限循环）
    call next_token            # 消费 ';' → inc 首 token（即 ')'）
    # ---- inc：记录起点 → 扫描跳过至顶层 ')'（body 后回放发码）----
.Lpfo_inc:
    movl tok_start, %eax
    pushl %eax                 # 栈：[..][LB][inc_start]
    movl $0, scan_depth
    movl tok_start, %esi
.Lpfo_scan:
    movzbl (%esi), %eax
    testl %eax, %eax
    jz Lsyn_err
    cmpb $'(', %al
    jne .Lpfo_sc1
    incl scan_depth
    jmp .Lpfo_sc_adv
.Lpfo_sc1:
    cmpb $')', %al
    jne .Lpfo_sc2
    movl scan_depth, %eax
    testl %eax, %eax
    jnz .Lpfo_sc_deep
    movl %esi, %eax
    pushl %eax                 # 栈：[..][LB][inc_start][rparen_pos]
    jmp .Lpfo_sc_done
.Lpfo_sc_deep:
    decl scan_depth
    jmp .Lpfo_sc_adv
.Lpfo_sc2:
    cmpb $',', %al
    jne .Lpfo_sc_adv
.Lpfo_sc_adv:
    incl %esi
    jmp .Lpfo_scan
.Lpfo_sc_done:
    # 定 body 首 token：游标 → ')' 之后
    movl 0(%esp), %eax
    leal 1(%eax), %esi
    call next_token
    # ---- body ----
.Lpfo_body:
    call parse_stmt
    # 保存 body 后 token 状态（peek 深栈；回放 inc 会推进游标并打乱 token）
    call peek_token
    movl 8(%esp), %eax         # LB
    addl $1, %eax
    call emit_label            # LI:
    # ---- inc 回放（重置游标重解析并发码；空 inc 跳过）----
    movl 4(%esp), %eax         # inc_start
    cmpl 0(%esp), %eax         # inc_start == rparen_pos → 空 inc
    je .Lpfo_inc_skip
    movl %eax, %esi
    call next_token
    call parse_assign
    movl tok_kind, %eax
    cmpl $TOK_RPAREN, %eax
    jne Lsyn_err               # inc 表达式须以顶层 ')' 结束
    leal s_stmt_end, %ecx
    call emit_template         # 丢弃 inc 值
.Lpfo_inc_skip:
    call restore_token         # 恢复 body 后 token 状态（不得从 rparen+1 重读！）
    # ---- 收尾：jmp LB / LE: ----
    movl 8(%esp), %eax         # jmp LB
    call emit_jmp
    movl 8(%esp), %eax
    addl $2, %eax              # LE:
    call emit_label
    addl $12, %esp             # 弹 [LB][inc_start][rparen]
    ret

# ================= 赋值 / 表达式（v2 + 比较层） =================
parse_assign:
    movl tok_kind, %eax
    cmpl $TOK_IDENT, %eax
    jne parse_cmp
    call peek_token
    movl tok_kind, %eax
    cmpl $TOK_ASSIGN, %eax
    je .Lpa_bind
    call restore_token
    jmp parse_cmp
.Lpa_bind:
    call restore_token
    call lookup_var
    pushl %eax                 # 本层目标槽偏移压栈（右值递归重入保护）
    call next_token
    movl tok_kind, %eax
    cmpl $TOK_ASSIGN, %eax
    jne Lsyn_err
    call next_token
    call parse_assign
    popl %edi
    leal s_bind1, %ecx
    call app_str
    movl %edi, %eax
    call app_dec_signed
    leal s_bind2, %ecx
    call app_str
    call emit_line
    ret

# ================= 比较（置于表达式最低优先级层，左结合） =================
# cmp := expr (('=='|'!='|'<'|'<='|'>'|'>=') expr)*   结果 int 0/1
# 发码：pop ecx(右); pop eax(左); cmpl ecx,eax; setCC al; movzbl → push（无分支）
parse_cmp:
    call parse_expr
.Lpcmp_top:
    movl tok_kind, %eax
    cmpl $TOK_EQ, %eax
    je .Lpcmp_op
    cmpl $TOK_NE, %eax
    je .Lpcmp_op
    cmpl $TOK_LT, %eax
    je .Lpcmp_op
    cmpl $TOK_LE, %eax
    je .Lpcmp_op
    cmpl $TOK_GT, %eax
    je .Lpcmp_op
    cmpl $TOK_GE, %eax
    je .Lpcmp_op
    ret
.Lpcmp_op:
    movl tok_kind, %eax
    pushl %eax                 # 算子压栈（重入保护，同 v2 pending_op 教训）
    call next_token
    call parse_expr
    popl %eax
    cmpl $TOK_EQ, %eax
    jne .Lpcmp_ne
    leal cmp_eq, %ecx
    jmp .Lpcmp_emit
.Lpcmp_ne:
    cmpl $TOK_NE, %eax
    jne .Lpcmp_lt
    leal cmp_ne, %ecx
    jmp .Lpcmp_emit
.Lpcmp_lt:
    cmpl $TOK_LT, %eax
    jne .Lpcmp_le
    leal cmp_lt, %ecx
    jmp .Lpcmp_emit
.Lpcmp_le:
    cmpl $TOK_LE, %eax
    jne .Lpcmp_gt
    leal cmp_le, %ecx
    jmp .Lpcmp_emit
.Lpcmp_gt:
    cmpl $TOK_GT, %eax
    jne .Lpcmp_ge
    leal cmp_gt, %ecx
    jmp .Lpcmp_emit
.Lpcmp_ge:
    leal cmp_ge, %ecx
.Lpcmp_emit:
    call emit_template
    jmp .Lpcmp_top

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

# ================= primary =================
# primary := NUM | IDENT | IDENT '(' args ')' | '(' assign-expr ')'
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
    call copy_name             # scratch_name = 标识符（可能是函数名）
    call peek_token
    movl tok_kind, %eax
    cmpl $TOK_LPAREN, %eax
    je .Lpp_call
    call restore_token
    # 变量读取（查变量表）
    call lookup_var
    movl %eax, %edi
    leal s_vread1, %ecx
    call app_str
    movl %edi, %eax
    call app_dec_signed
    leal s_vread2, %ecx
    call app_str
    call emit_line
    call next_token
    ret
.Lpp_call:
    call commit_peek           # 当前 token = '('；函数名已存 scratch_name
    call func_find
    cmpl $-1, %eax
    je Lsyn_err                # 未定义函数 → exit 2
    # 压栈保存函数名 16 字节（实参解析可能嵌套调用覆盖 scratch_name）
    leal scratch_name, %edx
    xorl %ecx, %ecx
.Lpc_save:
    cmpl $4, %ecx
    jge .Lpc_saved
    movl (%edx,%ecx,4), %eax
    pushl %eax
    incl %ecx
    jmp .Lpc_save
.Lpc_saved:
    # ---- 阶段1：扫描实参边界（'(' 后，按顶层逗号分隔）----
    # 当前 token='('（游标在 '(' 之后）；先读下一个 token 判断空参
    call next_token            # tok = ')'（空参）或第一实参首 token
    movl tok_kind, %eax
    cmpl $TOK_RPAREN, %eax
    je .Lpc_zero
    # 非空：扫描从第一实参起点（tok_start）前进，把各实参起点记入 arg_pos[]
    movl $0, arg_count
    movl $0, scan_depth         # 括号深度（内存槽；扫描期无嵌套，安全）
    movl $0, scan_idx
    movl tok_start, %esi
    movl %esi, %eax
    leal arg_pos, %edx
    movl %eax, (%edx)          # arg_pos[0] = 实参1 起点
    incl arg_count
    incl scan_idx
.Lpc_scan_loop:
    movzbl (%esi), %eax
    testl %eax, %eax
    jz Lsyn_err                # 文本意外结束（缺 ')'）
    cmpb $'(', %al
    jne .Lpc_sc1
    incl scan_depth
    jmp .Lpc_sc_adv
.Lpc_sc1:
    cmpb $')', %al
    jne .Lpc_sc2
    movl scan_depth, %eax
    testl %eax, %eax
    jnz .Lpc_sc_deep
    movl %esi, scan_end         # 记录顶层 ')' 位置（收尾用）
    jmp .Lpc_sc_done           # 顶层 ')' 结束本调用实参区
.Lpc_sc_deep:
    decl scan_depth
    jmp .Lpc_sc_adv
.Lpc_sc2:
    cmpb $',', %al
    jne .Lpc_sc_adv
    movl scan_depth, %eax
    testl %eax, %eax
    jnz .Lpc_sc_adv            # 括号内的 ',' 不切分实参
    # 顶层 ','：下一实参起点 = esi+1 → arg_pos[scan_idx]
    leal 1(%esi), %eax
    leal arg_pos, %edx
    movl scan_idx, %ecx
    movl %eax, (%edx,%ecx,4)
    incl scan_idx
    incl arg_count
    jmp .Lpc_sc_adv
.Lpc_sc_adv:
    incl %esi
    jmp .Lpc_scan_loop
.Lpc_sc_done:
    # ---- 阶段2：从右到左解析实参（cdecl：最后解析的最先压栈）----
    # 构造不可变调用栈（自底向上）：[fn名][scan_end][N保留][SENT=-1][实参1..N 起点]
    # 栈顶=实参N 起点（源码最右）→ 循环 pop 即从右到左；SENT 判界（起点必非 -1）；
    # 嵌套调用（实参内）只在本层栈区之上 push/pop，本层栈序不被打乱——免疫嵌套覆盖；
    # 发码所需 N 与 scan_end 在完成时自栈弹回（此时嵌套已结束）。
    pushl scan_end            # 保留 scan_end（mem 压栈）
    movl arg_count, %eax
    pushl %eax                # N 保留（供 addl 发码）
    movl $-1, %eax
    pushl %eax                # SENTINEL
    xorl %ecx, %ecx           # 起点索引 i=0..N-1
.Lpc_ps:                      # 起点 1..N 入栈（i 递增 → 实参N 最后压、位于栈顶）
    cmpl arg_count, %ecx
    jge .Lpc_ps_done
    leal arg_pos, %edx
    movl (%edx,%ecx,4), %eax
    pushl %eax
    incl %ecx
    jmp .Lpc_ps
.Lpc_ps_done:
.Lpc_rev:
    movl 0(%esp), %eax
    cmpl $-1, %eax            # SENTINEL？
    je .Lpc_rev_done
    popl %esi
    call next_token           # 重建该实参首个 token
    call parse_assign         # 完整解析+发码（比较/赋值皆可——经 parse_assign）
    jmp .Lpc_rev
.Lpc_rev_done:
    popl %eax                 # 弹 SENTINEL
    popl %ebp                 # 弹 N 保留 → %ebp = 实参数（跨嵌套安全）
    popl %eax                 # 弹 scan_end 并写回（收尾重置游标用；此后无嵌套）
    movl %eax, scan_end
    jmp .Lpc_emit
.Lpc_zero:
    xorl %ebp, %ebp           # 空参：N=0；'(' 已被 next_token 消费
.Lpc_emit:
    # 弹回函数名（4 dword 回 scratch_name）
    movl $3, %edi
.Lpc_load:
    popl %eax
    leal scratch_name, %edx
    movl %eax, (%edx,%edi,4)
    decl %edi
    jns .Lpc_load
    # %ebp = 实参数（已在 .Lpc_rev 末尾 popl %ebp 或 .Lpc_zero 置 0）
    # 发码 call f_<name>
    leal s_call1, %ecx
    call app_str
    leal scratch_name, %ecx
    call app_str
    leal s_nl, %ecx
    call app_str
    call emit_line
    # addl $4n,%esp + pushl %eax
    leal s_call3, %ecx
    call app_str
    movl %ebp, %eax
    shll $2, %eax
    call app_dec
    leal s_call4, %ecx
    call app_str
    call emit_line
    # 收尾 token：回放（重设游标解析各实参）会打乱输入游标；此处显式把游标
    # 定位到顶层 ')' 之后并读取下一个 token（空参时 ')' 已是当前 token，直接读其后）
    cmpl $0, %ebp
    jne .Lpc_tail_scan
    call next_token
    jmp .Lpc_tail_done
.Lpc_tail_scan:
    movl scan_end, %esi
    incl %esi
    call next_token
.Lpc_tail_done:
    ret

.Lpp_lp:
    call next_token
    call parse_assign          # 括号内完整赋值/比较表达式
    movl tok_kind, %eax
    cmpl $TOK_RPAREN, %eax
    jne Lsyn_err
    call next_token
    ret

# ================= 符号表：变量（函数作用域 + 块作用域遮蔽） =================
# lookup_var: 当前 token=IDENT → 槽偏移/%eax；未声明 → Lsyn_err
lookup_var:
    call copy_name
    call sym_find
    cmpl $-1, %eax
    je Lsyn_err
    ret

# declare_param: 当前 token=IDENT，按参数登记（当前块[=函数作用域]重名检查）
declare_param:
    call copy_name
    call sym_find_current
    cmpl $-1, %eax
    jne Lsyn_err
    movl sym_count, %ecx
    cmpl $MAX_SYM, %ecx
    jge Lsyn_err
    leal 8(,%ecx,4), %eax      # off = 8 + 4k（第一个参数 8(%ebp)）
    movl %eax, sym_off(,%ecx,4)
    call sym_add_name          # 复制 scratch → 表 + 计数+1
    incl fn_nparams
    ret

# declare_local: 当前 token=IDENT，按局部登记（当前块重名检查）＋发码 subl
declare_local:
    call copy_name
    call sym_find_current
    cmpl $-1, %eax
    jne Lsyn_err
    movl sym_count, %ecx
    cmpl $MAX_SYM, %ecx
    jge Lsyn_err
    # 局部序号 = count - nparams；off = -4*(局部序号+1)
    movl %ecx, %eax
    subl fn_nparams, %eax
    leal 1(%eax), %eax
    shll $2, %eax
    negl %eax
    movl %eax, sym_off(,%ecx,4)
    call sym_add_name
    leal decl_alloc, %ecx
    call emit_template
    ret

# sym_add_name: 把 scratch_name 复制到 sym_name[sym_count*16]，sym_count++
#   各声明入口已校验 sym_count < MAX_SYM
sym_add_name:
    pushl %esi
    movl sym_count, %edi
    shll $4, %edi
    leal sym_name(%edi), %edi
    leal scratch_name, %esi
    xorl %edx, %edx
.Lsan_copy:
    cmpl $MAX_NAMELEN, %edx
    jge .Lsan_done
    movb (%esi,%edx), %al
    testb %al, %al
    jz .Lsan_end
    movb %al, (%edi,%edx)
    incl %edx
    jmp .Lsan_copy
.Lsan_end:
    movb $0, (%edi,%edx)
.Lsan_done:
    incl sym_count
    popl %esi
    ret

# ================= 符号表：函数（同 v2） =================
# func_find: 查 scratch_name 于函数表 → %eax = 索引 / -1
func_find:
    pushl %esi
    movl $0, %edi
.Lff_test:
    cmpl func_count, %edi
    jge .Lff_miss
    movl %edi, %ecx
    shll $4, %ecx
    leal func_name(%ecx), %esi
    leal scratch_name, %edx
    xorl %eax, %eax
.Lff_cmp:
    movb (%eax,%esi), %cl
    movb (%eax,%edx), %ch
    cmpb %ch, %cl
    jne .Lff_next
    testb %ch, %ch
    jz .Lff_hit
    incl %eax
    cmpl $MAX_NAMELEN, %eax
    jb .Lff_cmp
    jmp .Lff_hit
.Lff_next:
    incl %edi
    jmp .Lff_test
.Lff_hit:
    popl %esi
    movl %edi, %eax
    ret
.Lff_miss:
    popl %esi
    movl $-1, %eax
    ret

# func_add: 登记 scratch_name 到函数表末尾；表满 → Lsyn_err
func_add:
    pushl %esi
    movl func_count, %ecx
    cmpl $MAX_FUNC, %ecx
    jge .Lfa_full
    movl %ecx, %edi
    shll $4, %edi
    leal func_name(%edi), %edi
    leal scratch_name, %esi
    xorl %edx, %edx
.Lfa_copy:
    cmpl $MAX_NAMELEN, %edx
    jge .Lfa_done
    movb (%esi,%edx), %al
    testb %al, %al
    jz .Lfa_end
    movb %al, (%edi,%edx)
    incl %edx
    jmp .Lfa_copy
.Lfa_end:
    movb $0, (%edi,%edx)
.Lfa_done:
    incl func_count
    popl %esi
    ret
.Lfa_full:
    popl %esi
    jmp Lsyn_err

# func_has_main: 函数表是否含 "main" → %eax = 1/0
func_has_main:
    pushl %esi
    movl $0, %edi
.Lhm_test:
    cmpl func_count, %edi
    jge .Lhm_no
    movl %edi, %ecx
    shll $4, %ecx
    leal func_name(%ecx), %esi
    leal s_main_name, %edx
    xorl %eax, %eax
.Lhm_cmp:
    movb (%eax,%esi), %cl
    movb (%eax,%edx), %ch
    cmpb %ch, %cl
    jne .Lhm_next
    testb %ch, %ch
    jz .Lhm_yes
    incl %eax
    cmpl $MAX_NAMELEN, %eax
    jb .Lhm_cmp
    jmp .Lhm_yes
.Lhm_next:
    incl %edi
    jmp .Lhm_test
.Lhm_yes:
    popl %esi
    movl $1, %eax
    ret
.Lhm_no:
    popl %esi
    xorl %eax, %eax
    ret

# ================= 词法（v1 + return + {`{}`} + if/else/while/for + 比较算子） =================
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
    cmpb $'0', %al
    jb .Lnt_alpha
    cmpb $'9', %al
    jbe .Lnt_num
    jmp .Lnt_alpha
.Lnt_num:
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
.Lnt_alpha:
    movzbl (%esi), %eax
    call is_alpha
    jnc .Lnt_nonid
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
    # 关键字分派（按长度）：2=if 3=int/for 4=else 5=while 6=return
    cmpl $2, %edi
    je .Lna_kw2
    cmpl $3, %edi
    je .Lna_kw3
    cmpl $4, %edi
    je .Lna_kw4
    cmpl $5, %edi
    je .Lna_kw5
    cmpl $6, %edi
    je .Lna_kw6
    jmp .Lna_ident
.Lna_kw2:                      # "if"
    movl tok_start, %edx
    cmpb $'i', (%edx)
    jne .Lna_ident
    cmpb $'f', 1(%edx)
    jne .Lna_ident
    movl $TOK_IF, tok_kind
    ret
.Lna_kw3:                      # "int" / "for"
    movl tok_start, %edx
    cmpb $'i', (%edx)
    jne .Lna_kw3_for
    cmpb $'n', 1(%edx)
    jne .Lna_ident
    cmpb $'t', 2(%edx)
    jne .Lna_ident
    movl $TOK_INT, tok_kind
    ret
.Lna_kw3_for:
    cmpb $'f', (%edx)
    jne .Lna_ident
    cmpb $'o', 1(%edx)
    jne .Lna_ident
    cmpb $'r', 2(%edx)
    jne .Lna_ident
    movl $TOK_FOR, tok_kind
    ret
.Lna_kw4:                      # "else"
    movl tok_start, %edx
    cmpb $'e', (%edx)
    jne .Lna_ident
    cmpb $'l', 1(%edx)
    jne .Lna_ident
    cmpb $'s', 2(%edx)
    jne .Lna_ident
    cmpb $'e', 3(%edx)
    jne .Lna_ident
    movl $TOK_ELSE, tok_kind
    ret
.Lna_kw5:                      # "while"
    movl tok_start, %edx
    cmpb $'w', (%edx)
    jne .Lna_ident
    cmpb $'h', 1(%edx)
    jne .Lna_ident
    cmpb $'i', 2(%edx)
    jne .Lna_ident
    cmpb $'l', 3(%edx)
    jne .Lna_ident
    cmpb $'e', 4(%edx)
    jne .Lna_ident
    movl $TOK_WHILE, tok_kind
    ret
.Lna_kw6:                      # "return"
    movl tok_start, %edx
    cmpb $'r', (%edx)
    jne .Lna_ident
    cmpb $'e', 1(%edx)
    jne .Lna_ident
    cmpb $'t', 2(%edx)
    jne .Lna_ident
    cmpb $'u', 3(%edx)
    jne .Lna_ident
    cmpb $'r', 4(%edx)
    jne .Lna_ident
    cmpb $'n', 5(%edx)
    jne .Lna_ident
    movl $TOK_RETURN, tok_kind
    ret
.Lna_ident:
    movl $TOK_IDENT, tok_kind
    ret
.Lnt_nonid:
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
    cmpb $'<', %al
    je .Lns_lt
    cmpb $'>', %al
    je .Lns_gt
    cmpb $'!', %al
    je .Lns_bang
    cmpb $';', %al
    je .Lns_semi
    cmpb $',', %al
    je .Lns_comma
    cmpb $'{', %al
    je .Lns_lb
    cmpb $'}', %al
    je .Lns_rb
    movl $1, %ebx
    jmp err_msg
.Lns_plus:  movl $TOK_PLUS,   tok_kind; jmp .Lns_adv
.Lns_minus: movl $TOK_MINUS,  tok_kind; jmp .Lns_adv
.Lns_star:  movl $TOK_STAR,   tok_kind; jmp .Lns_adv
.Lns_slash: movl $TOK_SLASH,  tok_kind; jmp .Lns_adv
.Lns_lp:    movl $TOK_LPAREN, tok_kind; jmp .Lns_adv
.Lns_rp:    movl $TOK_RPAREN, tok_kind; jmp .Lns_adv
.Lns_eq:                          # '=' / '=='
    cmpb $'=', 1(%esi)
    jne .Lns_assign
    movl $TOK_EQ, tok_kind
    movl $2, tok_len
    addl $2, %esi
    ret
.Lns_assign:
    movl $TOK_ASSIGN, tok_kind
    incl %esi
    ret
.Lns_lt:                          # '<' / '<='
    cmpb $'=', 1(%esi)
    jne .Lns_lt1
    movl $TOK_LE, tok_kind
    movl $2, tok_len
    addl $2, %esi
    ret
.Lns_lt1:
    movl $TOK_LT, tok_kind
    incl %esi
    ret
.Lns_gt:                          # '>' / '>='
    cmpb $'=', 1(%esi)
    jne .Lns_gt1
    movl $TOK_GE, tok_kind
    movl $2, tok_len
    addl $2, %esi
    ret
.Lns_gt1:
    movl $TOK_GT, tok_kind
    incl %esi
    ret
.Lns_bang:                        # '!='（逻辑非 ! 留待 P4；孤立 '!' 为非法字符 → exit 1）
    cmpb $'=', 1(%esi)
    jne .Lns_bang_bad
    movl $TOK_NE, tok_kind
    movl $2, tok_len
    addl $2, %esi
    ret
.Lns_bang_bad:
    movl $1, %ebx
    jmp err_msg
.Lns_semi:  movl $TOK_SEMI,   tok_kind; jmp .Lns_adv
.Lns_comma: movl $TOK_COMMA,  tok_kind; jmp .Lns_adv
.Lns_lb:    movl $TOK_LBRACE, tok_kind; jmp .Lns_adv
.Lns_rb:    movl $TOK_RBRACE, tok_kind; jmp .Lns_adv
.Lns_adv:
    incl %esi
    ret

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

# ================= peek / restore / commit（内存深度栈，严格配对） =================
# 备份存独立内存槽（pk_* + pk_depth），不占编译/生成栈——peek_token 自身 ret 时栈必须
# 平衡（曾因备份留在编译栈顶导致 ret 弹出输入指针、执行流跳进 in_buf，见日志会话 6）
peek_token:
    movl pk_depth, %ecx
    cmpl $8, %ecx
    jge Lsyn_err                 # 前瞻嵌套过深（v3 最坏 3 层，8 足够）
    movl tok_kind, %eax
    movl %eax, pk_kind(,%ecx,4)
    movl tok_ival, %eax
    movl %eax, pk_ival(,%ecx,4)
    movl tok_start, %eax
    movl %eax, pk_start(,%ecx,4)
    movl tok_len, %eax
    movl %eax, pk_len(,%ecx,4)
    movl %esi, %eax
    movl %eax, pk_cur(,%ecx,4)
    incl pk_depth
    call next_token
    ret
restore_token:
    movl pk_depth, %ecx
    testl %ecx, %ecx
    jz Lsyn_err                  # 下溢防御
    decl %ecx
    movl pk_kind(,%ecx,4), %eax
    movl %eax, tok_kind
    movl pk_ival(,%ecx,4), %eax
    movl %eax, tok_ival
    movl pk_start(,%ecx,4), %eax
    movl %eax, tok_start
    movl pk_len(,%ecx,4), %eax
    movl %eax, tok_len
    movl pk_cur(,%ecx,4), %esi
    movl %ecx, pk_depth
    ret
commit_peek:
    movl pk_depth, %ecx
    testl %ecx, %ecx
    jz Lsyn_err
    decl %ecx
    movl %ecx, pk_depth
    ret

# ================= 代码生成助手（v2 + 标号助手） =================
emit_push_imm:
    leal s_push_pre, %ecx
    call app_str
    movl tok_ival, %eax
    call app_dec
    movl $10, %eax
    call app_char
    call emit_line
    ret

emit_template:
    call app_str
    call emit_line
    ret

# ---- v3 标号助手（%eax = 标号号） ----
emit_jz:                        # "    jz L<num>\n"
    pushl %eax
    leal s_jz_pre, %ecx
    call app_str
    popl %eax
    call app_dec
    movl $10, %eax
    call app_char
    call emit_line
    ret
emit_jmp:                       # "    jmp L<num>\n"
    pushl %eax
    leal s_jmp_pre, %ecx
    call app_str
    popl %eax
    call app_dec
    movl $10, %eax
    call app_char
    call emit_line
    ret
emit_label:                     # "L<num>:\n"
    pushl %eax
    leal s_lab_pre, %ecx
    call app_str
    popl %eax
    call app_dec
    movl $':', %eax
    call app_char
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

# app_dec_signed: %eax 有符号 → 十进制（负号前缀）
app_dec_signed:
    testl %eax, %eax
    jns .Lads_pos
    negl %eax
    pushl %eax
    movl $'-', %eax
    call app_char
    popl %eax
.Lads_pos:
    call app_dec
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

# copy_name: 当前 IDENT → scratch_name（NUL 结尾）；超长 → Lsyn_err
copy_name:
    pushl %esi
    movl tok_len, %ecx
    cmpl $MAX_NAMELEN, %ecx
    jg .Lcn_err
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
.Lcn_err:
    popl %esi
    jmp Lsyn_err

# sym_find: 自末倒序查变量表（最近声明者优先=内层遮蔽外层）→ %eax = 索引 / -1
#   调用方另取 sym_off（本函数返回索引）
sym_find:
    pushl %esi
    movl sym_count, %edi
    decl %edi
.Lsf_test:
    cmpl $-1, %edi
    je .Lsf_miss
    movl %edi, %ecx
    shll $4, %ecx
    leal sym_name(%ecx), %esi
    leal scratch_name, %edx
    xorl %eax, %eax
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
    jmp .Lsf_hit
.Lsf_next:
    decl %edi
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

# sym_find_current: 仅查当前块 [scope_base, sym_count) 是否有同名 → %eax = 索引 / -1
#   用于声明重名检查：遮蔽外层合法，不判重（对齐 C 语义）
sym_find_current:
    pushl %esi
    movl sym_count, %edi
    decl %edi
.Lsfc_test:
    cmpl scope_base, %edi
    jl .Lsfc_ok
    movl %edi, %ecx
    shll $4, %ecx
    leal sym_name(%ecx), %esi
    leal scratch_name, %edx
    xorl %eax, %eax
.Lsfc_cmp:
    movb (%eax,%esi), %cl
    movb (%eax,%edx), %ch
    cmpb %ch, %cl
    jne .Lsfc_next
    testb %ch, %ch
    jz .Lsfc_hit
    incl %eax
    cmpl $MAX_NAMELEN, %eax
    jb .Lsfc_cmp
    jmp .Lsfc_hit
.Lsfc_next:
    decl %edi
    jmp .Lsfc_test
.Lsfc_hit:
    popl %esi
    movl %edi, %eax
    ret
.Lsfc_ok:
    popl %esi
    movl $-1, %eax
    ret
