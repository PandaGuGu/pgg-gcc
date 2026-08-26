# pggcc4.s —— pggcc v4（P4 一期）自研编译器本体（无蛋 stage-4 · 编译器核心子集 B1——生蛋原料）
#
# 职责：读入 stdin 程序文本（类型化函数/全局变量序列）→ 输出可独立运行的 i386 AT&T 汇编（.s），
#      入口固定 main：_start 调用 f_main 并打印其返回值（换行后 exit）。
#      构建链 as --32 + ld -m elf_i386（无 crt/libc），全程不调用任何 C/C++ 编译器。
#      本文件由 v3（pggcc3.s）扩展而来；细则：plan-language-features.md §4.4（2026-08-25 起草）。
#
# 语言子集（v4 = P4 一期，对标 subC 最小面，B1 生蛋原料）：
#   类型系统：符号表 {name, off, tbase, tptr, anum}
#     tbase ∈ {T_INT, T_CHAR}；tptr = 指针层级（0 标量 / 1 一级 / 2 二级，上限 2）；
#     数组不单独成类型：`int a[N]` = (tbase, tptr=1, anum=N)；anum=0 表示非数组；
#     数组名作表达式 = 首元素地址（退化指针，只读，不可整体赋值）；
#     char 定无符号（读零扩展）；char 变量占 4B 栈槽（低字节有效）、char 数组/全局元素 1B；
#     全局符号表独立 {name, tbase, tptr, anum}，跨函数可见，可初始化（.data）或零（.bss）。
#   声明：type := 'int'|'char'；dec := ('*')* IDENT ('[' NUM ']')?     # 数组仅一维；
#     复合声明符（int *a[3]）不在面（错误）；局部标量可 `= expr` 初始化；全局可常量初始化。
#   函数：type := 'int'|'char'|'void' ('*')*（返回指针为 §4.4 的实现延伸，支撑 strcpy 自证）；
#     参数 int/char/指针按值；cdecl 约定；`void` 内可无 return / return 无值。
#   表达式：与/或（短路 0/1）、比较、算术、一元 -/!/取址&/解引用*/前缀++--、后缀 [i]/++/--、
#     强转 (int)(char)(int*)(char*)、字符/字符串字面量、函数调用。
#   语句：声明/表达式/return/块（遮蔽+栈回收）/ if/else / while / for / do-while / break / continue。
#   注释：/* ... */（C89 单层不嵌套）。
#
# 代码生成（复述 §4.4 第 4 节 + 实现约定）：
#   - _start: call f_main → f_print_decimal → 换行 → exit；无 libc/crt 裸 syscall。
#   - 数据段：按需切换 .text/.data/.bss/.rodata 输出（字符串 Lstr%d 入 .rodata、全局初值 .data、零值 .bss）。
#   - 读：int/ptr `movl -off(%ebp),%eax`；char `movzbl -off(%ebp),%eax`（零扩展）；数组名 `leal 基址`。
#   - 左值求址发码（parse_unary 以 lval_mode=1 进入即"地址模式"）：
#       变量 → leal -off(%ebp)（全局 leal g_x）；`*e` → e 值即地址（操作数以值模式解析）；
#       `e[i]` → 基址 + idx×esz；lval 模式下指针变量作下标基时先自槽读值（slot→value）。
#   - 写回统一：pushl 地址; <右值>; popl %eax; popl %ecx; movx %eax,(%ecx); movzbl? 终值回栈。
#   - 复合赋值/前后缀：单次求址 → 读旧值 → 运算 → 写回（前缀返新值、后缀返旧值）；
#     指针 ± 按 esz 步进（int/ptr ×4，char ×1）。
#   - 逻辑短路：&& → test/jz Lf; <右>; test/jz Lf; push 1; jmp Le; Lf: push 0; Le:；|| 对称。
#   - do-while：LD: body; cond; test; jnz LD；break/continue 走循环控制标号栈 [cont,brk]。
#   - 强转：int→char `movzbl %al,%eax`（截断零扩展）；int↔ptr 值重解释无操作。
#   - char 函数：返回低字节、调用方 movzbl 扩展；void 函数调用不取值。运行时助手新增 f_print_str。
#
# 实现留痕（§4.4"实现时可推翻但须留痕"）：
#   D1 赋值左值检测：parse_assign 先经 is_assign_ahead 原始文本扫描（跳过注释/引号，括号深度保护，
#      排除 ==/<=/>=/!=）判定顶层是否存在赋值/复合赋值算子；有→以 lval_mode 解析左值再处理赋值，
#      无→常规 parse_logic 值链。代价：后缀 ++/-- 作用的下标/解引用左值会在重放时二次求值（登记限制）。
#   D2 局部声明改为"逐声明 subl $N"，off 由累积 local_bytes 推算（数组按 N×esz 取整到 4）；
#      块出栈回收改为按 local_bytes 差（而非符号数×4）。
#   D3 函数返回类型允许指针（type '*'*），支撑自证要点 10（strcpy 返回 char*）——B2 预演必需。
#   D4 运行时助手更名 f_*（f_print_decimal/f_print_char/f_print_str）并预注入函数表，
#      用户代码可直接调用（重定义同名 → 错误）。
#   D5 未被赋值算子的左值表达式以值模式继续下层解析（primary 视 lval_mode 决定发码）。
#   D6 首轮自证调试修复 6 处（2026-08-25，见 docs/logs 会话 10）：
#       ①is_assign_ahead 引号越界——闭引号被当新开引号 addl $2 吞掉 ';'，误判后续语句有赋值
#         （修：改为扫描到同名闭引号再越过）；②esc_decode 无八进制且不推进 %esi、.Lns_char
#         转义后不推进（字符转义全挂）——统一"esc_decode 推进+八进制 \ddd"，.Lns_str 删多余推进；
#       ③parse_global_decl 用 %edi 携带 tbase 跨 func_find/gs_find/reg_global（均破坏寄存器）→
#         改内存槽 pd_tbase；④reg_global 名字拷贝循环 movb (%esi,%edx),%al 破坏 tbase → pushl 保护；
#       ⑤全局标量/字符串初值漏消费初值 token（.Lpg_next 检查 SEMI 时报错）+ app_dec 前 %eax 未保护
#         （.byte 输出残值）；⑥.Lpg_instr 用 %esi 遍历 str_tab 破坏输入游标 → 改 %ebx。
#   D7 emit_string_lit 补 NUL 终止字节输出（此前 Lstr 两两粘连，strcpy(x,"abc") 会读到
#      "abcabc"——len/strcmp 类程序行为错乱）。
#   D8 子集限制登记：函数须"先定义后调用"（无处前向声明/隐式声明）；char 常量初值 '\0'（NUL
#      字面量）被 .Lns_char 的返回值 0 检查拒绝；字符串初值超数组长按截断处理（C89 要求报错，
#      本阶段登记为不报错限制）。
#   D9–D12 = B2-P0（v4.1 模板扩展，2026-08-25，见 docs/logs 会话 11；方案 architecture-b2-bootstrap §3）
#   D9 内建扩展（S1）：print_int / print_err / exit 入内建函数表（均 void，cdecl 从调用栈取参），
#      运行时模板 s_runtime 增 f_print_int（十进制不带换行）/ f_print_err（fd2＋换行）/ f_exit
#      （sys_exit，实参→%ebx）；保留名同 print_str 先例（用户重定义同名 → 错误）。
#   D10 stdin 预读（S2）：源程序声明全局 src_buf 与 src_len → _start 在 call f_main 前
#      read(0, g_src_buf, N)（N = src_buf 声明长度 anum），字节数存 g_src_len，读失败置 0；
#      未同时声明两者则不发预读（零开销）。判定依据 parse 后的 gs_* 全局符号表。
#   D11 rc 打印开关（S3）：源程序声明全局 pg_quiet 且非 0 → 跳过 return 值打印（供编译器类
#      程序以 stdout 输出产物）；未声明则维持"打印返回值"语义。
#   D12 发码顺序调整：_start 原在解析前输出 s_head_start/s_main_epi → 移至 parse_top 之后
#      （emit_prog_head/emit_prog_epi），使 D10/D11 的条件判定可依赖 gs_*；安全依据：
#      as 默认 .text 起步，函数体初始即落 .text，全局/字符串段切出后均显式切回 .text，
#      s_head_start 自带 .section .text，故 _start 码段始终正确落段。
#   D13 out_line 溢出加固：s_runtime 超长（v4.1 增助手后 >128B），原 emit_template 一次性
#      app_str 逐字符写 out_line(128B) 越过 .bss 末端 → 段错误 → 改分块发码 emit_runtime
#      （每 ~100 字符刷一行，字节流不变）。
#   D14 B2-P0 期发现并修复 v4 遗留死角（v4 全局无 int 标量初值用例，未覆盖）：.Lpg_long
#      全局 int 标量初值原用 %eax 跨 emit_template/app_str 携带 → 被破坏，.data 输出
#      `.long 残值`（如 =0 变 .long 32）→ 改 %ebx 携带（app_str/emit_template 不破坏 %ebx），
#      并补 int 标量初值回归用例（pg_quiet=0/1 依赖此路径）。
#   D15 B2a 自举期发现并修复 v4 潜伏缺陷：函数调用实参边界扫描（.Lpc_scan_loop）原不跳过
#      注释/引号字符区 → 字符串实参内含 ','（如 print_str("...%ecx, %eax...")）被误判为实参
#      分隔符 → 回放解析拦腰重扫碎串（裸 % / \ 报错 exit 1）。修复：仿 is_assign_ahead 增加
#      引号（含 \X 转义）与 /* */ 注释跳过。回归：run.sh 增字符串带逗号实参用例。
#   E1 B2a 前置：源码读入上限 4096→65536（boot0.pgc 本体 >4KB，B2 自举必需；in_buf 扩容）。
#   E2 B2d 前置：字符串字面量常量表上限 64→256（B2d 起 boot0.pgc 模板字面量 >64 条；str_tab 扩容）。
#   E3 B2d 前置：函数数上限 32→64（B2d 起 boot0.pgc 函数数 >32；fn 表/计数扩容）。
#   E4 B2f 前置：全局符号数上限 64→128（B2f 起 boot0.pgc 全局符号恰 64，`ast`/`astp` 位居后段、
#      居尾者触发 reg_global `.Lrg_full` → 误报语法错误；gs_* 表扩容）。
#
# 引擎限制登记（B2a 实测）：字符串字面量解码后 ≤255 字节（str_tab 每条 256B，`cmpl $255,%edx;
#   jge Lsyn_err`），超出报"未闭合"；boot0 模板须按此分块（见 boot0.pgc et()）。
#
# 寄存器约定（同前，硬性）：%esi=输入游标（内部 helper 自存自取）；%edi 跨 app_* 调用安全；
#   lval_mode / cur_tbase·cur_tptr·cur_anum·cur_lval 为表达式结果/左值性全局状态；
#   递归重入状态（算子/类型/标号/基址）一律压编译栈；dec_to_str 破坏 %ebx。

.equ TOK_END,     0
.equ TOK_NUM,     1
.equ TOK_PLUS,    2
.equ TOK_MINUS,   3
.equ TOK_STAR,    4
.equ TOK_SLASH,   5
.equ TOK_LPAREN,  6
.equ TOK_RPAREN,  7
.equ TOK_IDENT,   8
.equ TOK_ASSIGN,  9
.equ TOK_SEMI,    10
.equ TOK_COMMA,   11
.equ TOK_INT,     12
.equ TOK_RETURN,  13
.equ TOK_LBRACE,  14
.equ TOK_RBRACE,  15
.equ TOK_IF,      16
.equ TOK_ELSE,    17
.equ TOK_WHILE,   18
.equ TOK_FOR,     19
.equ TOK_EQ,      20
.equ TOK_NE,      21
.equ TOK_LT,      22
.equ TOK_LE,      23
.equ TOK_GT,      24
.equ TOK_GE,      25
.equ TOK_LBKT,    26
.equ TOK_RBKT,    27
.equ TOK_INC,     28
.equ TOK_DEC,     29
.equ TOK_AMP,     30
.equ TOK_BANG,    31
.equ TOK_LOGAND,  32
.equ TOK_LOGOR,   33
.equ TOK_OPADD,   34
.equ TOK_OPSUB,   35
.equ TOK_OPMUL,   36
.equ TOK_OPDIV,   37
.equ TOK_CHARLIT, 38
.equ TOK_STRLIT,  39
.equ TOK_CHAR,    40
.equ TOK_VOID,    41
.equ TOK_DO,      42
.equ TOK_BREAK,   43
.equ TOK_CONTINUE,44

.equ T_INT,  0
.equ T_CHAR, 1
.equ T_VOID, 2

.equ MAX_SYM,    48            # 每函数变量/参数总数上限（跨块累计）
.equ MAX_NAMELEN, 16            # 名长上限
.equ MAX_FUNC,    64            # 函数数上限（含 3 个运行时内建；E3：B2d 起 boot0 函数 >32）
.equ MAX_BLK,     64            # 块嵌套深度上限
.equ MAX_GLB,     256           # 全局符号数上限（E4：B2f 起 boot0 全局 =64，astp 恰第 64 个越界；E6：P4-II boot0 全局 131，T_* 常量行 56 个命名常量也计全局）
.equ MAX_STR,     4096          # 字符串字面量常量表上限（每条 ≤256B；E8：P4-II 剩余特性 boot0 新增 &/struct数组/3D/-> 等分支大量 print_str，重放登记量逼近 1024 上限）
.equ MAX_LOOP,    64            # 循环嵌套深度上限

.section .rodata
msg_usage:  .asciz "error: usage: pggcc < program\n"
s_err_pre:  .asciz "error: "
s_space:    .asciz " "
s_nl:       .asciz "\n"
s_main_name:.asciz "main"
bi_print_dec: .asciz "print_decimal"
bi_print_char:.asciz "print_char"
bi_print_str: .asciz "print_str"
bi_print_int: .asciz "print_int"
bi_print_err: .asciz "print_err"
bi_exit:      .asciz "exit"

# ---- B2-P0（v4.1）保留全局判定的字面名 ----
lit_src_buf:  .asciz "src_buf"
lit_src_len:  .asciz "src_len"
lit_pg_quiet: .asciz "pg_quiet"

