# 语言特性实现计划（C / C++ 全特性清单版）

> 授权：2026-08-24，用户允许查看 **C、C++ 全部特性**（仅记录特性名，不下载/保存任何编译器源码），
> 用于"重置实验"后的实现规划。参照：cppreference.com、ISO 公开标准与 WG14/WG21 草案。
> 本文件是特性台账——按版本列出标志性语法/库特性；逐条落地时在 ORIGIN 登记实现来源。
> **§4 为 P0–P3 可直接开工细则**（核心特性明确，不设"等等"）；P4+ 按 §5 特性集吸收。

## 0. 实施策略

- **C 轨道先行**，按版本序 C90 → C23（阶段 P0–P8）；**C++ 为待办（backlog）**。
- **实现形态（2026-08-25 无蛋更新）**：编译器本体为**手写 i386 汇编**（无 libc/crt，见
  experiment-baseline §6），构建链 as/ld；P0 起即以汇编地板层自研，全链不调用任何 C/C++ 编译器。
- **输入协议演化**：P0 单表达式（argv）；P1 起为程序文本（stdin），顺序执行并打印结果
  （P1 末条表达式语句的值；P2 起打印 `main` 返回值）。
- 特性落地原则：完全自研；对照受阶段门控（对照须用户显式放行后才能重建/启用）。
- 每阶段完成时在 ORIGIN 特性清单登记（标准条款 + 自实现日期）。
- **自举路线（2026-08-25 固化）**：P3 达成图灵完备后、P5 特性化前插自举支线（B0–B6，见 §6）；
  **B0 决策点 = v4 编译器核心子集完成后**，此后日常特性在自举链上继续开发。

## 1. C（ISO/IEC 9899 系）

### C90（9899:1990，即 ANSI C89）
- 函数原型（prototype）、`void`、枚举、`const`/`volatile`、结构体赋值、标准库线（stdio/stdlib/string/ctype/math…）、预处理器 `#`/`##`、三字符组等。

### C99（9899:1999）
- `long long`、`//` 行注释、混合声明与语句、块内声明、**可变长数组（VLA）**、复合字面量、指定初始化器、`restrict`、`_Bool`/`_Complex`、`inline`、变参宏、`snprintf`、`<stdint.h>`/`<inttypes.h>`（精确宽度类型）、`_Pragma`、`__func__`、枚举尾逗号、`for` 内声明等。

### C11（9899:2011）
- `_Generic`、匿名结构体/联合体、`_Static_assert`、`_Alignas`/`_Alignof`、`_Noreturn`、`_Thread_local`、`_Atomic`、`char16_t`/`char32_t`、多线程/原子库（`<threads.h>`/`<stdatomic.h>`）、`<stdalign.h>`、移除 `gets` 等。

### C17（9899:2018）
- 缺陷修复为主（无新增语言特性；规范性澄清与少量库修正）。

### C23（9899:2024，当前标准）
- 语法：`nullptr`/`nullptr_t`、`true`/`false`/`bool`、数字分隔符 `'`、`typeof`/`typeof_unqual`、对象定义 `auto` 推导、`_BitInt(N)`、`char8_t`/`u8`、单参 `static_assert`、属性（`[[deprecated]]/[[fallthrough]]/[[maybe_unused]]/[[nodiscard]]/[[noreturn]]/[[reproducible]]/[[unsequenced]]`）、`#embed`、`= {}` 零初始化、标签自由放置、移除 K&R 旧式定义等。
- 库：`memset_explicit`、`memccpy`、`strdup`/`strndup`、`memalignment`、`<stdbit.h>`（`stdc_*`）、`gmtime_r`/`localtime_r` 等。
- 未来：C2y（预计 2026–2029）。

## 2. C++（ISO/IEC 14882 系）

