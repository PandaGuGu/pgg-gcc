# pggcc2.s —— pggcc v2（P2 阶段）自研编译器本体（无蛋 stage-2）
#
# 职责：读入 stdin 程序文本（函数定义序列）→ 输出可独立运行的 i386 AT&T 汇编（.s），
#      入口固定 main：_start 调用 f_main 并打印其返回值（换行后 exit）。
#      构建链 as --32 + ld -m elf_i386（无 crt/libc），全程不调用任何 C/C++ 编译器。
#      本文件由 v1（pggcc1.s）扩展而来。
#
# 语言子集（plan §4.2，ISO/IEC 9899:1990 §6.1/§6.3/§6.5/§6.7/§6.6）：
#   func   := 'int' IDENT '(' params ')' '{' stmt* '}'
#   params := ε | IDENT (',' IDENT)*                  // 全 int，按值传递
#   stmt   := decl | assign ';' | expr ';' | return expr ';'
#   call   := IDENT '(' args ')'                      // primary 内
#   args   := ε | expr (',' expr)*
#   return := 'return' expr ';'
#   其余同 v1（decl/assign/expr/term/unary/primary；primary 增 call）
# 语义：int 返回；cdecl 调用约定（实参从右到左压栈——源码序解析天然满足：
#      最后一个实参最后压栈、位于栈顶；调用方 addl $4n,%esp 平衡）；return 立即
#      退出函数、值入 %eax；函数级作用域（v2 无嵌套块）；入口函数固定 main。
#
# 代码生成（复述）：
#   - _start: call f_main → print_decimal → 换行 → exit（%eax=main 返回值）
#   - 函数序言: f_<name>: pushl %ebp; movl %esp,%ebp；常量尾声 movl %ebp,%esp; popl %ebp; ret
#   - 局部变量沿用 v1 机制：逐声明运行时 subl $4,%esp，第 l 个局部槽 -4(l+1)(%ebp)
#   - 参数槽 +8+4k(%ebp)（cdecl：第一个参数 8(%ebp)，随后 +4 递增）
#   - 调用: pushl 实参(源码序) → call f_<name> → addl $4n,%esp → pushl %eax（返回值入表达式栈）
#   - return: popl %eax → 尾声指令（内联）
#
# 较 v1 的关键改造（日志会话 6 留痕）：
#   - 打印语义：v1"末语句值"废弃 → 改为 main 返回值（_start 调用 f_main）
#   - peek/restore 由单槽内存改**编译栈式**（peek_token/restore_token/commit_peek 严格配对），
#     支持函数调用等嵌套 2-token 前瞻（v1 的单槽 save_* 遇嵌套会覆盖）
#   - 函数名在实参解析期间可能被嵌套调用覆盖 scratch_name → 调用现场压栈 16B 保护
#   - 实参计数用编译栈"计数位"（incl (%esp)），避免重入覆盖
#   - 变量槽偏移支持正/负：参数 +8+4k、局部负偏移（新增 app_dec_signed）
#   - 自证"递归"点需控制流（if），P3 才引入 → 顺延至 v3，本阶段留痕
#
# 编译器自身寄存器约定（同前，硬性）：
#   %esi=输入游标（所有内部 helper 自存自取）；%edi=%ebp=跨 call 安全临时；
#   app_* 助手破坏 %ecx/%edx；递归重入的中间状态一律压编译栈或存 edi/ebp/内存局部。

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

.equ MAX_SYM,     32            # 每函数变量/参数总数上限
.equ MAX_NAMELEN, 16            # 名长上限
.equ MAX_FUNC,    16            # 函数数上限

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
# 生成程序运行时助手 + .bss（同 v0/v1）
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
    # 函数上下文：变量表重置、参数计数清零
    movl $0, sym_count
    movl $0, fn_nparams
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
    call parse_func_body      # stmt* 至 '}'（当前 = '}'）
    movl tok_kind, %eax
    cmpl $TOK_RBRACE, %eax
    jne Lsyn_err
    call next_token
    # 函数尾声
    leal s_func_epi, %ecx
    call emit_template
    ret