# ---- 生成程序（.s）固定文本模板 ----
s_head_start: .asciz ".section .text\n.globl _start\n_start:\n"    # _start 无条件部分
s_head_callmain: .asciz "    call f_main\n"
s_main_epi:   .asciz "    call f_print_decimal\n    movl $10, %eax\n    call f_print_char\n    movl $1, %eax\n    xorl %ebx, %ebx\n    int $0x80\n"
# S2 stdin 预读（条件发码，src_buf 与 src_len 均存在时）：
#   read(0, g_src_buf, N) → g_src_len（N = src_buf 声明长度 anum）
s_rd_a:       .asciz "    movl $3, %eax\n    xorl %ebx, %ebx\n    leal "
s_rd_b:       .asciz ", %ecx\n    movl $"
s_rd_c:       .asciz ", %edx\n    int $0x80\n    movl %eax, "
s_rd_d:       .asciz "\n    testl %eax, %eax\n    jns Lrds_ok\n    movl $0, "
s_rd_e:       .asciz "\nLrds_ok:\n"
# S3 rc 打印开关（条件发码，pg_quiet 存在时）：pg_quiet != 0 → 跳过 return 打印
s_q_pre:      .asciz "    cmpl $0, "
s_q_tail:     .asciz "\n    jnz Lq_rc\n    call f_print_decimal\n    movl $10, %eax\n    call f_print_char\nLq_rc:\n    movl $1, %eax\n    xorl %ebx, %ebx\n    int $0x80\n"
s_push_pre:   .asciz "    pushl $"
op_add:       .asciz "    popl %ecx\n    popl %eax\n    addl %ecx, %eax\n    pushl %eax\n"
op_sub:       .asciz "    popl %ecx\n    popl %eax\n    subl %ecx, %eax\n    pushl %eax\n"
op_mul:       .asciz "    popl %ecx\n    popl %eax\n    imull %ecx, %eax\n    pushl %eax\n"
op_div:       .asciz "    popl %ecx\n    popl %eax\n    cltd\n    idivl %ecx\n    pushl %eax\n"
unary_neg:    .asciz "    popl %eax\n    negl %eax\n    pushl %eax\n"
s_dealloc:    .asciz "    addl $"          # +N + s_dealloc2（块出栈回收，N=字节）
s_dealloc2:   .asciz ", %esp\n"
s_vread1:     .asciz "    movl "          # +signed_off+ "(%ebp), %eax\n    pushl %eax\n"
s_vread2:     .asciz "(%ebp), %eax\n    pushl %eax\n"
s_zread1:     .asciz "    movzbl "        # +signed_off+ s_vread2
s_stmt_end:   .asciz "    popl %eax\n"
s_func_epi:   .asciz "    movl %ebp, %esp\n    popl %ebp\n    ret\n"
s_flabel1:    .asciz "f_"
s_flabel2:    .asciz ":\n    pushl %ebp\n    movl %esp, %ebp\n"
s_call1:      .asciz "    call f_"
s_call3:      .asciz "    addl $"
s_call4:      .asciz ", %esp\n    pushl %eax\n"
s_call_char:  .asciz ", %esp\n    movzbl %al, %eax\n    pushl %eax\n"
s_cnd_test:   .asciz "    popl %eax\n    testl %eax, %eax\n"
s_jz_pre:     .asciz "    jz L"
s_jnz_pre:    .asciz "    jnz L"
s_jmp_pre:    .asciz "    jmp L"
s_lab_pre:    .asciz "L"
# 比较（无分支 setCC）
cmp_eq: .asciz "    popl %ecx\n    popl %eax\n    cmpl %ecx, %eax\n    sete %al\n    movzbl %al, %eax\n    pushl %eax\n"
cmp_ne: .asciz "    popl %ecx\n    popl %eax\n    cmpl %ecx, %eax\n    setne %al\n    movzbl %al, %eax\n    pushl %eax\n"
cmp_lt: .asciz "    popl %ecx\n    popl %eax\n    cmpl %ecx, %eax\n    setl %al\n    movzbl %al, %eax\n    pushl %eax\n"
cmp_le: .asciz "    popl %ecx\n    popl %eax\n    cmpl %ecx, %eax\n    setle %al\n    movzbl %al, %eax\n    pushl %eax\n"
cmp_gt: .asciz "    popl %ecx\n    popl %eax\n    cmpl %ecx, %eax\n    setg %al\n    movzbl %al, %eax\n    pushl %eax\n"
cmp_ge: .asciz "    popl %ecx\n    popl %eax\n    cmpl %ecx, %eax\n    setge %al\n    movzbl %al, %eax\n    pushl %eax\n"
# v4 新增发码模板
s_leal_pre:   .asciz "    leal "
s_leal_pst:   .asciz "(%ebp), %eax\n    pushl %eax\n"     # leal + signed_off + pst
s_glb_movl:   .asciz "    movl g_"                       # +name+ ", %eax\n    pushl %eax\n"
s_glb_z:      .asciz "    movzbl g_"
s_glb_lea:    .asciz "    leal g_"
s_glb_tail:   .asciz ", %eax\n    pushl %eax\n"
s_deref_movl: .asciz "    popl %eax\n    movl (%eax), %eax\n    pushl %eax\n"
s_deref_movz: .asciz "    popl %eax\n    movzbl (%eax), %eax\n    pushl %eax\n"
s_lognot:     .asciz "    popl %eax\n    testl %eax, %eax\n    sete %al\n    movzbl %al, %eax\n    pushl %eax\n"
s_cast_char:  .asciz "    popl %eax\n    movzbl %al, %eax\n    pushl %eax\n"
s_wb_int:     .asciz "    popl %eax\n    popl %ecx\n    movl %eax, (%ecx)\n    pushl %eax\n"
s_wb_char:    .asciz "    popl %eax\n    popl %ecx\n    movb %al, (%ecx)\n    movzbl %al, %eax\n    pushl %eax\n"
s_com_pre:    .asciz "    popl %edx\n    popl %ecx\n    pushl %ecx\n"   # 复合赋值：edx=右值 ecx=地址(存栈)
s_com_ldi:    .asciz "    movl (%ecx), %eax\n"
s_com_ldc:    .asciz "    movzbl (%ecx), %eax\n"
s_com_add:    .asciz "    addl %edx, %eax\n"
s_com_sub:    .asciz "    subl %edx, %eax\n"
s_com_mul:    .asciz "    imull %edx, %eax\n"
s_com_div:    .asciz "    movl %eax, %ebx\n    movl %edx, %ecx\n    movl %ebx, %eax\n    cltd\n    idivl %ecx\n"
s_com_sti:    .asciz "    popl %ecx\n    movl %eax, (%ecx)\n    pushl %eax\n"
s_com_stc:    .asciz "    popl %ecx\n    movb %al, (%ecx)\n    movzbl %al, %eax\n    pushl %eax\n"
s_pfx_pop:    .asciz "    popl %eax\n"
s_pfx_ldi:    .asciz "    movl (%eax), %ecx\n"
s_pfx_ldc:    .asciz "    movzbl (%eax), %ecx\n"
s_pfx_inc:    .asciz "    incl %ecx\n"
s_pfx_dec:    .asciz "    decl %ecx\n"
s_pfx_i4:     .asciz "    addl $4, %ecx\n"
s_pfx_i1:     .asciz "    addl $1, %ecx\n"
s_pfx_d4:     .asciz "    subl $4, %ecx\n"
s_pfx_d1:     .asciz "    subl $1, %ecx\n"
s_pfx_sti:    .asciz "    movl %ecx, (%eax)\n    pushl %ecx\n"
s_pfx_stc:    .asciz "    movb %cl, (%eax)\n    movzbl %cl, %ecx\n    pushl %ecx\n"
s_pst_old:    .asciz "    pushl %ecx\n"      # 后缀：先压旧值
s_pst_sti:    .asciz "    movl %ecx, (%eax)\n"
s_pst_stc:    .asciz "    movb %cl, (%eax)\n"
s_sect_data:  .asciz ".section .data\n"
s_sect_bss:   .asciz ".section .bss\n"
s_sect_ro:    .asciz ".section .rodata\n"
s_sect_text:  .asciz ".section .text\n"
s_al4:        .asciz "    .align 4\n"
s_gd_long:    .asciz "    .long "
s_gd_byte:    .asciz "    .byte "
s_gd_space:   .asciz "    .space "
s_gname_pre:  .asciz "g_"
s_str_lab:    .asciz "Lstr"
s_str_push:   .asciz "    pushl $Lstr"
s_scale_pre:  .asciz "    popl %ecx\n    popl %eax\n    imull $"
s_scale_mid:  .asciz ", %ecx, %ecx\n"
s_scale_add:  .asciz "    addl %ecx, %eax\n    pushl %eax\n"
s_scale_pre2: .asciz "    popl %ecx\n    popl %eax\n    imull $"
s_scale_mid2: .asciz ", %eax, %eax\n"
s_ret_char:   .asciz "    popl %eax\n    movzbl %al, %eax\n"

# ---- 生成程序运行时助手 + .bss（f_* 前缀以支持用户直接调用；print_str 为新增）----
s_runtime:  .asciz "f_print_decimal:\n    pushl %ebx\n    pushl %ecx\n    pushl %edx\n    pushl %esi\n    pushl %edi\n    test %eax, %eax\n    jns .Lpd_pos\n    movl %eax, %esi\n    movl $'-', %eax\n    call f_print_char\n    movl %esi, %eax\n    negl %eax\n.Lpd_pos:\n    movl %eax, %edi\n    leal runt_buf+15, %esi\n    movb $0, (%esi)\n.Lpd_loop:\n    movl %edi, %eax\n    xorl %edx, %edx\n    movl $10, %ebx\n    divl %ebx\n    movl %eax, %edi\n    addb $'0', %dl\n    decl %esi\n    movb %dl, (%esi)\n    test %edi, %edi\n    jnz .Lpd_loop\n    movl $4, %eax\n    movl $1, %ebx\n    movl %esi, %ecx\n    leal runt_buf+15, %edx\n    subl %esi, %edx\n    int $0x80\n    popl %edi\n    popl %esi\n    popl %edx\n    popl %ecx\n    popl %ebx\n    ret\n\nf_print_char:\n    pushl %eax\n    pushl %ebx\n    pushl %ecx\n    pushl %edx\n    leal runt_cbuf, %ecx\n    movb %al, (%ecx)\n    movl $1, %edx\n    movl $1, %ebx\n    movl $4, %eax\n    int $0x80\n    popl %edx\n    popl %ecx\n    popl %ebx\n    popl %eax\n    ret\n\nf_print_str:\n    pushl %ebp\n    movl %esp, %ebp\n    pushl %esi\n    pushl %edi\n    movl 8(%ebp), %esi\n.Lps_len:\n    cmpb $0, (%esi)\n    je .Lps_got\n    incl %esi\n    jmp .Lps_len\n.Lps_got:\n    movl %esi, %edi\n    subl 8(%ebp), %edi\n    movl %edi, %edx\n    movl 8(%ebp), %ecx\n    movl $1, %ebx\n    movl $4, %eax\n    int $0x80\n    popl %edi\n    popl %esi\n    movl %ebp, %esp\n    popl %ebp\n    ret\n\nf_exit:\n    pushl %ebp\n    movl %esp, %ebp\n    movl 8(%ebp), %ebx\n    movl $1, %eax\n    int $0x80\n\nf_print_int:\n    pushl %ebp\n    movl %esp, %ebp\n    pushl %ebx\n    pushl %ecx\n    pushl %edx\n    pushl %esi\n    pushl %edi\n    movl 8(%ebp), %eax\n    test %eax, %eax\n    jns .Lpi_pos\n    movl %eax, %esi\n    movl $'-', %eax\n    call f_print_char\n    movl %esi, %eax\n    negl %eax\n.Lpi_pos:\n    movl %eax, %edi\n    leal runt_buf+15, %esi\n    movb $0, (%esi)\n.Lpi_loop:\n    movl %edi, %eax\n    xorl %edx, %edx\n    movl $10, %ebx\n    divl %ebx\n    movl %eax, %edi\n    addb $'0', %dl\n    decl %esi\n    movb %dl, (%esi)\n    test %edi, %edi\n    jnz .Lpi_loop\n    movl $4, %eax\n    movl $1, %ebx\n    movl %esi, %ecx\n    leal runt_buf+15, %edx\n    subl %esi, %edx\n    int $0x80\n    popl %edi\n    popl %esi\n    popl %edx\n    popl %ecx\n    popl %ebx\n    movl %ebp, %esp\n    popl %ebp\n    ret\n\nf_print_err:\n    pushl %ebp\n    movl %esp, %ebp\n    pushl %esi\n    pushl %edi\n    movl 8(%ebp), %esi\n.Lpe_len:\n    cmpb $0, (%esi)\n    je .Lpe_got\n    incl %esi\n    jmp .Lpe_len\n.Lpe_got:\n    movl %esi, %edi\n    subl 8(%ebp), %edi\n    movl %edi, %edx\n    movl 8(%ebp), %ecx\n    movl $2, %ebx\n    movl $4, %eax\n    int $0x80\n    leal runt_cbuf, %ecx\n    movb $10, (%ecx)\n    movl $1, %edx\n    movl $2, %ebx\n    movl $4, %eax\n    int $0x80\n    popl %edi\n    popl %esi\n    movl %ebp, %esp\n    popl %ebp\n    ret\n\n.section .bss\nrunt_buf:  .space 16\nrunt_cbuf: .space 1\n"

# ---- 编译器自身工作内存（.bss） ----
.section .bss
in_buf:      .space 131073       # B2 前置：源码读入上限 4096→65536（boot0.pgc 超 4KB）；E9：P4-II 剩余特性 boot0.pgc 增至 66KB+，截断引发字符串"未闭合"误报 → 上限 65536→131072
input_start: .long 0
tok_kind:    .long 0
tok_ival:    .long 0
tok_start:   .long 0
tok_len:     .long 0
# 符号表：变量/参数（含类型）
sym_name:    .space MAX_SYM*MAX_NAMELEN
sym_off:     .space MAX_SYM*4
sym_tbase:   .space MAX_SYM*4
sym_tptr:    .space MAX_SYM*4
sym_anum:    .space MAX_SYM*4
sym_count:   .long 0
fn_nparams:  .long 0          # 当前函数参数个数（局部槽偏移基数）
local_bytes: .long 0          # 当前函数已分配局部栈字节（数组也计入）
# 函数表（含返回类型）
func_name:   .space MAX_FUNC*MAX_NAMELEN
func_tbase:  .space MAX_FUNC*4
func_tptr:   .space MAX_FUNC*4
func_count:  .long 0
cur_ftbase:  .long 0          # 当前函数返回类型
cur_fptr:    .long 0
# 全局符号表
gs_name:     .space MAX_GLB*MAX_NAMELEN
gs_tbase:    .space MAX_GLB*4
gs_tptr:     .space MAX_GLB*4
gs_anum:     .space MAX_GLB*4
gs_count:    .long 0
# 字符串常量表（64×256）
str_tab:     .space MAX_STR*256
str_count:   .long 0
str_buf:     .space 260       # 词法解码缓冲
# 表达式结果类型 / 左值性 / 左值模式
cur_tbase:   .long 0
cur_tptr:    .long 0
cur_anum:    .long 0
cur_lval:    .long 0
lval_mode:   .long 0
dc_tbase:    .long 0          # parse_decl 当前声明类型（跨声明符保留）
par_tbase:   .long 0          # parse_func 当前参数类型（内存槽传递）
par_tptr:    .long 0
tmp_ptr:     .long 0          # 声明符指针层级计数（内存槽，防 next_token 破坏）
pd_anum:     .long 0          # 声明符数组元素数（同上）
pd_tbase:    .long 0          # parse_global_decl 声明类型 tbase（内存槽，防 helper 破坏 %edi）
pt_func:     .long 0          # parse_top 顶层决策：1=函数 0=全局（防 lexer 破坏寄存器）
call_rtbase: .long 0          # 调用点函数返回类型（内存槽，跨发码保存）
call_rtptr:  .long 0
# 循环控制标号栈
loop_cont:   .space MAX_LOOP*4
loop_brk:    .space MAX_LOOP*4
loop_depth:  .long 0
scratch_name:.space MAX_NAMELEN+1
pk_depth:    .long 0
pk_kind:     .space 8*4
pk_ival:     .space 8*4
pk_start:    .space 8*4
pk_len:      .space 8*4
pk_cur:      .space 8*4
blk_mark:    .space MAX_BLK*4   # 块作用域：sym_count 标记
blk_mbytes:  .space MAX_BLK*4   # 块作用域：local_bytes 标记
blk_depth:   .long 0
scope_base:  .long 0
label_cnt:   .long 0
out_len:     .long 0
out_line:    .space 128
dec_buf:     .space 16
gd_bytes:    .long 0            # 当前全局数据类型（emit 用：1=char）
arg_count:   .long 0
scan_depth:  .long 0
scan_idx:    .long 0
scan_end:    .long 0
arg_pos:     .space 16*4

.section .text
.globl _start
_start:
    movl $3, %eax
    xorl %ebx, %ebx
    leal in_buf, %ecx
    movl $131072, %edx
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
    # 预注入运行时内建函数（f_print_decimal / f_print_char / f_print_str / f_print_int /
    #                    f_print_err / f_exit，均返回 void）
    call builtin_reg
    call next_token
    call parse_top            # func* | global-decl*
    call func_has_main
    testl %eax, %eax
    jz Lsyn_err
    # B2-P0（v4.1）：头部/尾部发码移至此——须等全局声明解析完成，才能按 gs_* 判定
    #   保留全局 src_buf/src_len（S2 stdin 预读）与 pg_quiet（S3 rc 打印开关）。
    call emit_prog_head       # .section .text/_start + 条件 stdin 预读 + call f_main
    call emit_prog_epi        # rc 打印（pg_quiet 条件跳过）+ exit
    call emit_runtime         # s_runtime 超长，分块发码（防 out_line 溢出）
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

# ================= 程序结构：func* | global-decl* =================
parse_top:
.pt_top:
    movl tok_kind, %eax
    cmpl $TOK_END, %eax
    je .Lpt_done
    cmpl $TOK_VOID, %eax
    je .Lpt_func            # void 只能作函数返回类型
    cmpl $TOK_INT, %eax
    je .Lpt_tdec
    cmpl $TOK_CHAR, %eax
    je .Lpt_tdec
    jmp Lsyn_err            # 顶层只允许函数定义或全局声明
.Lpt_tdec:
    # int/char 后（可跳过返回指针星号）：IDENT + '(' → 函数；否则 → 全局声明
    # 决策存内存槽（lexer 关键字号派发会破坏 %edx）
    movl $0, pt_func
    movl $0, %ecx              # 已 peek 层数
.Lpt_stars:
    call peek_token
    incl %ecx
    movl tok_kind, %eax
    cmpl $TOK_STAR, %eax
    je .Lpt_stars              # 返回指针星号（继续前瞻）
    cmpl $TOK_IDENT, %eax
    jne Lsyn_err
    call peek_token
    incl %ecx
    movl tok_kind, %eax
    cmpl $TOK_LPAREN, %eax
    je .Lpt_func1
    jmp .Lpt_restore
.Lpt_func1:
    movl $1, pt_func
.Lpt_restore:
    movl %ecx, %edi
.Lpt_res:
    testl %edi, %edi
    jz .Lpt_res_done
    call restore_token
    decl %edi
    jmp .Lpt_res
.Lpt_res_done:
    cmpl $1, pt_func
    je .Lpt_func
    call parse_global_decl
    jmp .pt_top
.Lpt_func:
    call parse_func
    jmp .pt_top
.Lpt_done:
    ret