### C++98（14882:1998；03 为缺陷修复版）
- 类/对象、继承、多态（virtual）、运算符/函数重载、模板、命名空间、异常、RTTI、引用、默认参数、友元、static 成员、`new`/`delete`、`iostream`、STL（string/容器/迭代器/算法/bitset）、`std::auto_ptr` 等。

### C++11
- `auto`、右值引用/移动语义、lambda、`nullptr`、`enum class`、`override`/`final`、范围 for、`constexpr`、`decltype`、统一初始化 `{}`/`initializer_list`、变参模板、`extern template`、`static_assert`、`<thread>`/`<atomic>`/`<mutex>`、智能指针、`unordered_*`、`chrono`/`tuple`/`regex`/`random` 等。

### C++14
- 泛型 lambda、变量模板、函数返回类型推导、二进制字面量、`constexpr` 放宽、`decltype(auto)` 等。

### C++17
- 结构化绑定、`if`/`switch` 初始化语句、内联变量、折叠表达式、`if constexpr`、CTAD（类模板实参推导）、`std::string_view`/`optional`/`variant`/`any`、`<filesystem>`、并行算法、嵌套命名空间、`[[fallthrough]]`/`[[maybe_unused]]`/`[[nodiscard]]` 属性等。

### C++20
- 概念（concepts）、协程（coroutines）、三路比较 `<=>`、Ranges、`std::span`/`std::format`/calendar·时区、`consteval`、模块（modules，部分）、`jthread`/`stop_token`、`[[likely]]`/`[[unlikely]]` 等。

### C++23
- `if consteval`、显式对象参数（deducing this）、多维 `operator[]`、`#elifdef`/`#elifndef`、`[[assume]]`、`std::expected`/`std::mdspan`/`std::print`/`<stacktrace>`/`<flat_map>` 等、ranges 适配器补充（zip/chunk_by/slide…）。

### C++26（2026-03-28 推送）
- 反射（`^^`）、契约（`contract_assert`/`pre`/`post`）、用户自定义 `static_assert` 消息、注解、占位符变量、trivial 可重定位、`constexpr` 放置 new、pack indexing、结构化绑定作条件、`<debugging>`/`<hazard_pointer>`/`<inplace_vector>`/`<stdbit.h>` 等。

## 3. 阶段编排（C 轨道实现序；C++ 全量转 backlog）

| 阶段 | 目标 | 对应版本 | 状态 / 细则 |
|------|------|----------|--------------|
| P0（v0） | 词法 + 整数四则表达式 → 汇编（自研 i386 汇编 stage-0） | 起步 C89 子集 | ✅ 2026-08-25 无蛋重推完成（10/10 自证），**细则 §4.0** |
| P1（v1） | 变量声明与赋值（符号表、栈帧局部变量） | C89 | ✅ 2026-08-25 无蛋 stage-1 完成（10/10），**细则 §4.1** |
| P2（v2） | 函数定义与调用（栈帧、参数传递、返回） | C89 | ✅ 2026-08-25 无蛋 stage-2 完成（11/11），**细则 §4.2** |
| P3（v3） | 控制流（if/while/for、块作用域、比较） | C89 | ✅ 2026-08-25 无蛋 stage-3 完成（15/15 自证；递归自证 fact(5)==120 → B0 硬门槛达成），**细则 §4.3** |
| P4 | 类型系统补全（指针/数组/struct/union/enum/typedef/const/volatile 等）→ C90 全量 | C90 | 📋 核心特性 §5 |
| P5 | C99 特性集 | C99 | 📋 核心特性 §5 |
| P6 | C11 特性集（原子/线程/泛型选择） | C11 | 📋 核心特性 §5 |
| P7 | C17（缺陷修复） | C17 | 📋 核心特性 §5 |
| P8 | C23 特性集 | C23 | 📋 核心特性 §5 |
| C++ | 待 C 系列成熟后启动：98 → 03 → 11 → 14 → 17 → 20 → 23 → 26 | C++ backlog | 后续启动 |