# ================= 函数体语句 =================
# parse_func_body: stmt*，遇 TOK_RBRACE 返回（不消费 '}'）
parse_func_body:
    movl tok_kind, %eax
    cmpl $TOK_RBRACE, %eax
    je .Lpfb_done
    cmpl $TOK_INT, %eax
    je parse_decl
    cmpl $TOK_RETURN, %eax
    je .Lpfb_return
    cmpl $TOK_IDENT, %eax
    je .Lpfb_maybe_assign
    jmp .Lpfb_expr
.Lpfb_maybe_assign:
    call peek_token
    movl tok_kind, %eax
    cmpl $TOK_ASSIGN, %eax
    je .Lpfb_assign
    call restore_token
    jmp .Lpfb_expr
.Lpfb_assign:
    call restore_token
    call parse_assign
    movl tok_kind, %eax
    cmpl $TOK_SEMI, %eax
    jne Lsyn_err
    call next_token
    leal s_stmt_end, %ecx
    call emit_template
    jmp parse_func_body
.Lpfb_expr:
    call parse_expr
    movl tok_kind, %eax
    cmpl $TOK_SEMI, %eax
    jne Lsyn_err
    call next_token
    leal s_stmt_end, %ecx
    call emit_template
    jmp parse_func_body
.Lpfb_return:
    call next_token            # → expr
    call parse_expr            # 值压栈
    movl tok_kind, %eax
    cmpl $TOK_SEMI, %eax
    jne Lsyn_err
    call next_token
    leal s_ret_seq, %ecx
    call emit_template         # popl %eax + 尾声
    jmp parse_func_body
.Lpfb_done:
    ret

# ================= 声明（函数内，用法同 v1）=================
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
    jmp parse_func_body        # 声明语句完成 → 回到函数体语句循环
.Lpd_comma:
    call next_token
    jmp .Lpd_ident

# ================= 赋值 / 表达式（同 v1）=================
parse_assign:
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
# primary := NUM | IDENT | IDENT '(' args ')' | '(' expr ')'
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
    call parse_assign         # 完整解析+发码（值压栈）
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
    call parse_expr
    movl tok_kind, %eax
    cmpl $TOK_RPAREN, %eax
    jne Lsyn_err
    call next_token
    ret

# ================= 符号表：变量（函数级） =================
# lookup_var: 当前 token=IDENT → 槽偏移/%eax；未声明 → Lsyn_err
lookup_var:
    call copy_name
    call sym_find
    cmpl $-1, %eax
    je Lsyn_err
    ret

# declare_param: 当前 token=IDENT，按参数登记（xor 重名检查）
declare_param:
    call copy_name
    call sym_find
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

# declare_local: 当前 token=IDENT，按局部登记（xor 重名）＋发码 subl
declare_local:
    call copy_name
    call sym_find
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

# ================= 符号表：函数 =================
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

# ================= 词法（v1 + return/{/}） =================
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
    # 关键字：int / return（先查 int）
    cmpl $3, %edi
    je .Lna_kw3
    cmpl $6, %edi
    je .Lna_kw6
    jmp .Lna_ident
.Lna_kw3:
    movl tok_start, %edx
    cmpb $'i', (%edx)
    jne .Lna_ident
    cmpb $'n', 1(%edx)
    jne .Lna_ident
    cmpb $'t', 2(%edx)
    jne .Lna_ident
    movl $TOK_INT, tok_kind
    ret
.Lna_kw6:
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
.Lns_eq:    movl $TOK_ASSIGN, tok_kind; jmp .Lns_adv
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
    jge Lsyn_err                 # 前瞻嵌套过深（v2 最坏 2-3 层，8 足够）
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

# sym_find: 比较 scratch_name 与变量表 → %eax = 索引 / -1（槽偏移另取）
sym_find:
    pushl %esi
    movl $0, %edi
.Lsf_test:
    cmpl sym_count, %edi
    jge .Lsf_miss
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