# builtin_reg: 把运行时助手注进函数表（name, tbase=T_VOID, tptr=0）
#   v4.1（B2-P0 S1）新增 print_int / print_err / exit（均返回 void；cdecl 从调用栈取参）
builtin_reg:
    leal bi_print_dec, %ecx
    call builtin_add
    leal bi_print_char, %ecx
    call builtin_add
    leal bi_print_str, %ecx
    call builtin_add
    leal bi_print_int, %ecx
    call builtin_add
    leal bi_print_err, %ecx
    call builtin_add
    leal bi_exit, %ecx
    call builtin_add
    ret
builtin_add:            # %ecx = 名字符串地址
    pushl %esi
    pushl %edi
    movl func_count, %edi
    cmpl $MAX_FUNC, %edi
    jge Lsyn_err_bp
    shll $4, %edi
    leal func_name(%edi), %edi
    movl %ecx, %esi
    xorl %edx, %edx
.Lba_copy:
    movb (%esi,%edx), %al
    testb %al, %al
    jz .Lba_copyd
    movb %al, (%edi,%edx)
    incl %edx
    jmp .Lba_copy
.Lba_copyd:
    movb $0, (%edi,%edx)
    movl func_count, %eax
    movl $T_VOID, func_tbase(,%eax,4)
    movl $0, func_tptr(,%eax,4)
    incl func_count
    popl %edi
    popl %esi
    ret
Lsyn_err_bp:
    popl %edi
    popl %esi
    jmp Lsyn_err

# ================= 函数定义 =================
# parse_func: 当前 token = 返回类型关键字（INT/CHAR/VOID）
#   类型 := ('int'|'char'|'void') ('*')* IDENT '(' params ')' block
parse_func:
    movl tok_kind, %eax
    cmpl $TOK_VOID, %eax
    je .Lpf_void
    cmpl $TOK_CHAR, %eax
    je .Lpf_char
    movl $T_INT, cur_ftbase
    jmp .Lpf_have_t
.Lpf_void:
    movl $T_VOID, cur_ftbase
    jmp .Lpf_have_t
.Lpf_char:
    movl $T_CHAR, cur_ftbase
.Lpf_have_t:
    movl $0, cur_fptr
    call next_token
    # 返回指针（返回类型实现延伸 D3）
.Lpf_ptr_loop:
    movl tok_kind, %eax
    cmpl $TOK_STAR, %eax
    jne .Lpf_ptr_done
    cmpl $T_VOID, cur_ftbase
    je Lsyn_err              # void 不允许指针返回
    cmpl $2, cur_fptr
    jge Lsyn_err
    incl cur_fptr
    call next_token
    jmp .Lpf_ptr_loop
.Lpf_ptr_done:
    movl tok_kind, %eax
    cmpl $TOK_IDENT, %eax
    jne Lsyn_err
    call copy_name
    call func_find
    cmpl $-1, %eax
    jne Lsyn_err              # 重复定义 / 与内建重名
    call func_add
    # 发码标号 + 序言
    leal s_flabel1, %ecx
    call app_str
    leal scratch_name, %ecx
    call app_str
    leal s_flabel2, %ecx
    call app_str
    call emit_line
    # 函数上下文重置
    movl $0, sym_count
    movl $0, fn_nparams
    movl $0, local_bytes
    movl $0, blk_depth
    movl $0, scope_base
    movl $0, loop_depth
    call next_token           # → '('
    movl tok_kind, %eax
    cmpl $TOK_LPAREN, %eax
    jne Lsyn_err
    call next_token
    movl tok_kind, %eax
    cmpl $TOK_RPAREN, %eax
    je .Lpf_after_params
    cmpl $TOK_VOID, %eax
    jne .Lpf_param_loop
    # (void) 参数表
    call next_token
    movl tok_kind, %eax
    cmpl $TOK_RPAREN, %eax
    je .Lpf_after_params
    jmp Lsyn_err
.Lpf_param_loop:
    # 参数 := [type] ('*')* IDENT（类型/层级全走内存槽，防 next_token 破坏）
    movl $T_INT, par_tbase     # 默认 int（兼容 v2 裸名参数）
    movl $0, tmp_ptr
    movl tok_kind, %eax
    cmpl $TOK_INT, %eax
    je .Lpfp_typed
    cmpl $TOK_CHAR, %eax
    jne .Lpfp_ptr
    movl $T_CHAR, par_tbase
.Lpfp_typed:
    call next_token
.Lpfp_ptr:
    movl tok_kind, %eax
    cmpl $TOK_STAR, %eax
    jne .Lpfp_ident
    cmpl $2, tmp_ptr
    jge Lsyn_err
    incl tmp_ptr
    call next_token
    jmp .Lpfp_ptr
.Lpfp_ident:
    movl tok_kind, %eax
    cmpl $TOK_IDENT, %eax
    jne Lsyn_err
    movl tmp_ptr, %eax
    movl %eax, par_tptr
    call copy_name
    call declare_param        # 登记（off=8+4k；类型读 par_tbase/par_tptr）
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
    call parse_stmt_list
    movl tok_kind, %eax
    cmpl $TOK_RBRACE, %eax
    jne Lsyn_err
    call next_token
    leal s_func_epi, %ecx
    call emit_template
    ret

# ================= 语句列表 / 语句分派 =================
parse_stmt_list:
.Lpsl_top:
    movl tok_kind, %eax
    cmpl $TOK_RBRACE, %eax
    je .Lpsl_done
    call parse_stmt
    jmp .Lpsl_top
.Lpsl_done:
    ret

parse_stmt:
    movl tok_kind, %eax
    cmpl $TOK_INT, %eax
    je parse_decl
    cmpl $TOK_CHAR, %eax
    je parse_decl
    cmpl $TOK_VOID, %eax
    je Lsyn_err               # void 不能声明局部变量
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
    cmpl $TOK_DO, %eax
    je parse_do
    cmpl $TOK_BREAK, %eax
    je .Lpst_break
    cmpl $TOK_CONTINUE, %eax
    je .Lpst_continue
    call parse_assign
    movl tok_kind, %eax
    cmpl $TOK_SEMI, %eax
    jne Lsyn_err
    call next_token
    leal s_stmt_end, %ecx
    call emit_template
    ret
.Lpst_break:
    call emit_break
    call next_token
    movl tok_kind, %eax
    cmpl $TOK_SEMI, %eax
    jne Lsyn_err
    call next_token
    ret
.Lpst_continue:
    call emit_continue
    call next_token
    movl tok_kind, %eax
    cmpl $TOK_SEMI, %eax
    jne Lsyn_err
    call next_token
    ret
.Lpst_ret:
    call next_token
    cmpl $T_VOID, cur_ftbase
    jne .Lpst_ret_v
    # void 函数：return 无表达式
    movl tok_kind, %eax
    cmpl $TOK_SEMI, %eax
    jne Lsyn_err
    call next_token
    leal s_func_epi, %ecx
    call emit_template
    ret
.Lpst_ret_v:
    call parse_assign
    cmpl $T_VOID, cur_tbase
    je Lsyn_err               # void 值不能 return
    movl tok_kind, %eax
    cmpl $TOK_SEMI, %eax
    jne Lsyn_err
    call next_token
    cmpl $T_CHAR, cur_ftbase
    jne .Lpst_reti
    cmpl $0, cur_fptr
    jne .Lpst_reti            # 返回指针：不截断
    leal s_ret_char, %ecx
    call emit_template        # popl %eax; movzbl %al,%eax
    leal s_func_epi, %ecx
    call emit_template
    ret
.Lpst_reti:
    leal s_ret_seq, %ecx
    call emit_template
    ret

# ================= 声明（函数内局部；含类型/指针/数组/标量初始化） =================
parse_decl:
    # 当前 token = INT 或 CHAR
    movl tok_kind, %eax
    cmpl $TOK_CHAR, %eax
    jne 1f
    movl $T_CHAR, %eax
    jmp 2f
1:  movl $T_INT, %eax
2:  movl %eax, dc_tbase
    call next_token
.Lpd_decl:                      # 每个声明符（类型已定于 dc_tbase；跨声明符保留）
    movl $0, tmp_ptr            # 指针层级计数放内存槽（next_token 会破坏寄存器）
.Lpd_ptr:
    movl tok_kind, %eax
    cmpl $TOK_STAR, %eax
    jne .Lpd_ident
    cmpl $2, tmp_ptr
    jge Lsyn_err
    incl tmp_ptr
    call next_token
    jmp .Lpd_ptr
.Lpd_ident:
    movl tok_kind, %eax
    cmpl $TOK_IDENT, %eax
    jne Lsyn_err
    call copy_name
    call next_token              # 消费声明符标识符 → token = '[' / '=' / ',' / ';'
    movl $0, pd_anum
.Lpd_arr:
    movl tok_kind, %eax
    cmpl $TOK_LBKT, %eax
    jne .Lpd_narr
    cmpl $0, tmp_ptr
    jne Lsyn_err                # 复合声明符（int *a[3]）不在面（登记限制）
    call next_token
    movl tok_kind, %eax
    cmpl $TOK_NUM, %eax
    jne Lsyn_err
    movl tok_ival, %eax
    cmpl $0, %eax
    jle Lsyn_err
    cmpl $256, %eax
    ja Lsyn_err                 # N ≤ 256（局部数组 ≤1KB）
    movl %eax, pd_anum
    call next_token
    movl tok_kind, %eax
    cmpl $TOK_RBKT, %eax
    jne Lsyn_err
    call next_token              # 消费 ']' → token = '=' / ',' / ';'
.Lpd_narr:
    # 分配尺寸：数组 N×esz 取整到 4；标量 4B（N 在 pd_anum）
    cmpl $0, pd_anum
    jne .Lpd_asz
    movl $4, %ecx
    jmp .Lpd_areg
.Lpd_asz:
    movl dc_tbase, %eax
    cmpl $T_CHAR, %eax
    jne .Lpd_asz4
    movl pd_anum, %eax
    jmp .Lpd_arnd
.Lpd_asz4:
    movl pd_anum, %eax
    shll $2, %eax
.Lpd_arnd:
    addl $3, %eax
    andl $-4, %eax
    movl %eax, %ecx
.Lpd_areg:
    # 登记局部符号：off = -(local_bytes + size)；reg_local 入参原样回到 eax/ecx/edx/ebx
    pushl %ecx                  # size 存编译栈
    movl local_bytes, %eax
    movl 0(%esp), %ecx
    addl %ecx, %eax
    movl %eax, local_bytes
    negl %eax
    movl %eax, %ebx             # off
    movl dc_tbase, %eax
    movl tmp_ptr, %ecx
    movl pd_anum, %edx
    call reg_local
    popl %eax                   # size
    # 发码 "    subl $N, %esp"
    pushl %eax
    leal s_subl1, %ecx
    call app_str
    popl %eax
    call app_dec
    leal s_dealloc2, %ecx       # ", %esp\n"
    call app_str
    call emit_line
    # 局部初始化：'=' expr（仅标量/指针；数组→错误，登记限制）
    movl tok_kind, %eax
    cmpl $TOK_ASSIGN, %eax
    jne .Lpd_more
    cmpl $0, tmp_ptr
    jne Lsyn_err
    cmpl $0, pd_anum
    jne Lsyn_err
    call next_token
    call parse_assign
    cmpl $T_VOID, cur_tbase
    je Lsyn_err
    # 存入局部槽（popl %eax; movb/movl -off(%ebp)）
    movl sym_count, %ecx
    decl %ecx
    movl sym_off(,%ecx,4), %eax
    movl sym_tbase(,%ecx,4), %edx
    pushl %eax
    pushl %edx
    leal s_stmt_end, %ecx
    call emit_template
    popl %edx
    popl %eax
    cmpl $T_CHAR, %edx
    jne .Lpd_sti
    pushl %eax
    leal s_storel_c1, %ecx
    call app_str
    popl %eax
    call app_dec_signed
    leal s_storel_c2, %ecx
    call app_str
    call emit_line
    jmp .Lpd_more
.Lpd_sti:
    pushl %eax
    leal s_storel_i1, %ecx
    call app_str
    popl %eax
    call app_dec_signed
    leal s_storel_i2, %ecx
    call app_str
    call emit_line
.Lpd_more:
    movl tok_kind, %eax
    cmpl $TOK_COMMA, %eax
    je .Lpd_comma
    cmpl $TOK_SEMI, %eax
    jne Lsyn_err
    call next_token
    ret
.Lpd_comma:
    call next_token
    jmp .Lpd_decl

# ================= 全局声明 =================
# parse_global_decl: 当前 token = INT/CHAR（已确认为全局，非函数）
parse_global_decl:
    movl tok_kind, %eax
    cmpl $TOK_CHAR, %eax
    jne .Lpg_int
    movl $T_CHAR, %edi
    jmp .Lpg_tok
.Lpg_int:
    movl $T_INT, %edi
.Lpg_tok:
    movl %edi, pd_tbase        # tbase 落内存槽（后段不再依赖 %edi 跨 helper 存活）
    call next_token
.Lpg_vtop:
    movl $0, tmp_ptr            # 指针层级计数（内存槽）
.Lpg_ptr:
    movl tok_kind, %eax
    cmpl $TOK_STAR, %eax
    jne .Lpg_ident
    cmpl $2, tmp_ptr
    jge Lsyn_err
    incl tmp_ptr
    call next_token
    jmp .Lpg_ptr
.Lpg_ident:
    movl tok_kind, %eax
    cmpl $TOK_IDENT, %eax
    jne Lsyn_err
    call copy_name
    call next_token             # 消费声明符标识符 → token = '[' / '=' / ',' / ';'
    movl $0, pd_anum
.Lpg_arr:
    movl tok_kind, %eax
    cmpl $TOK_LBKT, %eax
    jne .Lpg_narr
    cmpl $0, tmp_ptr
    jne Lsyn_err                # 复合声明符
    call next_token
    movl tok_kind, %eax
    cmpl $TOK_NUM, %eax
    jne Lsyn_err
    movl tok_ival, %eax
    cmpl $0, %eax
    jle Lsyn_err
    movl %eax, pd_anum
    call next_token
    movl tok_kind, %eax
    cmpl $TOK_RBKT, %eax
    jne Lsyn_err
    call next_token
.Lpg_narr:
    cmpl $0, tmp_ptr
    je .Lpg_ok
    cmpl $0, pd_anum
    je .Lpg_ok
    jmp Lsyn_err                # 复合声明符
.Lpg_ok:
    # 与函数表 / 全局表重名检查
    pushl %edi
    movl tmp_ptr, %eax
    pushl %eax
    movl pd_anum, %eax
    pushl %eax
    call func_find
    cmpl $-1, %eax
    jne Lsyn_err
    call gs_find
    cmpl $-1, %eax
    jne Lsyn_err
    popl %eax                  # anum
    movl %eax, pd_anum
    popl %eax                  # tptr
    movl %eax, tmp_ptr
    popl %edi
    # 登记全局（tbase 从内存槽 pd_tbase 读，防 %edi 被 helper 漂移）
    movl pd_tbase, %eax
    movl tmp_ptr, %ecx
    cmpl $0, pd_anum
    je .Lpg_reg1
    cmpl $0, %ecx
    jne .Lpg_reg1
    movl $1, %ecx              # 数组（非指针）登记 tptr=1（衰减语义）
.Lpg_reg1:
    movl pd_anum, %edx
    movl $0, %ebx            # off 不用；占位
    call reg_global
    # 输出：.data（有初值）或 .bss（无初值）
    movl tok_kind, %eax
    cmpl $TOK_ASSIGN, %eax
    je .Lpg_init
    # 无初值 → .bss .space size
    leal s_sect_bss, %ecx
    call emit_template
    leal s_gname_pre, %ecx
    call app_str
    leal scratch_name, %ecx
    call app_str
    leal s_colon, %ecx
    call app_str
    call emit_line
    leal s_gd_space, %ecx
    call app_str
    # size：数组 N×esz（char=1；int/ptr=4）；标量 1/4
    cmpl $0, pd_anum
    je .Lpg_zscalar
    movl pd_anum, %eax
    movl pd_tbase, %ecx
    cmpl $T_CHAR, %ecx
    je .Lpg_zsize
    shll $2, %eax
    jmp .Lpg_zsize
.Lpg_zscalar:
    movl pd_tbase, %eax
    cmpl $T_CHAR, %eax
    jne .Lpg_z4
    movl $1, %eax
    jmp .Lpg_zsize
.Lpg_z4:
    movl $4, %eax
.Lpg_zsize:
    call app_dec
    leal s_nl, %ecx
    call app_str
    call emit_line
    leal s_sect_text, %ecx
    call emit_template
    jmp .Lpg_next
.Lpg_init:
    # 有初值 → .data
    leal s_sect_data, %ecx
    call emit_template
    leal s_gname_pre, %ecx
    call app_str
    leal scratch_name, %ecx
    call app_str
    leal s_colon, %ecx
    call app_str
    call emit_line
    # 初值形式：若 anum>0 → '{' 列表 / 字符串；否则标量（NUM/CHARLIT）
    cmpl $0, pd_anum
    jne .Lpg_inarr
    # 标量
    call next_token
    # 取标量值
    movl tok_kind, %eax
    cmpl $TOK_NUM, %eax
    je .Lpg_val_num
    cmpl $TOK_CHARLIT, %eax
    je .Lpg_val_num
    jmp Lsyn_err              # 标量全局初值须为常量