> 注：P0–P3 的"对应版本"均为 C89 之上的功能面优先级，非实现完整标准；P4 完成即 C90 全量。
> 每条特性落地时，以本页特性名为 Key，在 ORIGIN 特性清单登记（标准条款 + 自实现日期）。

## 4. P0–P3 实现细则（可直接开工；核心特性明确，不设"等等"）

> 公共约束：i386 AT&T 汇编输出、无 libc/crt、栈式求值；实现时可推翻本细则但须在日志留痕。

### 4.0 P0 / v0（无蛋 · 词法 + 整数四则表达式）

**输入/输出协议**（已定标，见 architecture-v0-eggfree.md §7）：
输入 `argv[1]` 单表达式；汇编 → stdout；错误 → stderr；退出码：0 成功 / 2 语法错误 / 1 参数错误；
空白跳过 空格(`0x20`)/`\t`/`\n`/`\r`；数字与中间结果 int32（钳制不报）。

**词法**（token 集）：`NUM`（十进制 ≥1 位）｜ `+ - * / ( )` ｜ `END`。

**文法**（优先级=层级，同层左结合用循环）：
```
expr    := term  (('+'|'-') term)*
term    := unary (('*'|'/') unary)*
unary   := '-' unary | primary
primary := NUM | '(' expr ')'
```

**语义**：整数截断除法（`idivl` 商向零截断，天然对齐 C89）；无溢出检查。

**代码生成**（栈式）：
- 字面量：`pushl $imm`；
- 二元：`popl %ecx; popl %eax;` 后接 `addl`/`subl`/`imull`/（`cltd; idivl %ecx`）`%ecx,%eax; pushl %eax`；
- 程序骨架 = prologue（`_start` 取 argc/argv，`argv[1]` 指针交词法）+ epilogue（`%eax→print_decimal`→换行→`exit` syscall），均无 libc/crt。

**自证**：tests/run.sh 10 用例（四则/括号/一元负/左结合/截断除法，手算期望值）。

### 4.1 P1 / v1（变量声明与赋值）

**输入协议**：程序文本经 **stdin** 读入（run.sh 用管道传字符串；实现时亦可支持首参数=文件路径）；
语句序列，每条 `;` 结尾；**顺序执行，结束打印最后一条表达式语句的值**（无则打印 0）。

**词法新增**：`IDENT`（字母/`_` 开头，后接字母/数字/`_`）、关键字 `int`。

**文法**：
```
decl   := 'int' IDENT (',' IDENT)* ';'
stmt   := decl | assign ';' | expr ';'
assign := IDENT '=' assign | expr        // 右结合；赋值即表达式，其值=右值
expr/term/unary := 同 P0；primary 增 IDENT
```

**语义**：变量全 int32；使用前须声明（未声明→错误 exit 2）；赋值左值仅限变量；
`a = b = c` 链赋值成立（值自右向左传播）。

**符号表与栈帧**：编译期数组 `{name(≤16B), off}`；函数序言 `pushl %ebp; movl %esp,%ebp; subl $N,%esp`
预留 4B×变量数；变量槽 `-off(%ebp)`。

**代码生成**：读 `movl -off(%ebp),%eax; pushl %eax`；赋值=右值入 `%eax` 后 `movl %eax,-off(%ebp)`；
表达式语句求值结果留 `%eax`，末条语句打印之。

**自证要点**：声明+赋值+读回参与表达式；`a=b=c` 链；多变量；未声明使用报错。

### 4.2 P2 / v2（函数定义与调用）

**输入协议**：程序文本（同 v1，stdin）；**入口函数固定 `main`**；结束打印 `main` 返回值。

**词法新增**：关键字 `int`（复用）、`return`。

**文法**：
```
func   := 'int' IDENT '(' params ')' '{' stmt* '}'     // 允许递归
params := ε | IDENT (',' IDENT)*                       // 全 int
call   := IDENT '(' args ')'                           // primary 内
args   := ε | expr (',' expr)*
ret    := 'return' expr ';'
stmt/decl/assign := 同 v1
```