.Lpg_val_num:
    movl tok_ival, %eax
    pushl %eax               # 保护初值（app_str/emit 破坏 %eax）
    cmpl $T_CHAR, pd_tbase
    jne .Lpg_long
    leal s_gd_byte, %ecx
    call app_str
    popl %eax
    call app_dec
    leal s_nl, %ecx
    call app_str
    call emit_line
    call next_token          # 消费初值 token（标量路径此前漏消费）
    jmp .Lpg_data_done
.Lpg_long:
    popl %ebx                  # 初值携 %ebx（emit_template/app_str 破坏 %eax，不破坏 %ebx；D14）
    leal s_al4, %ecx
    call emit_template
    leal s_gd_long, %ecx
    call app_str
    movl %ebx, %eax
    call app_dec
    leal s_nl, %ecx
    call app_str
    call emit_line
    call next_token          # 消费初值 token
    jmp .Lpg_data_done
.Lpg_inarr:
    pushl pd_anum              # 栈：[..][N][tbase]
    pushl pd_tbase
    call next_token
    movl tok_kind, %eax
    cmpl $TOK_STRLIT, %eax
    je .Lpg_instr
    cmpl $TOK_LBRACE, %eax
    je .Lpg_inlist
    jmp Lsyn_err
.Lpg_instr:
    # 字符串初始化 char 数组：str_tab[index] 字节序列（不足补 0）；栈：[..][N][tbase]
    movl 0(%esp), %ebx         # tbase
    cmpl $T_CHAR, %ebx
    jne Lsyn_err              # 仅 char 数组可用字符串初值
    movl tok_ival, %ecx
    imull $256, %ecx, %ecx
    leal str_tab(%ecx), %ebx   # 遍历指针用 %ebx（%esi=输入游标不可破坏）
    movl 4(%esp), %edi         # N（edi 跨 app_* 安全）
.Lpg_instr_loop:
    cmpl $0, %edi
    je .Lpg_instr_done
    movzbl (%ebx), %eax
    pushl %ebx
    pushl %edi
    pushl %eax
    leal s_gd_byte, %ecx
    call app_str
    movl 0(%esp), %eax
    call app_dec
    leal s_nl, %ecx
    call app_str
    call emit_line
    popl %eax
    popl %edi
    popl %ebx
    incl %ebx
    decl %edi
    jmp .Lpg_instr_loop
.Lpg_instr_done:
    addl $8, %esp              # 弹 [N][tbase]
    call next_token            # 消费字符串字面量 token（此前漏消费）
    jmp .Lpg_data_done
.Lpg_inlist:
    # '{' 常量列表：值逐个 .long/.byte，计到 N 补 0；栈：[..][N][tbase]
    movl 0(%esp), %ebx         # tbase
    cmpl $T_INT, %ebx
    jne 1f
    leal s_al4, %ecx
    call emit_template
1:
    movl 4(%esp), %edi         # 剩余计数（edi 跨 app_* 安全）
    call next_token            # 消费 '{'
.Lpg_li_loop:
    cmpl $0, %edi
    je .Lpg_li_pad
    movl tok_kind, %eax
    cmpl $TOK_NUM, %eax
    je .Lpg_li_val
    cmpl $TOK_CHARLIT, %eax
    je .Lpg_li_val
    cmpl $TOK_RBRACE, %eax
    je .Lpg_li_end
    jmp Lsyn_err
.Lpg_li_val:
    movl 0(%esp), %ebx         # tbase
    pushl %ebx
    pushl %edi
    movl tok_ival, %eax
    pushl %eax
    leal s_gd_byte, %ecx
    cmpl $T_CHAR, %ebx
    je 2f
    leal s_gd_long, %ecx
2:  call app_str
    popl %eax
    call app_dec
    leal s_nl, %ecx
    call app_str
    call emit_line
    popl %edi
    popl %ebx
    decl %edi
    call next_token
    movl tok_kind, %eax
    cmpl $TOK_COMMA, %eax
    je 3f
    cmpl $TOK_RBRACE, %eax
    jne Lsyn_err
    jmp .Lpg_li_end
3:  call next_token
    jmp .Lpg_li_loop
.Lpg_li_pad:
    movl 0(%esp), %ebx         # tbase
    pushl %ebx
    pushl %edi
    leal s_gd_byte, %ecx
    cmpl $T_CHAR, %ebx
    je 4f
    leal s_gd_long, %ecx
4:  call app_str
    call app_dec0
    leal s_nl, %ecx
    call app_str
    call emit_line
    popl %edi
    popl %ebx
    decl %edi
    cmpl $0, %edi
    jg .Lpg_li_pad
    jmp .Lpg_li_done
.Lpg_li_end:
    cmpl $0, %edi
    jg .Lpg_li_pad
.Lpg_li_done:
    addl $8, %esp              # 弹 [N][tbase]
    call next_token            # 消费 '}'
.Lpg_data_done:
    leal s_sect_text, %ecx
    call emit_template
.Lpg_next:
    movl tok_kind, %eax
    cmpl $TOK_COMMA, %eax
    jne .Lpg_semi
    call next_token
    jmp .Lpg_vtop
.Lpg_semi:
    cmpl $TOK_SEMI, %eax
    jne Lsyn_err
    call next_token
    ret

app_dec0:                   # 输出 0
    pushl %eax
    pushl %esi
    pushl %ebp
    movl $'0', %eax
    call app_char
    popl %ebp
    popl %esi
    popl %eax
    ret

# ================= 块语句（块作用域 + 栈回收） =================
parse_block:
    movl blk_depth, %ecx
    cmpl $MAX_BLK, %ecx
    jge Lsyn_err
    movl sym_count, %eax
    movl %eax, blk_mark(,%ecx,4)
    movl local_bytes, %eax
    movl %eax, blk_mbytes(,%ecx,4)
    incl blk_depth
    movl sym_count, %eax
    movl %eax, scope_base
    call next_token
    call parse_stmt_list
    movl tok_kind, %eax
    cmpl $TOK_RBRACE, %eax
    jne Lsyn_err
    # 出块：回收块内声明栈字节（local_bytes 差），符号表弹回
    movl local_bytes, %edi
    movl blk_depth, %ecx
    decl %ecx
    subl blk_mbytes(,%ecx,4), %edi
    testl %edi, %edi
    jz .Lpb_noalloc
    leal s_dealloc, %ecx
    call app_str
    movl %edi, %eax
    call app_dec
    leal s_dealloc2, %ecx
    call app_str
    call emit_line
.Lpb_noalloc:
    decl blk_depth
    movl blk_depth, %ecx
    movl blk_mbytes(,%ecx,4), %eax
    movl %eax, local_bytes
    movl blk_depth, %ecx
    movl blk_mark(,%ecx,4), %eax
    movl %eax, sym_count
    testl %ecx, %ecx
    jz .Lpb_base0
    movl %ecx, %eax
    decl %eax
    movl blk_mark(,%eax,4), %eax
    movl %eax, scope_base
    jmp .Lpb_after
.Lpb_base0:
    movl $0, scope_base
.Lpb_after:
    call next_token
    ret

# ================= 循环控制 =================
# push_loop(cont, brk)：把两个标号压 loop 栈
push_loop:
    movl loop_depth, %ecx
    cmpl $MAX_LOOP, %ecx
    jge Lsyn_err
    movl 4(%esp), %eax        # cont
    movl %eax, loop_cont(,%ecx,4)
    movl 8(%esp), %eax        # brk
    movl %eax, loop_brk(,%ecx,4)
    incl loop_depth
    ret                       # 参数由调用方 addl $8 清理
pop_loop:
    decl loop_depth
    ret
emit_break:
    movl loop_depth, %ecx
    testl %ecx, %ecx
    jz Lsyn_err
    decl %ecx
    movl loop_brk(,%ecx,4), %eax
    call emit_jmp
    ret
emit_continue:
    movl loop_depth, %ecx
    testl %ecx, %ecx
    jz Lsyn_err
    decl %ecx
    movl loop_cont(,%ecx,4), %eax
    call emit_jmp
    ret

# ================= if 语句 =================
parse_if:
    call next_token
    movl tok_kind, %eax
    cmpl $TOK_LPAREN, %eax
    jne Lsyn_err
    call next_token
    call parse_assign
    cmpl $T_VOID, cur_tbase
    je Lsyn_err
    movl tok_kind, %eax
    cmpl $TOK_RPAREN, %eax
    jne Lsyn_err
    call next_token
    movl label_cnt, %eax
    pushl %eax
    addl $2, label_cnt
    leal s_cnd_test, %ecx
    call emit_template
    movl 0(%esp), %eax
    call emit_jz
    call parse_stmt
    movl tok_kind, %eax
    cmpl $TOK_ELSE, %eax
    je .Lpi_else
    movl 0(%esp), %eax
    call emit_label
    popl %eax
    ret
.Lpi_else:
    movl 0(%esp), %eax
    addl $1, %eax
    call emit_jmp
    movl 0(%esp), %eax
    call emit_label
    call next_token
    call parse_stmt
    movl 0(%esp), %eax
    addl $1, %eax
    call emit_label
    popl %eax
    ret

# ================= while 语句 =================
parse_while:
    call next_token
    movl tok_kind, %eax
    cmpl $TOK_LPAREN, %eax
    jne Lsyn_err
    movl label_cnt, %eax
    pushl %eax
    addl $2, label_cnt
    movl 0(%esp), %eax
    call emit_label
    # 循环控制：cont=LW brk=LW+1
    movl 0(%esp), %edx
    movl %edx, %eax
    addl $1, %eax
    movl %edx, %ecx
    pushl %eax
    pushl %ecx
    call push_loop
    addl $8, %esp              # 清理 push_loop 两参
    call next_token
    call parse_assign
    cmpl $T_VOID, cur_tbase
    je Lsyn_err
    movl tok_kind, %eax
    cmpl $TOK_RPAREN, %eax
    jne Lsyn_err
    call next_token
    leal s_cnd_test, %ecx
    call emit_template
    movl 0(%esp), %eax
    addl $1, %eax
    call emit_jz
    call parse_stmt
    movl 0(%esp), %eax
    call emit_jmp
    movl 0(%esp), %eax
    addl $1, %eax
    call emit_label
    call pop_loop
    popl %eax
    ret

# ================= for 语句 =================
parse_for:
    call next_token
    movl tok_kind, %eax
    cmpl $TOK_LPAREN, %eax
    jne Lsyn_err
    movl label_cnt, %eax
    pushl %eax
    addl $3, label_cnt
    # 循环控制：cont=LB+1（inc） brk=LB+2
    movl 0(%esp), %edx
    leal 2(%edx), %eax
    leal 1(%edx), %ecx
    pushl %eax
    pushl %ecx
    call push_loop
    addl $8, %esp              # 清理 push_loop 两参
    call next_token
    # init（';' 结束）
    movl tok_kind, %eax
    cmpl $TOK_SEMI, %eax
    je .Lpfo_init_empty
    call parse_assign
    cmpl $T_VOID, cur_tbase
    je Lsyn_err
    movl tok_kind, %eax
    cmpl $TOK_SEMI, %eax
    jne Lsyn_err
    call next_token
    leal s_stmt_end, %ecx
    call emit_template
    jmp .Lpfo_cond
.Lpfo_init_empty:
    call next_token
.Lpfo_cond:
    movl 0(%esp), %eax
    call emit_label
    movl tok_kind, %eax
    cmpl $TOK_SEMI, %eax
    je .Lpfo_cond_empty
    call parse_assign
    cmpl $T_VOID, cur_tbase
    je Lsyn_err
    movl tok_kind, %eax
    cmpl $TOK_SEMI, %eax
    jne Lsyn_err
    call next_token
    leal s_cnd_test, %ecx
    call emit_template
    movl 0(%esp), %eax
    addl $2, %eax
    call emit_jz
    jmp .Lpfo_inc
.Lpfo_cond_empty:
    call next_token
.Lpfo_inc:
    movl tok_start, %eax
    pushl %eax
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
    pushl %eax
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
    movl 0(%esp), %eax
    leal 1(%eax), %esi
    call next_token
.Lpfo_body:
    call parse_stmt
    call peek_token
    movl 8(%esp), %eax
    addl $1, %eax
    call emit_label
    movl 4(%esp), %eax
    cmpl 0(%esp), %eax
    je .Lpfo_inc_skip
    movl %eax, %esi
    call next_token
    call parse_assign
    cmpl $T_VOID, cur_tbase
    je Lsyn_err
    movl tok_kind, %eax
    cmpl $TOK_RPAREN, %eax
    jne Lsyn_err
    leal s_stmt_end, %ecx
    call emit_template
.Lpfo_inc_skip:
    call restore_token
    movl 8(%esp), %eax
    call emit_jmp
    movl 8(%esp), %eax
    addl $2, %eax
    call emit_label
    call pop_loop
    addl $12, %esp
    ret

# ================= do-while 语句 =================
parse_do:
    call next_token
    movl label_cnt, %eax
    pushl %eax                # LD（cont=LD+1；brk=LD+2）
    addl $3, label_cnt
    movl 0(%esp), %eax
    call emit_label           # LD:
    movl 0(%esp), %edx
    leal 2(%edx), %eax
    leal 1(%edx), %ecx
    pushl %eax
    pushl %ecx
    call push_loop
    addl $8, %esp              # 清理 push_loop 两参
    call parse_stmt           # body
    movl tok_kind, %eax
    cmpl $TOK_WHILE, %eax
    jne Lsyn_err
    call next_token
    movl tok_kind, %eax
    cmpl $TOK_LPAREN, %eax
    jne Lsyn_err
    call next_token
    movl 0(%esp), %eax
    addl $1, %eax
    call emit_label           # LC:（cont 点）
    call parse_assign         # cond
    cmpl $T_VOID, cur_tbase
    je Lsyn_err
    movl tok_kind, %eax
    cmpl $TOK_RPAREN, %eax
    jne Lsyn_err
    call next_token
    movl tok_kind, %eax
    cmpl $TOK_SEMI, %eax
    jne Lsyn_err
    call next_token
    leal s_cnd_test, %ecx
    call emit_template
    movl 0(%esp), %eax        # jnz LD
    call emit_jnz
    call pop_loop
    popl %eax
    ret

# ================= 赋值 / 表达式 =================
# assign := lval (OPASS|ASN) assign | logic
# 实现（D1）：is_assign_ahead 扫描原文判定有无顶层赋值算子；
#   有 → lval_mode=1 解析左值（得地址）→ 处理赋值/复合赋值；
#   无 → 常规 parse_logic。
parse_assign:
    call is_assign_ahead
    testl %eax, %eax
    jz .Lpas_logic
    # ------- 赋值路径 -------
    movl $1, lval_mode
    call parse_unary           # 左值 → TOS=地址；cur 为左值类型
    movl $0, lval_mode
    call parse_unary_fin       # 处理 [ ] 后缀链（左值模式）
    movl cur_lval, %eax
    testl %eax, %eax
    jz Lsyn_err                # 非左值（3=4、(a+b)=5 等）
    movl tok_kind, %eax
    cmpl $TOK_ASSIGN, %eax
    je .Lpas_assign
    cmpl $TOK_OPADD, %eax
    je .Lpas_com
    cmpl $TOK_OPSUB, %eax
    je .Lpas_com
    cmpl $TOK_OPMUL, %eax
    je .Lpas_com
    cmpl $TOK_OPDIV, %eax
    je .Lpas_com
    jmp Lsyn_err               # 扫描承诺过赋值算子；否则语法错误
.Lpas_assign:
    cmpl $0, cur_anum
    jne Lsyn_err               # 数组整体赋值 → 错误
    movl tok_kind, %eax
    pushl %eax                 # 存 op（=ASSIGN）
    # 保存左值类型（tbase/tptr）到编译栈
    pushl cur_tbase
    pushl cur_tptr
    cmpl $T_VOID, cur_tbase
    je Lsyn_err
    call next_token
    call parse_assign          # 右值（值在 TOS）
    cmpl $T_VOID, cur_tbase
    je Lsyn_err                # void 值不可赋值
    popl %ecx                  # 目标 tptr
    popl %edx                  # 目标 tbase
    popl %eax                  # op
    # 写回宽度：char 仅限标量（tptr==0）；指针/数组元素 4B
    cmpl $T_CHAR, %edx
    jne .Lpas_wb_int
    cmpl $0, %ecx
    jne .Lpas_wb_int
    leal s_wb_char, %ecx
    call emit_template
    jmp .Lpas_cur
.Lpas_wb_int:
    leal s_wb_int, %ecx
    call emit_template
.Lpas_cur:
    movl %edx, cur_tbase
    movl %ecx, cur_tptr
    movl $0, cur_lval
    movl $0, cur_anum
    ret
.Lpas_com:
    # 复合赋值：+= -= *= /=（类型/op 从编译栈槽位读，防 emit_template 破坏寄存器）
    cmpl $0, cur_anum
    jne Lsyn_err
    movl tok_kind, %eax
    pushl %eax                 # [op]
    pushl cur_tbase            # [op][tbase]
    pushl cur_tptr             # [op][tbase][tptr]
    cmpl $T_VOID, cur_tbase
    je Lsyn_err
    call next_token
    call parse_assign          # 右值（值在 TOS）
    cmpl $T_VOID, cur_tbase
    je Lsyn_err
    # 发码：pre（edx=rhs ecx=addr 存栈）+ load old + op + store
    leal s_com_pre, %ecx
    call emit_template
    # load old（0=tptr 4=tbase 8=op；char 仅限标量 tptr==0）
    cmpl $T_CHAR, 4(%esp)
    jne .Lpas_com_ldi
    cmpl $0, 0(%esp)
    jne .Lpas_com_ldi
    leal s_com_ldc, %ecx
    call emit_template
    jmp .Lpas_com_op
.Lpas_com_ldi:
    leal s_com_ldi, %ecx
    call emit_template
.Lpas_com_op:
    movl 8(%esp), %eax         # op（重新读，防 clobber）
    cmpl $TOK_OPADD, %eax
    je .Lpas_opadd
    cmpl $TOK_OPSUB, %eax
    je .Lpas_opsub
    cmpl $TOK_OPMUL, %eax
    je .Lpas_opmul
    leal s_com_div, %ecx
    call emit_template
    jmp .Lpas_com_st
.Lpas_opadd:
    leal s_com_add, %ecx
    call emit_template
    jmp .Lpas_com_st
.Lpas_opsub:
    leal s_com_sub, %ecx
    call emit_template
    jmp .Lpas_com_st
.Lpas_opmul:
    leal s_com_mul, %ecx
    call emit_template
.Lpas_com_st:
    cmpl $T_CHAR, 4(%esp)
    jne .Lpas_com_sti
    cmpl $0, 0(%esp)
    jne .Lpas_com_sti
    leal s_com_stc, %ecx
    call emit_template
    jmp .Lpas_com_cur
.Lpas_com_sti:
    leal s_com_sti, %ecx
    call emit_template
.Lpas_com_cur:
    movl 4(%esp), %edx         # tbase
    movl 0(%esp), %ecx         # tptr
    addl $12, %esp             # 弹 [op][tbase][tptr]
    movl %edx, cur_tbase
    movl %ecx, cur_tptr
    movl $0, cur_lval
    movl $0, cur_anum
    ret
.Lpas_logic:
    call parse_logic
    ret

# parse_unary_fin: 处理 lval 模式下的后缀链 —— 实际由 parse_unary→parse_postfix 完成。
#   这里仅为占位（见 parse_postfix）；调用方直接继续。
parse_unary_fin:
    ret

# is_assign_ahead: 从 tok_start 原始文本扫描，判定语句/表达式区域内（到 ';' 或
#   深度0 的 ')'/'，' 前）是否存在顶层 '='/复合赋值算子（跳过注释/引号字符区）。
#   → %eax = 1/0
is_assign_ahead:
    pushl %esi
    pushl %ebx
    pushl %edi
    movl tok_start, %esi
    movl $0, %edi              # %edi = 括号深度
.Liaa_loop:
    movzbl (%esi), %eax
    testl %eax, %eax
    jz .Liaa_no
    cmpb $';', %al
    je .Liaa_stop0
    cmpb $')', %al
    je .Liaa_stop1
    cmpb $',', %al
    je .Liaa_stop0
    cmpb $'(', %al
    je .Liaa_open
    cmpb $'[', %al
    je .Liaa_open
    cmpb $']', %al
    je .Liaa_close
    cmpb $'/', %al
    jne .Liaa_s1
    cmpb $'*', 1(%esi)
    jne .Liaa_s1
    # 注释：跳到 '*/'
.Liaa_comm:
    addl $2, %esi
    movzbl (%esi), %ecx
    testl %ecx, %ecx
    jz .Liaa_no              # 未闭合注释 → 当作无赋值（后续词法报错）
    cmpb $'*', %cl
    jne .Liaa_comm
    cmpb $'/', 1(%esi)
    jne .Liaa_comm_adv
    addl $2, %esi
    jmp .Liaa_loop
.Liaa_comm_adv:
    incl %esi
    jmp .Liaa_comm
.Liaa_s1:
    cmpb $'\'', %al
    je .Liaa_quote1
    cmpb $'"', %al
    je .Liaa_quote1
    cmpb $'=', %al
    je .Liaa_eq
    cmpb $'+', %al
    je .Liaa_plus
    cmpb $'-', %al
    je .Liaa_plus
    cmpb $'*', %al
    je .Liaa_star
    incl %esi
    jmp .Liaa_loop
.Liaa_stop0:
    cmpl $0, %edi
    jne .Liaa_adv_stop
.Liaa_S0:
    jmp .Liaa_no
.Liaa_adv_stop:
    incl %esi
    jmp .Liaa_loop
.Liaa_stop1:
    cmpl $0, %edi
    jne .Liaa_close
    jmp .Liaa_no
.Liaa_open:
    incl %edi
    incl %esi
    jmp .Liaa_loop
.Liaa_close:
    testl %edi, %edi
    jz .Liaa_no
    decl %edi
    incl %esi
    jmp .Liaa_loop
.Liaa_quote1:                 # (%esi) 是开引号；扫描到同名闭引号并越过（处理反斜杠转义）
    incl %esi
.Liaa_qloop:
    movzbl (%esi), %ecx
    testl %ecx, %ecx
    jz .Liaa_no               # 未闭合 → 当作无赋值（后续词法报错）
    cmpb $'\\', %cl
    jne .Liaa_qn
    addl $2, %esi             # 转义对 \X 整体跳过
    jmp .Liaa_qloop
.Liaa_qn:
    cmpb %al, %cl             # 闭引号？
    je .Liaa_qend
    incl %esi
    jmp .Liaa_qloop
.Liaa_qend:
    incl %esi                 # 越过闭引号
    jmp .Liaa_loop
.Liaa_eq:                     # '='：== 跳过；前导 < > ! 跳过（<= >= !=）；否则顶层 → 有赋值
    cmpb $'=', 1(%esi)
    je .Liaa_skip2
    cmpb $'<', -1(%esi)
    je .Liaa_skip1
    cmpb $'>', -1(%esi)
    je .Liaa_skip1
    cmpb $'!', -1(%esi)
    je .Liaa_skip1
    cmpl $0, %edi
    jne .Liaa_skip1
    .Liaa_Y1:
    jmp .Liaa_yes
.Liaa_plus:                   # '+'/'-'：'++'跳过；'='顶层 → 有赋值
    cmpb $'+', 1(%esi)
    je .Liaa_skip2
    cmpb $'-', 1(%esi)
    je .Liaa_skip2
    cmpb $'=', 1(%esi)
    je .Liaa_eqchk
    incl %esi
    jmp .Liaa_loop
.Liaa_eqchk:
    cmpl $0, %edi
    jne .Liaa_skip2
    jmp .Liaa_yes
.Liaa_star:
    cmpb $'=', 1(%esi)
    jne .Liaa_skip1
    cmpl $0, %edi
    jne .Liaa_skip2
    jmp .Liaa_yes
.Liaa_skip2:
    addl $2, %esi
    jmp .Liaa_loop
.Liaa_skip1:
    incl %esi
    jmp .Liaa_loop
.Liaa_yes:
    movl $1, %eax
    jmp .Liaa_ret
.Liaa_no:
    xorl %eax, %eax
.Liaa_ret:
    popl %edi
    popl %ebx
    popl %esi
    ret

# ================= 逻辑（短路） =================
# logic := cmp (('&&'|'||') cmp)*
parse_logic:
    call parse_cmp
.Lpl_top:
    movl tok_kind, %eax
    cmpl $TOK_LOGAND, %eax
    je .Lpl_op
    cmpl $TOK_LOGOR, %eax
    je .Lpl_op
    ret
.Lpl_op:
    pushl %eax                 # op
    # 标号：Lf/Lt = label_cnt；Le = label_cnt+1
    movl label_cnt, %eax
    pushl %eax
    addl $2, label_cnt
    movl 0(%esp), %eax         # Lf
    movl 4(%esp), %ecx         # op
    cmpl $TOK_LOGAND, %ecx
    jne .Lpl_or
    # &&：左值 test/jz Lf
    leal s_cnd_test, %ecx
    call emit_template
    movl 0(%esp), %eax
    call emit_jz
    jmp .Lpl_rhs
.Lpl_or:
    # ||：左值 test/jnz Lt
    leal s_cnd_test, %ecx
    call emit_template
    movl 0(%esp), %eax
    call emit_jnz
.Lpl_rhs:
    call next_token
    call parse_cmp
    # 右值 test；然后结果 0/1 与跳转
    movl 0(%esp), %eax         # Lf/Lt
    movl 4(%esp), %ecx         # op
    cmpl $TOK_LOGAND, %ecx
    jne .Lpl_or2
    leal s_cnd_test, %ecx
    call emit_template
    movl 0(%esp), %eax
    call emit_jz
    # push 1; jmp Le; Lf: push 0; Le:
    leal s_pl_1, %ecx
    call emit_template
    movl 0(%esp), %eax
    addl $1, %eax
    call emit_jmp
    movl 0(%esp), %eax
    call emit_label
    leal s_pl_0, %ecx
    call emit_template
    movl 0(%esp), %eax
    addl $1, %eax
    call emit_label
    jmp .Lpl_done
.Lpl_or2:
    leal s_cnd_test, %ecx
    call emit_template
    movl 0(%esp), %eax
    call emit_jnz
    leal s_pl_0, %ecx
    call emit_template
    movl 0(%esp), %eax
    addl $1, %eax
    call emit_jmp
    movl 0(%esp), %eax
    call emit_label
    leal s_pl_1, %ecx
    call emit_template
    movl 0(%esp), %eax
    addl $1, %eax
    call emit_label
.Lpl_done:
    addl $8, %esp              # 弹 [Lf][op]
    movl $T_INT, cur_tbase
    movl $0, cur_tptr
    movl $0, cur_lval
    movl $0, cur_anum
    jmp .Lpl_top

# ================= 比较（同 v3） =================
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
    pushl %eax
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
    movl $T_INT, cur_tbase
    movl $0, cur_tptr
    movl $0, cur_lval
    movl $0, cur_anum
    jmp .Lpcmp_top

# ================= 加减（含指针伸缩） =================
# expr := term (('+'|'-') term)*；某侧为指针时另一侧按 esz 伸缩（esz：char* 为 1，其余 4）
parse_expr:
    call parse_term
    pushl cur_tbase             # 栈：[..][左tbase][左tptr]
    pushl cur_tptr
.Lpe_top:
    movl tok_kind, %eax
    cmpl $TOK_PLUS, %eax
    je .Lpe_op
    cmpl $TOK_MINUS, %eax
    je .Lpe_op
    jmp .Lpe_done
.Lpe_op:
    pushl %eax                 # op（在左类型对之上：0=op 4=左tptr 8=左tbase）
    call next_token
    call parse_term
    movl cur_tbase, %eax       # 右 tbase
    movl cur_tptr, %ebx        # 右 tptr
    movl 0(%esp), %ecx         # op（只读不弹，类型对留栈给 .Lpe_done）
    movl 4(%esp), %edx         # 左 tptr
    movl 8(%esp), %ebp         # 左 tbase
    # 指针判定一律看 tptr（tbase==T_INT 也可能是指针）
    cmpl $0, %edx
    je .Lpe_lnotptr
    cmpl $0, %ebx
    jne .Lpe_pp                # 指针+指针
    # 左指针：右操作数按 esz(左) 伸缩
    cmpl $1, %edx
    jne .Lpe_esz4
    cmpl $T_CHAR, %ebp
    jne .Lpe_esz4
    movl $1, %edi
    jmp .Lpe_scale_le
.Lpe_esz4:
    movl $4, %edi
.Lpe_scale_le:
    pushl %edi                 # [..][左tbase][左tptr][op][esz]
    leal s_scale_pre, %ecx
    call app_str
    popl %eax
    call app_dec
    leal s_scale_mid, %ecx
    call app_str
    leal s_scale_add, %ecx
    call app_str
    call emit_line
    addl $8, %esp              # 弹 [op][esz]（类型对留栈）
    movl %ebp, cur_tbase
    movl %edx, cur_tptr
    jmp .Lpe_cur_cont
.Lpe_lnotptr:
    cmpl $0, %ebx
    je .Lpe_plain
    cmpl $TOK_MINUS, %ecx
    je Lsyn_err                # 指针 - 指针 → 不支持
    # 右指针（i+p）：左按 esz(右) 伸缩；结果=右类型
    cmpl $1, %ebx
    jne .Lpe_esz4_b
    cmpl $T_CHAR, %eax
    jne .Lpe_esz4_b
    movl $1, %edi
    jmp .Lpe_scale_re
.Lpe_esz4_b:
    movl $4, %edi
.Lpe_scale_re:
    movl %eax, cur_tbase       # 结果=右指针类型（先落内存，防 app_* 破坏）
    movl %ebx, cur_tptr
    pushl %edi                 # [..][左tbase][左tptr][op][esz]
    leal s_scale_pre2, %ecx
    call app_str
    popl %eax
    call app_dec
    leal s_scale_mid2, %ecx
    call app_str
    leal s_scale_add, %ecx
    call app_str
    call emit_line
    addl $8, %esp              # 弹 [op][esz]
    jmp .Lpe_cur_cont
.Lpe_plain:
    cmpl $TOK_PLUS, %ecx
    jne .Lpe_psub
    leal op_add, %ecx
    jmp .Lpe_pemit
.Lpe_psub:
    leal op_sub, %ecx
.Lpe_pemit:
    call emit_template
    movl $T_INT, cur_tbase
    movl $0, cur_tptr
    addl $4, %esp              # 弹 op（类型对留栈）
    jmp .Lpe_cur_cont
.Lpe_pp:
    jmp Lsyn_err               # 指针 + 指针 → 不支持
.Lpe_cur_cont:
    movl $0, cur_lval
    movl $0, cur_anum
    jmp .Lpe_top
.Lpe_done:
    addl $8, %esp              # 弹左类型对
    ret

# ================= 乘除（纯算术；指针参与报错） =================
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
    pushl %eax
    call next_token
    call parse_unary
    movl cur_tptr, %eax
    cmpl $0, %eax
    jne Lsyn_err               # 指针乘法无意义
    popl %eax
    cmpl $TOK_STAR, %eax
    jne .Lpt_div
    leal op_mul, %ecx
    jmp .Lpt_emit
.Lpt_div:
    leal op_div, %ecx
.Lpt_emit:
    call emit_template
    movl $T_INT, cur_tbase
    movl $0, cur_tptr
    movl $0, cur_lval
    movl $0, cur_anum
    jmp .Lpt_top

# ================= 一元 =================
# unary := ('-'|'!'|'*'|'&'|'++'|'--') unary | postfix
# lval_mode=1 时：变量/解引用/下标给出"地址"（不装载值）
parse_unary:
    movl tok_kind, %eax
    cmpl $TOK_MINUS, %eax
    je .Lpu_minus
    cmpl $TOK_BANG, %eax
    je .Lpu_bang
    cmpl $TOK_STAR, %eax
    je .Lpu_star
    cmpl $TOK_AMP, %eax
    je .Lpu_amp
    cmpl $TOK_INC, %eax
    je .Lpu_inc
    cmpl $TOK_DEC, %eax
    je .Lpu_dec
    jmp parse_postfix
.Lpu_minus:
    call next_token
    pushl lval_mode
    movl $0, lval_mode
    call parse_unary
    popl lval_mode
    cmpl $T_VOID, cur_tbase
    je Lsyn_err
    leal unary_neg, %ecx
    call emit_template
    movl $T_INT, cur_tbase
    movl $0, cur_tptr
    movl $0, cur_lval
    movl $0, cur_anum
    ret
.Lpu_bang:
    call next_token
    pushl lval_mode
    movl $0, lval_mode
    call parse_unary
    popl lval_mode
    cmpl $T_VOID, cur_tbase
    je Lsyn_err
    leal s_lognot, %ecx
    call emit_template
    movl $T_INT, cur_tbase
    movl $0, cur_tptr
    movl $0, cur_lval
    movl $0, cur_anum
    ret
.Lpu_star:
    # *e：e 以值模式解析（值=地址）；按当前 lval_mode 决定装载/留址
    call next_token
    pushl lval_mode
    movl $0, lval_mode
    call parse_unary
    popl lval_mode
    movl cur_tbase, %eax
    movl cur_tptr, %ecx
    cmpl $0, %ecx
    je Lsyn_err                # 解引用指针/数组以外 → 错误
    cmpl $T_VOID, %eax
    je Lsyn_err
    decl %ecx                  # 结果 tptr
    # 结果类型 = (tbase, tptr-1)
    movl %eax, cur_tbase
    movl %ecx, cur_tptr
    movl $0, cur_anum
    movl $1, cur_lval
    movl lval_mode, %edx
    testl %edx, %edx
    jnz .Lpu_star_keep         # 地址模式：不装载
    # 值模式：按结果装载
    cmpl $0, %ecx
    jne .Lpu_star_movl
    cmpl $T_CHAR, %eax
    jne .Lpu_star_movl
    leal s_deref_movz, %ecx
    call emit_template
    ret