**语义**：int 返回；参数按值；**cdecl 调用约定（实参从右到左压栈，调用方负责平衡）**；
`return` 立即退出函数、值入 `%eax`；作用域=函数体（v2 尚无嵌套块）。

**符号表**：函数表 `{name, 入口标号}`；每函数变量表：参数 `8+4k(%ebp)`（正偏移）、局部负偏移。

**代码生成**：
- 函数序言 `pushl %ebp; movl %esp,%ebp; subl $N,%esp`；尾声 `movl %ebp,%esp; popl %ebp; ret`；
- 调用：从右到左 `pushl` 实参 → `call f` → 返回后 `addl $4n,%esp`。

**自证要点**：`add(2,3)==5`；递归（如 `fact(5)==120`）；多参数；`main` 返回打印。

### 4.3 P3 / v3（控制流：if/while/for + 比较）

**词法新增**：`== != < <= > >=`；`&& || !`（短路/逻辑非）延后至 P4 表达式补全。

**文法**：
```
stmt   := decl | assign ';' | expr ';' | ret ';'
        | 'if' '(' expr ')' stmt ('else' stmt)?
        | 'while' '(' expr ')' stmt
        | 'for' '(' opt ';' opt ';' opt ')' stmt       // opt := ε | expr
        | '{' stmt* '}'
cmp    := expr ('=='|'!='|'<'|'<='|'>'|'>=') expr       // 置于 expr 最低优先级层
```

**语义**：真值 0 假非 0 真；比较结果 int 0/1；
**块作用域**：`{}` 内声明入块生效、出块失效；内层同名变量**遮蔽**外层（不同栈槽）。

**代码生成**：条件跳转 `cmpl`+`jcc`（`jz/jnz/jl/jle/jg/jge` 按比较方向）；标号 `L%d` 计数器；
`for` 三段式直译：init → `L0:` cond → body → inc → `jmp L0`。

**自证要点**：if/else 双分支各计 1；while 计数；`for` 0..4 累和==10；嵌套块遮蔽
（`{ int a; a=2; } a` 出块后外层值恢复）；比较返回 0/1；**递归自证 `fact(5)==120`
（§6.1 B0 硬门槛——语言图灵完备）**。
> 实现留痕（2026-08-25，日志会话 8）：①for 的 inc 段源码在 body 前、代码须在其后 → 采用
> v2 实参同款"扫描+回放"发码（peek/restore 保护 body 后 token）；②出块发码 `addl $4k,%esp`
> 回收块内栈空间（防循环体内声明逐轮递增栈）；③符号表自末倒序（遮蔽）＋当前块重名检查；
> ④函数体首层与参数同域（C §6.2.1）。

## 5. P4–P8 核心特性集（明确开工面；标准驱动，逐版本吸收，每条在 ORIGIN 登记）

- **P4（C90 全量）**核心：类型——指针（`&`/`*`/`[]` 等价）、一/多维数组、`struct`/`union`
  （含嵌套与整值赋值）、`enum`、`typedef`、`const`/`volatile`；表达式——`++/--`、复合赋值
  `+=` 等、位运算 `&|^~<<>>`、逻辑 `&&||!`（0/1 短路）、三目 `?:`、逗号表达式；语句——
  `do-while`、`break`/`continue`、`switch/case/default`（fallthrough）；杂——全局变量
  （初值化）、字符串字面量（只读，存入 `.rodata`）、`sizeof`、`(type)expr` 强转；
  支撑——符号表类型化+作用域栈、数据段 `.data/.bss/.rodata` 输出、int 域隐式转换。
- **P5（C99）**：`long long`、`//` 注释、块内声明与混合声明、VLA、复合字面量、指定初始化器、
  `restrict`、`_Bool`/`_Complex`、`inline`、变参宏、`snprintf` 等（以 §1 清单为准逐条落地）。