.Lpu_star_movl:
    leal s_deref_movl, %ecx
    call emit_template
    ret
.Lpu_star_keep:
    ret
.Lpu_amp:
    call next_token
    movl $1, lval_mode
    call parse_unary
    movl $0, lval_mode
    movl cur_lval, %eax
    testl %eax, %eax
    jz Lsyn_err                # & 操作数须为左值
    cmpl $2, cur_tptr
    jge Lsyn_err               # 指针层级上限 2
    incl cur_tptr
    cmpl $0, cur_anum
    jne .Lpu_amp_anum
    jmp .Lpu_amp_ok
.Lpu_amp_anum:
    movl $0, cur_anum          # &a[i]：anum 归一为 0
.Lpu_amp_ok:
    movl $0, cur_lval
    ret
.Lpu_inc:
.Lpu_dec:
    # 前缀 ++/--：操作数以左值模式解析（得地址）→ 读旧值→±1/±esz→写回→新值
    # 类型/op 全部从编译栈槽位读（emit_template 等调用会破坏寄存器）
    movl tok_kind, %eax
    pushl %eax                 # 栈：[..][op]
    call next_token
    movl $1, lval_mode
    call parse_unary
    movl $0, lval_mode
    movl cur_lval, %eax
    testl %eax, %eax
    jz Lsyn_err
    cmpl $0, cur_anum
    jne Lsyn_err               # 数组名不可自增
    cmpl $T_VOID, cur_tbase
    je Lsyn_err
    pushl cur_tbase            # [op][tbase]
    pushl cur_tptr             # [op][tbase][tptr]
    leal s_pfx_pop, %ecx       # popl %eax（addr 出栈；addr 在 %eax）
    call emit_template
    # 装载旧值（判定读栈槽 4(%esp)/0(%esp)）
    cmpl $T_CHAR, 4(%esp)
    jne .Lpu_inc_ldi
    cmpl $0, 0(%esp)
    jne .Lpu_inc_ldi
    leal s_pfx_ldc, %ecx
    call emit_template
    jmp .Lpu_inc_delta
.Lpu_inc_ldi:
    leal s_pfx_ldi, %ecx
    call emit_template
.Lpu_inc_delta:
    # 增量：指针 → ±esz(=1/4 at tptr=1/char)；标量 → ±1（op 读 8(%esp)）
    movl 0(%esp), %ebx         # tptr
    cmpl $0, %ebx
    je .Lpu_inc_scalar
    cmpl $1, %ebx
    jne .Lpu_delta4
    cmpl $T_CHAR, 4(%esp)
    jne .Lpu_delta4
    movl 8(%esp), %eax
    cmpl $TOK_INC, %eax
    jne .Lpu_dec1
    leal s_pfx_i1, %ecx
    call emit_template
    jmp .Lpu_inc_st
.Lpu_dec1:
    leal s_pfx_d1, %ecx
    call emit_template
    jmp .Lpu_inc_st
.Lpu_delta4:
    movl 8(%esp), %eax
    cmpl $TOK_INC, %eax
    jne .Lpu_dec4
    leal s_pfx_i4, %ecx
    call emit_template
    jmp .Lpu_inc_st
.Lpu_dec4:
    leal s_pfx_d4, %ecx
    call emit_template
    jmp .Lpu_inc_st
.Lpu_inc_scalar:
    movl 8(%esp), %eax
    cmpl $TOK_INC, %eax
    jne .Lpu_decsc
    leal s_pfx_inc, %ecx
    call emit_template
    jmp .Lpu_inc_st
.Lpu_decsc:
    leal s_pfx_dec, %ecx
    call emit_template
.Lpu_inc_st:
    # 写回（细判定读 4(%esp) tbase）
    cmpl $T_CHAR, 4(%esp)
    jne .Lpu_inc_sti
    cmpl $0, 0(%esp)
    jne .Lpu_inc_sti
    leal s_pfx_stc, %ecx
    call emit_template
    jmp .Lpu_inc_cur
.Lpu_inc_sti:
    leal s_pfx_sti, %ecx
    call emit_template
.Lpu_inc_cur:
    movl 4(%esp), %ebp         # tbase（0=tptr 4=tbase 8=op）
    movl 0(%esp), %ebx         # tptr
    addl $12, %esp             # 弹 [op][tbase][tptr]
    movl %ebp, cur_tbase
    movl %ebx, cur_tptr
    movl $0, cur_lval
    movl $0, cur_anum
    ret

# ================= 后缀 [ ] / ++ / -- =================
parse_postfix:
    pushl tok_start            # 本后缀链起点（++/-- 重放用）
    call parse_primary
.Lppf_loop:
    movl tok_kind, %eax
    cmpl $TOK_LBKT, %eax
    je .Lppf_bkt
    cmpl $TOK_INC, %eax
    je .Lppf_inci
    cmpl $TOK_DEC, %eax
    je .Lppf_inci
    jmp .Lppf_done
.Lppf_bkt:
    # 基类型必须为数组/指针：cur_tptr ≥ 1
    movl cur_tbase, %eax
    movl cur_tptr, %ecx
    cmpl $0, %ecx
    je Lsyn_err
    # 保存基类型 (tbase,tptr,anum)
    pushl cur_anum
    pushl %ecx
    pushl %eax
    # lval 模式下指针变量基（tptr≥1 且 anum==0）需自槽读值
    movl lval_mode, %edx
    testl %edx, %edx
    jz .Lppf_bkt_index
    cmpl $0, cur_anum
    jne .Lppf_bkt_index        # 数组名：基址直接可用
    leal s_deref_movl, %ecx    # slot 值（=指针）= 基址
    call emit_template
.Lppf_bkt_index:
    call next_token
    pushl lval_mode
    movl $0, lval_mode
    call parse_assign
    popl lval_mode
    cmpl $T_VOID, cur_tbase
    je Lsyn_err
    movl tok_kind, %eax
    cmpl $TOK_RBKT, %eax
    jne Lsyn_err
    call next_token
    # 弹出基类型
    popl %ebp                  # 基 tbase
    popl %edx                  # 基 tptr
    popl %ecx                  # 基 anum（未用）
    pushl %ebp
    pushl %edx
    # esz = (基 tbase==T_CHAR && 基 tptr==1)?1:4
    cmpl $1, %edx
    jne .Lppf_esz4
    cmpl $T_CHAR, %ebp
    jne .Lppf_esz4
    movl $1, %edi
    jmp .Lppf_scale
.Lppf_esz4:
    movl $4, %edi
.Lppf_scale:
    leal s_scale_pre, %ecx
    call app_str
    movl %edi, %eax
    call app_dec
    leal s_scale_mid, %ecx
    call app_str
    leal s_scale_add, %ecx
    call app_str
    call emit_line
    popl %edx                  # 基 tptr
    popl %ebp                  # 基 tbase
    decl %edx                  # 结果 tptr
    movl %ebp, cur_tbase
    movl %edx, cur_tptr
    movl $0, cur_anum
    movl $1, cur_lval
    movl lval_mode, %ecx
    testl %ecx, %ecx
    jnz .Lppf_bkt_keep
    # 值模式：装载
    cmpl $0, %edx
    jne .Lppf_bkt_movl
    cmpl $T_CHAR, %ebp
    jne .Lppf_bkt_movl
    leal s_deref_movz, %ecx
    call emit_template
    jmp .Lppf_loop
.Lppf_bkt_movl:
    leal s_deref_movl, %ecx
    call emit_template
    jmp .Lppf_loop
.Lppf_bkt_keep:
    jmp .Lppf_loop
.Lppf_inci:
    # 后缀 ++/--：
    #   lval 模式（本链作左值上下文/重放途中）→ 留给外层值模式处理；
    #   值模式：操作数须为左值 → 从链起点重放（lval 模式重建地址）
    movl lval_mode, %ecx
    testl %ecx, %ecx
    jz .Lppf_inci2
    jmp .Lppf_done             # 重放时 ++ 不消费，外层值模式处理
.Lppf_inci2:
    # 值模式下，操作数（primary 读取）已把 VALUE 压栈；++ 前先丢弃该值（重放仅压地址）
    leal s_pfx_pop, %ecx       # "    popl %eax\n" 丢弃旧值
    call emit_template
    movl tok_kind, %eax
    pushl %eax                 # 保存 op
    movl 4(%esp), %esi         # 链起点 → 重放
    call next_token
    movl $1, lval_mode
    call parse_postfix
    movl $0, lval_mode
    movl cur_lval, %eax
    testl %eax, %eax
    jz Lsyn_err
    cmpl $0, cur_anum
    jne Lsyn_err               # a++（数组名）→ 错误
    popl %ecx                  # op
    pushl cur_tbase
    pushl cur_tptr
    pushl %ecx
    # 发码：pop addr → 读旧 → 压旧 → ±增量 → 写回
    leal s_pfx_pop, %ecx
    call emit_template
    # 旧值装载（%eax=地址保留）
    movl 8(%esp), %ebp         # tbase
    movl 4(%esp), %ebx         # tptr
    cmpl $T_CHAR, %ebp
    jne .Lppf_i_ldi
    cmpl $0, %ebx
    jne .Lppf_i_ldi
    leal s_pfx_ldc, %ecx
    call emit_template
    jmp .Lppf_i_old
.Lppf_i_ldi:
    leal s_pfx_ldi, %ecx
    call emit_template
.Lppf_i_old:
    leal s_pst_old, %ecx
    call emit_template         # 压旧值
    # 增量（同前缀）
    cmpl $0, %ebx
    je .Lppf_i_scalar
    cmpl $1, %ebx
    jne .Lppf_i_d4
    cmpl $T_CHAR, %ebp
    je .Lppf_i_d1
.Lppf_i_d4:
    cmpl $TOK_INC, 0(%esp)
    jne .Lppf_i_dec4
    leal s_pfx_i4, %ecx
    call emit_template
    jmp .Lppf_i_st
.Lppf_i_dec4:
    leal s_pfx_d4, %ecx
    call emit_template
    jmp .Lppf_i_st
.Lppf_i_d1:
    cmpl $TOK_INC, 0(%esp)
    jne .Lppf_i_dec1
    leal s_pfx_i1, %ecx
    call emit_template
    jmp .Lppf_i_st
.Lppf_i_dec1:
    leal s_pfx_d1, %ecx
    call emit_template
    jmp .Lppf_i_st
.Lppf_i_scalar:
    cmpl $TOK_INC, 0(%esp)
    jne .Lppf_i_decsc
    leal s_pfx_inc, %ecx
    call emit_template
    jmp .Lppf_i_st
.Lppf_i_decsc:
    leal s_pfx_dec, %ecx
    call emit_template
.Lppf_i_st:
    cmpl $T_CHAR, %ebp
    jne .Lppf_i_sti
    cmpl $0, %ebx
    jne .Lppf_i_sti
    leal s_pst_stc, %ecx
    call emit_template
    jmp .Lppf_i_cur
.Lppf_i_sti:
    leal s_pst_sti, %ecx
    call emit_template
.Lppf_i_cur:
    addl $12, %esp             # 弹 [tbase][tptr][op]
    movl %ebp, cur_tbase
    movl %ebx, cur_tptr
    movl $0, cur_lval
    movl $0, cur_anum
    call next_token            # 消费 ++/-- token（回放未消费它，防死循环）
    jmp .Lppf_loop
.Lppf_done:
    addl $4, %esp              # 弹链起点
    ret

# ================= primary =================
# primary := NUM | CHARLIT | STRLIT | IDENT(变量|调用) | '(' expr ')' | '(' type ')' unary(强转)
parse_primary:
    movl tok_kind, %eax
    cmpl $TOK_NUM, %eax
    je .Lpp_num
    cmpl $TOK_CHARLIT, %eax
    je .Lpp_num
    cmpl $TOK_STRLIT, %eax
    je .Lpp_str
    cmpl $TOK_IDENT, %eax
    je .Lpp_ident
    cmpl $TOK_LPAREN, %eax
    je .Lpp_lp
    jmp Lsyn_err
.Lpp_num:
    movl lval_mode, %ecx
    testl %ecx, %ecx
    jnz Lsyn_err               # 常量非左值
    call emit_push_imm
    movl $T_INT, cur_tbase
    movl $0, cur_tptr
    movl $0, cur_lval
    movl $0, cur_anum
    call next_token
    ret
.Lpp_str:
    movl lval_mode, %ecx
    testl %ecx, %ecx
    jnz Lsyn_err
    call emit_string_lit       # 首次使用输出 .rodata 段并 push 地址
    movl $T_CHAR, cur_tbase
    movl $1, cur_tptr
    movl $0, cur_lval
    movl $0, cur_anum
    call next_token
    ret
.Lpp_ident:
    call copy_name
    call peek_token
    movl tok_kind, %eax
    cmpl $TOK_LPAREN, %eax
    je .Lpp_call
    call restore_token
    # 变量 / 数组名（local 优先，global 次之）
    pushl %edi
    call sym_find
    cmpl $-1, %eax
    jne .Lpp_var_loc
    call gs_find
    cmpl $-1, %eax
    je Lsyn_err                # 未声明
    # ------- 全局 -------
    movl %eax, %edi
    movl gs_tbase(,%edi,4), %ebp
    movl gs_tptr(,%edi,4),  %ebx
    movl gs_anum(,%edi,4),  %edx
    pushl %edx                 # anum
    pushl %ebx                 # tptr
    pushl %ebp                 # tbase
    cmpl $0, %edx
    jne .Lpp_garr
    movl lval_mode, %ecx
    testl %ecx, %ecx
    jnz .Lpp_glval
    # 值读（判定用未破坏的 %ebp/%ebx）
    cmpl $T_CHAR, %ebp
    jne .Lpp_gri
    cmpl $0, %ebx
    jne .Lpp_gri
    leal s_glb_z, %ecx
    call app_str
    leal scratch_name, %ecx
    call app_str
    leal s_glb_tail, %ecx
    call app_str
    call emit_line
    jmp .Lpp_g_cur
.Lpp_glval:
    leal s_glb_lea, %ecx
    call app_str
    leal scratch_name, %ecx
    call app_str
    leal s_glb_tail, %ecx
    call app_str
    call emit_line
    jmp .Lpp_g_cur
.Lpp_gri:
    leal s_glb_movl, %ecx
    call app_str
    leal scratch_name, %ecx
    call app_str
    leal s_glb_tail, %ecx
    call app_str
    call emit_line
    jmp .Lpp_g_cur
.Lpp_garr:
    leal s_glb_lea, %ecx
    call app_str
    leal scratch_name, %ecx
    call app_str
    leal s_glb_tail, %ecx
    call app_str
    call emit_line
    popl %ebp
    popl %ebx
    popl %edx
    movl %ebp, cur_tbase
    movl $1, cur_tptr          # 数组衰减
    movl %edx, cur_anum
    movl $1, cur_lval
    jmp .Lpp_g_next
.Lpp_g_cur:
    popl %ebp                  # tbase
    popl %ebx                  # tptr
    popl %edx                  # anum
    movl %ebp, cur_tbase
    movl %ebx, cur_tptr
    movl %edx, cur_anum
    movl $1, cur_lval
.Lpp_g_next:
    popl %edi
    call next_token
    ret
.Lpp_var_loc:
    # ------- 局部 -------
    movl %eax, %edi
    movl sym_off(,%edi,4), %ebp
    movl sym_tbase(,%edi,4), %ebx
    movl sym_tptr(,%edi,4),  %edx
    movl sym_anum(,%edi,4),  %ecx
    pushl %ecx               # anum
    pushl %edx               # tptr
    pushl %ebx               # tbase
    pushl %ebp               # off
    cmpl $0, %ecx
    jne .Lpp_larr
    # 非数组
    movl lval_mode, %eax
    testl %eax, %eax
    jnz .Lpp_llval
    # 值：char 标量 → movzbl；int/ptr → movl（判定用未破坏的 %ebx/%edx）
    cmpl $T_CHAR, %ebx
    jne .Lpp_lri
    cmpl $0, %edx
    jne .Lpp_lri
    leal s_zread1, %ecx
    call app_str
    movl %ebp, %eax
    call app_dec_signed
    leal s_vread2, %ecx
    call app_str
    call emit_line
    jmp .Lpp_l_cur
.Lpp_lri:
    leal s_vread1, %ecx
    call app_str
    movl %ebp, %eax
    call app_dec_signed
    leal s_vread2, %ecx
    call app_str
    call emit_line
    jmp .Lpp_l_cur
.Lpp_llval:
    leal s_leal_pre, %ecx
    call app_str
    movl %ebp, %eax
    call app_dec_signed
    leal s_leal_pst, %ecx
    call app_str
    call emit_line
    jmp .Lpp_l_cur
.Lpp_larr:
    # 数组名：leal 基址（任何模式）
    leal s_leal_pre, %ecx
    call app_str
    movl %ebp, %eax
    call app_dec_signed
    leal s_leal_pst, %ecx
    call app_str
    call emit_line
.Lpp_l_cur:
    popl %ebp                # off（弃）
    popl %ebx                # tbase
    popl %edx                # tptr
    popl %ecx                # anum
    movl %ebx, cur_tbase
    cmpl $0, %ecx
    je .Lpp_l_scalar
    movl $1, cur_tptr        # 数组衰减
    jmp .Lpp_l_nxt
.Lpp_l_scalar:
    movl %edx, cur_tptr
.Lpp_l_nxt:
    movl %ecx, cur_anum
    movl $1, cur_lval
    jmp .Lpp_g_next
.Lpp_call:
    call commit_peek
    call func_find
    cmpl $-1, %eax
    je Lsyn_err
    movl %eax, %edi
    # 保存函数名 16 字节（实参解析可能嵌套覆盖 scratch_name）
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
    # 保存返回类型（占位，出参解析栈区最外层）
    movl func_tbase(,%edi,4), %eax
    pushl %eax
    movl func_tptr(,%edi,4), %eax
    pushl %eax
    # ---- 阶段1：扫描实参边界（同 v2）----
    call next_token
    movl tok_kind, %eax
    cmpl $TOK_RPAREN, %eax
    je .Lpc_zero
    movl $0, arg_count
    movl $0, scan_depth
    movl $0, scan_idx
    movl tok_start, %esi
    movl %esi, %eax
    leal arg_pos, %edx
    movl %eax, (%edx)
    incl arg_count
    incl scan_idx
.Lpc_scan_loop:
    movzbl (%esi), %eax
    testl %eax, %eax
    jz Lsyn_err
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
    movl %esi, scan_end
    jmp .Lpc_sc_done
.Lpc_sc_deep:
    decl scan_depth
    jmp .Lpc_sc_adv
.Lpc_sc2:
    cmpb $',', %al
    jne .Lpc_sc3
    movl scan_depth, %eax
    testl %eax, %eax
    jnz .Lpc_sc_adv
    leal 1(%esi), %eax
    leal arg_pos, %edx
    movl scan_idx, %ecx
    movl %eax, (%edx,%ecx,4)
    incl scan_idx
    incl arg_count
    jmp .Lpc_sc_adv
    # D15（B2a 自举发现）：实参边界扫描须跳过注释/引号字符区——否则字符串实参内的
    #   ',' 被误判为实参分隔符，回放解析把字符串拦腰重扫（裸 % / \ 报错，exit 1）。
.Lpc_sc3:
    cmpb $'/', %al
    jne .Lpc_sc_q1
    cmpb $'*', 1(%esi)
    jne .Lpc_sc_q1
    addl $2, %esi              # 注释 /* ... */：跳到 '*/'
.Lpc_sc_comm:
    movzbl (%esi), %eax
    testl %eax, %eax
    jz Lsyn_err
    cmpb $'*', %al
    jne .Lpc_sc_comm_adv
    cmpb $'/', 1(%esi)
    jne .Lpc_sc_comm_adv
    addl $2, %esi
    jmp .Lpc_scan_loop
.Lpc_sc_comm_adv:
    incl %esi
    jmp .Lpc_sc_comm
.Lpc_sc_q1:
    cmpb $'\'', %al
    je .Lpc_sc_q
    cmpb $'"', %al
    je .Lpc_sc_q
    jmp .Lpc_sc_adv
.Lpc_sc_q:                    # 引号字符区：跳过到同名闭引号（处理 \X 转义，同 is_assign_ahead）
    incl %esi
.Lpc_sc_qloop:
    movzbl (%esi), %ecx
    testl %ecx, %ecx
    jz Lsyn_err
    cmpb $'\\', %cl
    jne .Lpc_sc_qn
    addl $2, %esi
    jmp .Lpc_sc_qloop
.Lpc_sc_qn:
    cmpb %al, %cl
    je .Lpc_sc_qend
    incl %esi
    jmp .Lpc_sc_qloop
.Lpc_sc_qend:
    incl %esi
    jmp .Lpc_scan_loop
.Lpc_sc_adv:
    incl %esi
    jmp .Lpc_scan_loop
.Lpc_sc_done:
    pushl scan_end
    movl arg_count, %eax
    pushl %eax
    movl $-1, %eax
    pushl %eax
    xorl %ecx, %ecx
.Lpc_ps:
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
    cmpl $-1, %eax
    je .Lpc_rev_done
    popl %esi
    call next_token
    call parse_assign
    cmpl $T_VOID, cur_tbase
    je Lsyn_err                # void 值不能作实参
    jmp .Lpc_rev
.Lpc_rev_done:
    popl %eax
    popl %ebp
    popl %eax
    movl %eax, scan_end
    jmp .Lpc_emit
.Lpc_zero:
    xorl %ebp, %ebp
.Lpc_emit:
    # 弹出并保存返回类型（内存槽；随后名字回填才取到正确 4 个 dword）
    popl %eax                 # tptr
    movl %eax, call_rtptr
    popl %eax                 # tbase
    movl %eax, call_rtbase
    # 弹回函数名（4 dword 回 scratch_name）
    movl $3, %edi
.Lpc_load:
    popl %eax
    leal scratch_name, %edx
    movl %eax, (%edx,%edi,4)
    decl %edi
    jns .Lpc_load
    # %ebp = 实参数
    leal s_call1, %ecx
    call app_str
    leal scratch_name, %ecx
    call app_str
    leal s_nl, %ecx
    call app_str
    call emit_line
    leal s_call3, %ecx
    call app_str
    movl %ebp, %eax
    shll $2, %eax
    call app_dec
    # 返回类型：char 标量 → 调用后 movzbl
    movl call_rtbase, %ecx
    movl call_rtptr, %ebx
    cmpl $T_CHAR, %ecx
    jne .Lpc_tail_notchar
    cmpl $0, %ebx
    jne .Lpc_tail_notchar
    leal s_call_char, %ecx
    call app_str
    call emit_line
    movl $T_CHAR, cur_tbase
    movl $0, cur_tptr
    movl $0, cur_lval
    movl $0, cur_anum
    jmp .Lpc_tail
.Lpc_tail_notchar:
    leal s_call4, %ecx
    call app_str
    call emit_line
    cmpl $T_VOID, call_rtbase
    jne .Lpc_cur_set
    movl $T_VOID, cur_tbase
    movl $0, cur_tptr
    movl $0, cur_lval
    movl $0, cur_anum
    jmp .Lpc_tail
.Lpc_cur_set:
    movl call_rtbase, %ecx
    movl %ecx, cur_tbase
    movl call_rtptr, %ecx
    movl %ecx, cur_tptr
    movl $0, cur_lval
    movl $0, cur_anum
.Lpc_tail:
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
    # '('：强转判定
    call peek_token
    movl tok_kind, %eax
    cmpl $TOK_INT, %eax
    je .Lpp_cast_chk
    cmpl $TOK_CHAR, %eax
    je .Lpp_cast_chk
    call restore_token
    call next_token            # 消费 '('
    call parse_assign
    cmpl $T_VOID, cur_tbase
    je Lsyn_err
    movl tok_kind, %eax
    cmpl $TOK_RPAREN, %eax
    jne Lsyn_err
    call next_token
    ret                        # cur/lval 透明传递（括号表达式）
.Lpp_cast_chk:
    # 强转：int/char 是关键字，'(' 后出现即必为强转（peek2 非 ')'/'*' 时语法错误）
    call commit_peek           # token = INT/CHAR
    movl tok_kind, %eax
    cmpl $TOK_CHAR, %eax
    jne .Lpp_cast_int
    movl $T_CHAR, %ebp
    jmp .Lpp_cast_ptr
.Lpp_cast_int:
    movl $T_INT, %ebp
.Lpp_cast_ptr:
    movl $0, %ebx
    call next_token
.Lpp_cast_stars:
    movl tok_kind, %eax
    cmpl $TOK_STAR, %eax
    jne .Lpp_cast_rp
    cmpl $2, %ebx
    jge Lsyn_err
    incl %ebx
    call next_token
    jmp .Lpp_cast_stars
.Lpp_cast_rp:
    movl tok_kind, %eax
    cmpl $TOK_RPAREN, %eax
    jne Lsyn_err
    call next_token
    pushl %ebp
    pushl %ebx
    call parse_unary           # 操作数以值模式（lval_mode 末态不影响）
    popl %ebx
    popl %ebp
    cmpl $T_VOID, cur_tbase
    je Lsyn_err
    # 转换：→ char（标量）movzbl；int/ptr 无操作
    cmpl $T_CHAR, %ebp
    jne .Lpp_cast_nop
    cmpl $0, %ebx
    jne .Lpp_cast_nop
    leal s_cast_char, %ecx
    call emit_template
    jmp .Lpp_cast_cur
.Lpp_cast_nop:
.Lpp_cast_cur:
    movl %ebp, cur_tbase
    movl %ebx, cur_tptr
    movl $0, cur_lval
    movl $0, cur_anum
    ret

# ================= 字符串字面量输出 =================
# emit_string_lit: 首次使用把 str_tab[tok_ival] 一次性输出到 .rodata（Lstr%d: .byte …）
emit_string_lit:
    pushl %esi
    pushl %edi
    pushl %ebx
    movl tok_ival, %edi
    # .section .rodata
    leal s_sect_ro, %ecx
    call emit_template
    leal s_str_lab, %ecx
    call app_str
    movl %edi, %eax
    call app_dec
    leal s_colon, %ecx
    call app_str
    call emit_line
    # 逐字节 .byte（str_tab[idx*256] 直到 0）
    movl %edi, %eax
    imull $256, %eax, %eax
    leal str_tab(%eax), %esi
.Lesll_loop:
    cmpb $0, (%esi)
    je .Lesll_done
    leal s_gd_byte, %ecx
    call app_str
    movzbl (%esi), %eax
    call app_dec
    leal s_nl, %ecx
    call app_str
    call emit_line
    incl %esi
    jmp .Lesll_loop
.Lesll_done:
    # NUL 终止字节（字符串须自带 \0，否则相连的两个 Lstr 会粘连）
    leal s_gd_byte, %ecx
    call app_str
    call app_dec0
    leal s_nl, %ecx
    call app_str
    call emit_line
    leal s_sect_text, %ecx
    call emit_template
    # pushl $Lstr<idx>
    leal s_str_push, %ecx
    call app_str
    movl %edi, %eax
    call app_dec
    leal s_nl, %ecx
    call app_str
    call emit_line
    popl %ebx
    popl %edi
    popl %esi
    ret

# ================= 符号表：变量（含类型） =================
# reg_local: %eax=tbase %ecx=tptr %edx=anum %ebx=off → 追加局部符号
reg_local:
    pushl %esi
    movl sym_count, %edi
    cmpl $MAX_SYM, %edi
    jge Lsyn_err_rl
    # 当前块重名检查
    pushl %eax
    pushl %ecx
    pushl %edx
    pushl %ebx
    call sym_find_current
    cmpl $-1, %eax
    je .Lrl_ok
    jmp Lsyn_err_rl2
.Lrl_ok:
    popl %ebx
    popl %edx
    popl %ecx
    popl %eax
    pushl %eax
    pushl %ecx
    pushl %edx
    pushl %ebx
    movl sym_count, %edi
    # 名字
    shll $4, %edi
    leal sym_name(%edi), %edi
    leal scratch_name, %esi
    xorl %edx, %edx
.Lrl_copy:
    cmpl $MAX_NAMELEN, %edx
    jge .Lrl_copyd
    movb (%esi,%edx), %al
    testb %al, %al
    jz .Lrl_copyd
    movb %al, (%edi,%edx)
    incl %edx
    jmp .Lrl_copy
.Lrl_copyd:
    movb $0, (%edi,%edx)
    popl %ebx
    popl %edx
    popl %ecx
    popl %eax
    movl sym_count, %edi
    movl %eax, sym_tbase(,%edi,4)
    movl %ecx, sym_tptr(,%edi,4)
    movl %edx, sym_anum(,%edi,4)
    movl %ebx, sym_off(,%edi,4)
    incl sym_count
    popl %esi
    ret
Lsyn_err_rl:
    popl %esi
    jmp Lsyn_err
Lsyn_err_rl2:
    popl %ebx
    popl %edx
    popl %ecx
    popl %eax
    popl %esi
    jmp Lsyn_err

# declare_param: 登记参数（当前 token 已 copy_name；类型读 par_tbase/par_tptr 内存槽）
declare_param:
    pushl %esi
    call sym_find_current
    cmpl $-1, %eax
    jne Lsyn_err_dp
    movl sym_count, %ecx
    cmpl $MAX_SYM, %ecx
    jge Lsyn_err_dp
    leal 8(,%ecx,4), %eax
    movl %eax, sym_off(,%ecx,4)
    movl par_tbase, %edx
    movl %edx, sym_tbase(,%ecx,4)
    movl par_tptr, %edx
    movl %edx, sym_tptr(,%ecx,4)
    movl $0, sym_anum(,%ecx,4)
    call sym_add_name
    incl fn_nparams
    popl %esi
    ret
Lsyn_err_dp:
    popl %esi
    jmp Lsyn_err

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

# ================= 符号表：全局 =================
# gs_find: 查 scratch_name → %eax = 索引 / -1
gs_find:
    pushl %esi
    movl $0, %edi
.Lgf_test:
    cmpl gs_count, %edi
    jge .Lgf_miss
    movl %edi, %ecx
    shll $4, %ecx
    leal gs_name(%ecx), %esi
    leal scratch_name, %edx
    xorl %eax, %eax
.Lgf_cmp:
    movb (%eax,%esi), %cl
    movb (%eax,%edx), %ch
    cmpb %ch, %cl
    jne .Lgf_next
    testb %ch, %ch
    jz .Lgf_hit
    incl %eax
    cmpl $MAX_NAMELEN, %eax
    jb .Lgf_cmp
    jmp .Lgf_hit
.Lgf_next:
    incl %edi
    jmp .Lgf_test
.Lgf_hit:
    popl %esi
    movl %edi, %eax
    ret
.Lgf_miss:
    popl %esi
    movl $-1, %eax
    ret

# reg_global: %eax=tbase %ecx=tptr %edx=anum %ebx=off(占位) → 追加全局符号
reg_global:
    pushl %esi
    pushl %eax                # 保护 tbase（名字拷贝循环用 %al 会破坏 %eax）
    movl gs_count, %edi
    cmpl $MAX_GLB, %edi
    jge .Lrg_full
    shll $4, %edi
    leal gs_name(%edi), %edi
    leal scratch_name, %esi
    pushl %edx                # 保护 anum 输入（复制循环用 edx 计数）
    xorl %edx, %edx
.Lrg_copy:
    cmpl $MAX_NAMELEN, %edx
    jge .Lrg_copyd
    movb (%esi,%edx), %al
    testb %al, %al
    jz .Lrg_copyd
    movb %al, (%edi,%edx)
    incl %edx
    jmp .Lrg_copy
.Lrg_copyd:
    movb $0, (%edi,%edx)
    popl %edx
    popl %eax                # 恢复 tbase
    movl gs_count, %edi
    movl %eax, gs_tbase(,%edi,4)
    movl %ecx, gs_tptr(,%edi,4)
    movl %edx, gs_anum(,%edi,4)
    incl gs_count
    popl %esi
    ret
.Lrg_full:
    popl %eax
    popl %esi
    jmp Lsyn_err

# ================= 符号表：函数（同 v2 + 返回类型） =================
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
    movl func_count, %edi
    movl cur_ftbase, %eax
    movl %eax, func_tbase(,%edi,4)
    movl cur_fptr, %eax
    movl %eax, func_tptr(,%edi,4)
    incl func_count
    popl %esi
    ret
.Lfa_full:
    popl %esi
    jmp Lsyn_err

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
    cmpb $'/', %al
    jne .Lnt_char
    cmpb $'*', 1(%esi)
    jne .Lnt_char
    # 注释 /* ... */（C89 单层）
    addl $2, %esi
.Lnt_comm:
    movzbl (%esi), %eax
    testl %eax, %eax
    jz Lsyn_err                # 未闭合注释
    cmpb $'*', %al
    jne .Lnt_comm_adv
    cmpb $'/', 1(%esi)
    je .Lnt_comm_end
.Lnt_comm_adv:
    incl %esi
    jmp .Lnt_comm
.Lnt_comm_end:
    addl $2, %esi
    jmp .Lnt_skip
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
    # 关键字分派（按长度）：2=if/do 3=int/for 4=else/char/void 5=while/break 6=return 8=continue
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
    cmpl $8, %edi
    je .Lna_kw8
    jmp .Lna_ident
.Lna_kw2:
    movl tok_start, %edx
    cmpb $'i', (%edx)
    jne .Lna_kw2_do
    cmpb $'f', 1(%edx)
    jne .Lna_ident
    movl $TOK_IF, tok_kind
    ret