- **P6（C11）**：`_Generic`、匿名 struct/union、`_Static_assert`、`_Alignas/_Alignof`、
  `_Noreturn`、`_Thread_local`、`_Atomic`、`char16_t/char32_t`、多线程与原子库（§1 清单）。
- **P7（C17）**：缺陷修复为主（无新增特性；规范性澄清与少量库修正）。
- **P8（C23）**：`nullptr`、`_BitInt(N)`、`typeof/typeof_unqual`、数字分隔符 `'`、
  `#embed`、属性 `[[...]]`、单参 `static_assert` 等（§1 清单）。

## 6. 自举路线（"生蛋"与逐步自举；决策 2026-08-25 固化）

> 语义澄清：**无蛋**（不借用任何外部 C/C++ 编译器作起点）与**生蛋**（用自研语言写自研编译器、
> 自编译自）不冲突。生蛋是无蛋路线的**完成形态**——蛋是自产的，不是偷来的。
> 自举 = "pggcc 用 pggcc 语言编译 pggcc"，是"理解编译器"实验的毕业形式；
> 也是开发模式的切换：此后每加特性，用"pggcc 编译 pggcc"作回归自测。

### 6.1 两道门槛

- **硬门槛（能否自举）**：语言必须**图灵完备**——至少 if/while/for（P3/v3）与**递归自证**
  （fact(5)==120）。缺控制流则任何有实际规模的编译器源码都写不出。→ B0 标志 = v3 完成 + 递归自证。
- **实门槛（好不好自举）**：写编译器本体实际要用的设施——**数组、指针、字符串/字符字面量、
  比较与逻辑运算**。缺这些，自举版编译器只能用手工内存偏移硬写，事倍功半。→ B1 原料。

### 6.2 生蛋时机决策

**建议：v4 编译器核心子集完成后、P5 之前（B0 决策点）**。三时机对比：

| 时机 | 判断 |
|------|------|
| v3 后立即 | 可行但痛苦：无数组/指针/字符串，写编译器本体是天罚。不推荐 |
| **B0 决策点（建议）** | 从 P4 裁出"够写编译器"的最小面（对标 subC：int/char、数组、指针、字符串、控制流、函数），箭头直插自举里程碑 B0。**推荐** |
| P8 全 C89 后 | 特性面大、本体大，自举调试成本随规模上升；且晚拿"自举=自测 oracle"这一最大收益。不推荐 |

### 6.3 自举里程碑（B0–B6）

- **B0**：v3 控制流 + 递归自证（fact(5)==120）→ 语言图灵完备 = **硬门槛达成**。
- **B1**：v4 编译器核心子集（数组/指针/字符串/比较/逻辑/char）→ 生蛋原料。
- **B2**：用 pggcc 语言从头实现 B0 编译器源码（读入/词法/语法/代码生成/符号表全以本语言实现；
  架构沿用 stage-2/3 单遍无优化设计，自研，不读任何编译器源码）。
- **B3**：用最新手写汇编 stage 编译 B0 源码 → `bin0`。
- **B4**：**自举闭台验证（经典煮蛋验证）**：`bin0` 编译 B0 源码得 `bin1`；`bin0` 再编译 `bin1`
  得 `bin2`；比对 `bin1`/`bin2` 二进制一致性 → 证明"编译器能编译自己且结果稳定"；
  另用上一代手写 stage 编译同一源码做**跨链比对**（防 Thompson 型后门的标准防御）。
- **B5**：日常开发切到自举链，P5–P8 在链上继续。
- **B6**：手写汇编引导链（pggcc0–N.s）退役为历史引导链，保留仓库，配可复现脚本支持
  从任意 stage 全量重放。

> **推进次序提醒**：P3/v3 完成（B0）前不开启自举支线；B0 决策点经用户确认后，再从 P4 裁剪
> v4 编译器核心子集（B1）。B0 之后每完成一个特性，以"pggcc 自举"作回归验证（B5 起日常化）。