.Lna_kw2_do:
    cmpb $'d', (%edx)
    jne .Lna_ident
    cmpb $'o', 1(%edx)
    jne .Lna_ident
    movl $TOK_DO, tok_kind
    ret
.Lna_kw3:
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
.Lna_kw4:
    movl tok_start, %edx
    cmpb $'e', (%edx)
    jne .Lna_kw4_ch
    cmpb $'l', 1(%edx)
    jne .Lna_kw4_ch
    cmpb $'s', 2(%edx)
    jne .Lna_ident
    cmpb $'e', 3(%edx)
    jne .Lna_ident
    movl $TOK_ELSE, tok_kind
    ret
.Lna_kw4_ch:
    cmpb $'c', (%edx)
    jne .Lna_kw4_vo
    cmpb $'h', 1(%edx)
    jne .Lna_ident
    cmpb $'a', 2(%edx)
    jne .Lna_ident
    cmpb $'r', 3(%edx)
    jne .Lna_ident
    movl $TOK_CHAR, tok_kind
    ret
.Lna_kw4_vo:
    cmpb $'v', (%edx)
    jne .Lna_ident
    cmpb $'o', 1(%edx)
    jne .Lna_ident
    cmpb $'i', 2(%edx)
    jne .Lna_ident
    cmpb $'d', 3(%edx)
    jne .Lna_ident
    movl $TOK_VOID, tok_kind
    ret
.Lna_kw5:
    movl tok_start, %edx
    cmpb $'w', (%edx)
    jne .Lna_kw5_br
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
.Lna_kw5_br:
    cmpb $'b', (%edx)
    jne .Lna_ident
    cmpb $'r', 1(%edx)
    jne .Lna_ident
    cmpb $'e', 2(%edx)
    jne .Lna_ident
    cmpb $'a', 3(%edx)
    jne .Lna_ident
    cmpb $'k', 4(%edx)
    jne .Lna_ident
    movl $TOK_BREAK, tok_kind
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
.Lna_kw8:
    movl tok_start, %edx
    cmpb $'c', (%edx)
    jne .Lna_ident
    cmpb $'o', 1(%edx)
    jne .Lna_ident
    cmpb $'n', 2(%edx)
    jne .Lna_ident
    cmpb $'t', 3(%edx)
    jne .Lna_ident
    cmpb $'i', 4(%edx)
    jne .Lna_ident
    cmpb $'n', 5(%edx)
    jne .Lna_ident
    cmpb $'u', 6(%edx)
    jne .Lna_ident
    cmpb $'e', 7(%edx)
    jne .Lna_ident
    movl $TOK_CONTINUE, tok_kind
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
    cmpb $'[', %al
    je .Lns_lbk
    cmpb $']', %al
    je .Lns_rbk
    cmpb $'=', %al
    je .Lns_eq
    cmpb $'<', %al
    je .Lns_lt
    cmpb $'>', %al
    je .Lns_gt
    cmpb $'!', %al
    je .Lns_bang
    cmpb $'&', %al
    je .Lns_amp
    cmpb $'|', %al
    je .Lns_or
    cmpb $'\'', %al
    je .Lns_char
    cmpb $'"', %al
    je .Lns_str
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
.Lns_plus:                    # '+' '++' '+='
    cmpb $'+', 1(%esi)
    jne .Lns_plus2
    movl $TOK_INC, tok_kind
    movl $2, tok_len
    addl $2, %esi
    ret
.Lns_plus2:
    cmpb $'=', 1(%esi)
    jne .Lns_plus1
    movl $TOK_OPADD, tok_kind
    movl $2, tok_len
    addl $2, %esi
    ret
.Lns_plus1:
    movl $TOK_PLUS, tok_kind
    incl %esi
    ret
.Lns_minus:                   # '-' '--' '-='
    cmpb $'-', 1(%esi)
    jne .Lns_minus2
    movl $TOK_DEC, tok_kind
    movl $2, tok_len
    addl $2, %esi
    ret
.Lns_minus2:
    cmpb $'=', 1(%esi)
    jne .Lns_minus1
    movl $TOK_OPSUB, tok_kind
    movl $2, tok_len
    addl $2, %esi
    ret
.Lns_minus1:
    movl $TOK_MINUS, tok_kind
    incl %esi
    ret
.Lns_star:                    # '*' '*='
    cmpb $'=', 1(%esi)
    jne .Lns_star1
    movl $TOK_OPMUL, tok_kind
    movl $2, tok_len
    addl $2, %esi
    ret
.Lns_star1:
    movl $TOK_STAR, tok_kind
    incl %esi
    ret
.Lns_slash:                   # '/' '/='
    cmpb $'=', 1(%esi)
    jne .Lns_slash1
    movl $TOK_OPDIV, tok_kind
    movl $2, tok_len
    addl $2, %esi
    ret
.Lns_slash1:
    movl $TOK_SLASH, tok_kind
    incl %esi
    ret
.Lns_lp:    movl $TOK_LPAREN, tok_kind; jmp .Lns_adv
.Lns_rp:    movl $TOK_RPAREN, tok_kind; jmp .Lns_adv
.Lns_lbk:   movl $TOK_LBKT,   tok_kind; jmp .Lns_adv
.Lns_rbk:   movl $TOK_RBKT,   tok_kind; jmp .Lns_adv
.Lns_eq:
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
.Lns_lt:
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
.Lns_gt:
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
.Lns_bang:
    cmpb $'=', 1(%esi)
    jne .Lns_bang1
    movl $TOK_NE, tok_kind
    movl $2, tok_len
    addl $2, %esi
    ret
.Lns_bang1:
    movl $TOK_BANG, tok_kind
    incl %esi
    ret
.Lns_amp:
    cmpb $'&', 1(%esi)
    jne .Lns_amp1
    movl $TOK_LOGAND, tok_kind
    movl $2, tok_len
    addl $2, %esi
    ret
.Lns_amp1:
    movl $TOK_AMP, tok_kind
    incl %esi
    ret
.Lns_or:
    cmpb $'|', 1(%esi)
    jne .Lns_or_bad
    movl $TOK_LOGOR, tok_kind
    movl $2, tok_len
    addl $2, %esi
    ret
.Lns_or_bad:
    movl $1, %ebx
    jmp err_msg                # 位或不在面
.Lns_char:                     # 字符字面量
    movl %esi, tok_start
    incl %esi
    movzbl (%esi), %eax
    testl %eax, %eax
    jz Lsyn_err
    cmpb $'\\', %al
    jne .Lns_char_raw
    incl %esi
    movzbl (%esi), %eax
    call esc_decode            # %eax = 转义字节；esc_decode 推进 %esi 到闭引号
    testl %eax, %eax
    jz Lsyn_err
    movl %eax, %ebp
    jmp .Lns_char_close
.Lns_char_raw:
    movl %eax, %ebp
    incl %esi
.Lns_char_close:
    cmpb $'\'', (%esi)
    jne Lsyn_err
    incl %esi
    movl $TOK_CHARLIT, tok_kind
    movl %ebp, tok_ival
    movl $0, tok_len
    ret
.Lns_str:                      # 字符串字面量
    movl %esi, tok_start
    incl %esi
    movl str_count, %ebp
    cmpl $MAX_STR, %ebp
    jge Lsyn_err
    imull $256, %ebp, %ebp
    xorl %edx, %edx            # 解码字节计数
.Lns_str_loop:
    movzbl (%esi), %eax
    testl %eax, %eax
    jz Lsyn_err                # 未闭合
    cmpb $'"', %al
    je .Lns_str_end
    cmpl $255, %edx
    jge Lsyn_err               # 超长
    cmpb $'\\', %al
    jne .Lns_str_raw
    incl %esi
    movzbl (%esi), %eax
    call esc_decode            # esc_decode 已推进 %esi
    testl %eax, %eax
    jz Lsyn_err
    movb %al, str_tab(%ebp,%edx)
    incl %edx
    jmp .Lns_str_loop
.Lns_str_raw:
    movb %al, str_tab(%ebp,%edx)
    incl %edx
    incl %esi
    jmp .Lns_str_loop
.Lns_str_end:
    movb $0, str_tab(%ebp,%edx)   # NUL
    incl %esi
    incl str_count
    movl $TOK_STRLIT, tok_kind
    movl str_count, %ecx
    decl %ecx
    movl %ecx, tok_ival
    movl %edx, tok_len
    ret
.Lns_semi:  movl $TOK_SEMI,   tok_kind; jmp .Lns_adv
.Lns_comma: movl $TOK_COMMA,  tok_kind; jmp .Lns_adv
.Lns_lb:    movl $TOK_LBRACE, tok_kind; jmp .Lns_adv
.Lns_rb:    movl $TOK_RBRACE, tok_kind; jmp .Lns_adv
.Lns_adv:
    incl %esi
    ret

# esc_decode: %al = 转义字符（%esi 指向其当前位置）→ %eax = 字节值；
#   推进 %esi 越过已消费部分（简单转义 +1；八进制 +1~3）。
#   注意 .Lns_char/.Lns_str 对返回 0 报错（'\0' 字面被拒，登记限制）。
esc_decode:
    cmpb $'n', %al
    jne 1f
    movl $10, %eax
    incl %esi
    ret
1:  cmpb $'t', %al
    jne 2f
    movl $9, %eax
    incl %esi
    ret
2:  cmpb $'\\', %al
    jne 3f
    movl $92, %eax
    incl %esi
    ret
3:  cmpb $'\'', %al
    jne 4f
    movl $39, %eax
    incl %esi
    ret
4:  cmpb $'"', %al
    jne 5f
    movl $34, %eax
    incl %esi
    ret
5:  cmpb $'r', %al
    jne 6f
    movl $13, %eax
    incl %esi
    ret
6:  cmpb $'0', %al
    jne 7f
    movl $0, %eax
    incl %esi
    ret
7:
    # 八进制转义 \d | \dd | \ddd（0-7 最多 3 位；值 >255 → 错误）
    cmpb $'0', %al
    jb 8f
    cmpb $'7', %al
    ja 8f
    subl $'0', %eax
    incl %esi                  # 消费第一位
.Lns_oct_loop:
    cmpl $255, %eax
    ja Lsyn_err                # 严格大于 255 才非法（255 合法）
    movzbl (%esi), %ecx
    cmpb $'0', %cl
    jb .Lns_oct_done
    cmpb $'7', %cl
    ja .Lns_oct_done
    imull $8, %eax, %eax
    subl $'0', %ecx
    addl %ecx, %eax
    incl %esi
    jmp .Lns_oct_loop
.Lns_oct_done:
    ret
8:
    movl %eax, %eax            # 其余转义按字面
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

# ================= peek / restore / commit =================
peek_token:
    movl pk_depth, %ecx
    cmpl $8, %ecx
    jge Lsyn_err
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
    jz Lsyn_err
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
# gs_find_lit: %ecx = 字面名地址 → 拷入 scratch_name 后 gs_find → %eax = 索引 / -1
gs_find_lit:
    pushl %esi
    pushl %edi
    movl %ecx, %esi
    leal scratch_name, %edi
    xorl %edx, %edx
.Lgfl_copy:
    cmpl $MAX_NAMELEN, %edx
    jge .Lgfl_copyd
    movb (%esi,%edx), %al
    movb %al, (%edi,%edx)
    testb %al, %al
    jz .Lgfl_copyd
    incl %edx
    jmp .Lgfl_copy
.Lgfl_copyd:
    movb $0, (%edi,%edx)
    call gs_find              # %eax = idx / -1（gs_find 自存自取 %esi，不破坏 %ebx）
    popl %edi
    popl %esi
    ret

# emit_prog_head: 输出生成程序头部
#   ".section .text/.globl _start/_start:" + [S2 条件 stdin 预读] + "call f_main"
emit_prog_head:
    pushl %ebx
    pushl %ecx
    pushl %edx
    pushl %esi
    pushl %edi
    leal s_head_start, %ecx
    call emit_template
    # S2：src_buf 与 src_len 均存在 → 发预读（%ebx = src_buf 索引，%edi = src_len 索引）
    leal lit_src_buf, %ecx
    call gs_find_lit
    movl %eax, %ebx
    testl %eax, %eax
    js .Leph_call
    leal lit_src_len, %ecx
    call gs_find_lit
    movl %eax, %edi
    testl %eax, %eax
    js .Leph_call
    # read(0, g_src_buf, N) → g_src_len；N = gs_anum(src_buf)
    leal s_rd_a, %ecx
    call app_str
    leal s_gname_pre, %ecx
    call app_str
    movl %ebx, %ecx
    shll $4, %ecx
    leal gs_name(%ecx), %ecx
    call app_str                     # "g_src_buf"
    leal s_rd_b, %ecx
    call app_str
    movl %ebx, %ecx
    movl gs_anum(,%ecx,4), %eax
    call app_dec                     # N（dec_to_str 破坏 %ebx，此后不再用 src_buf 索引）
    leal s_rd_c, %ecx
    call app_str
    leal s_gname_pre, %ecx
    call app_str
    movl %edi, %ecx
    shll $4, %ecx
    leal gs_name(%ecx), %ecx
    call app_str                     # "g_src_len"（movl %eax 目标）
    leal s_rd_d, %ecx
    call app_str
    leal s_gname_pre, %ecx
    call app_str
    movl %edi, %ecx
    shll $4, %ecx
    leal gs_name(%ecx), %ecx
    call app_str                     # "g_src_len"（失败归零目标）
    leal s_rd_e, %ecx
    call app_str
    call emit_line
.Leph_call:
    leal s_head_callmain, %ecx
    call emit_template
    popl %edi
    popl %esi
    popl %edx
    popl %ecx
    popl %ebx
    ret

# emit_prog_epi: 输出生成程序尾部（rc 打印 + exit；pg_quiet 存在时条件跳过打印）
emit_prog_epi:
    pushl %ebx
    pushl %ecx
    pushl %edx
    pushl %esi
    pushl %edi
    leal lit_pg_quiet, %ecx
    call gs_find_lit
    movl %eax, %ebx              # %ebx = pg_quiet 索引（app_str 内部用 %eax，须先落槽）
    testl %eax, %eax
    js .Lpepi_normal
    # pg_quiet 存在 → cmpl $0, g_pg_quiet / jnz Lq_rc / 打印 / Lq_rc: / exit
    leal s_q_pre, %ecx
    call app_str
    leal s_gname_pre, %ecx
    call app_str
    movl %ebx, %ecx
    shll $4, %ecx
    leal gs_name(%ecx), %ecx
    call app_str                     # "g_pg_quiet"
    leal s_q_tail, %ecx
    call app_str
    call emit_line
    jmp .Lpepi_done
.Lpepi_normal:
    leal s_main_epi, %ecx
    call emit_template
.Lpepi_done:
    popl %edi
    popl %esi
    popl %edx
    popl %ecx
    popl %ebx
    ret

# emit_runtime: 输出 s_runtime（超长，>128B）——分块刷行，防止 app_str 逐字符
#   写入 out_line(128B) 溢出越过 .bss 末端（v4.1 加助手后触发，D13）
emit_runtime:
    pushl %esi
    pushl %ecx
    pushl %edx
    leal s_runtime, %esi
.Lrth_loop:
    movzbl (%esi), %eax
    test %eax, %eax
    jz .Lrth_done
    cmpl $100, out_len
    jl .Lrth_put
    call emit_line
.Lrth_put:
    call app_char
    incl %esi
    jmp .Lrth_loop
.Lrth_done:
    call emit_line
    popl %edx
    popl %ecx
    popl %esi
    ret

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

emit_jz:
    pushl %eax
    leal s_jz_pre, %ecx
    call app_str
    popl %eax
    call app_dec
    movl $10, %eax
    call app_char
    call emit_line
    ret
emit_jnz:
    pushl %eax
    leal s_jnz_pre, %ecx
    call app_str
    popl %eax
    call app_dec
    movl $10, %eax
    call app_char
    call emit_line
    ret
emit_jmp:
    pushl %eax
    leal s_jmp_pre, %ecx
    call app_str
    popl %eax
    call app_dec
    movl $10, %eax
    call app_char
    call emit_line
    ret
emit_label:
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

# sym_find: 自末倒序查变量表（遮蔽=最近优先）→ %eax = off / -1
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
    ret
.Lsf_miss:
    popl %esi
    movl $-1, %eax
    ret

# sym_find_current: 仅查当前块 [scope_base, sym_count) → %eax = 索引 / -1
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

# ---- 未用模板引用占位（供 .rodata 对齐；实际编译时不生成）----
s_pl_0: .asciz "    pushl $0\n"
s_pl_1: .asciz "    pushl $1\n"
s_colon: .asciz ":\n"
s_subl1: .asciz "    subl $"
s_storel_i1: .asciz "    movl %eax, "
s_storel_i2: .asciz "(%ebp)\n"
s_storel_c1: .asciz "    movb %al, "
s_storel_c2: .asciz "(%ebp)\n"
s_ret_seq: .asciz "    popl %eax\n    movl %ebp, %esp\n    popl %ebp\n    ret\n"
