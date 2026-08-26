# pgg-gcc

> 从零逐步实现 GCC 语言特性的教学编译器 —— 作者：PandaGuGu

## 项目定位

本项目是一个**教学/自研编译器**，目标是**按版本顺序逐步实现 GCC 所支持的语言特性**（C、C++ 等），
但**不复制 GCC 源码**，仅依据公开语言标准与通用编译原理进行独立实现。

> **实验说明**：本项目是**围绕 DeepSeek-V4-Flash（大语言模型）对 GCC / 编译器原理理解水平的测试**。
> 每个版本都由该模型凭其对语言标准与编译原理的理解**独立推导设计思路**并**自己实现**
> （自汇编至高级语言语法），再于用户**显式放行的阶段**与真实编译器的**运行行为**对照验证，检验理解是否准确。
>
> **阶段门控**：当前自研阶段**禁止与任何 C/C++ 编译器做行为对照**（对照即参考答案，会诱发 AI 越狱）；
> 对照由用户按阶段显式开启。
>
> **2026-08-24 实验重置**：Linux 侧对照装备已销毁并审核（黑盒产物、临时产物全部清除）；授权查看全部
> C/C++ 特性用于规划（仅记特性名，不下载源码）。实现计划见
> [docs/design/plan-language-features.md](docs/design/plan-language-features.md)。
>
> **2026-08-25 基线重置**：v0 自研实现与旧架构/日志文档已确认删除（commit `84204c0`），路线图回到待重推；
> 实验与环境基线见 [docs/design/experiment-baseline.md](docs/design/experiment-baseline.md)。
>
> **2026-08-25 无蛋引导**：用户决策"彻底无蛋"——pggcc 不再依赖任何 C/C++ 编译器作为构建蛋，
> 编译器本体由**AI编写 i386 汇编**（stage-0，无 libc）经 `as`/`ld` 直接构建；环境内 gcc 已卸载。
> v0 无蛋架构评审见 [docs/design/architecture-v0-eggfree.md](docs/design/architecture-v0-eggfree.md)。
>
> **2026-08-26 自举成功**：B2 自举支线（B2a–g）完成——用 pggcc 语言书写的编译器本体 `src/boot0.pgc`
> 经AI写汇编 stage-4（`pggcc4`）编译得 `bin0`，`bin0` 成功编译 `boot0.pgc` 自身（自编译产物随面扩张增长，现值 ≈643KB .s），
> 二次自举产物行为一致、再编回稳（B3 阶段条件达成）。**2026-08-26 B4 煮蛋闭台验证通过**：
> `bin0→bin1→bin2` 逐字节固定点（最新复验：boot0b.s==boot0c.s 658294B 逐字节一致、bin1==bin2 二进制一致）、三头行为矩阵 24/24、
> pg_quiet 语义回归 3/3（详见 [docs/logs/2026-08-26.md](docs/logs/2026-08-26.md)）。**同日 P4-II 收口**：
> 5 项残余限制（`&` 多维取址、局部初始化器、struct 数组传参、后缀 `[i]` 写、struct 多重指针 `->` 链）已在自举链上清零，
> **C90 全量达成**（run_boot 232/232、闭台固定点不破，详见 ORIGIN P4-II 行与日志会话 8）。
> 方案与执行结果见
> [docs/design/architecture-b2-bootstrap.md](docs/design/architecture-b2-bootstrap.md)。
>
> **2026-08-26 平台移植决策定稿**：路线 A（多后端＋交叉自举）、D1b 轻量 IR、Q1–Q5 用户拍板；
> C99 特性面 P5 前先完成移植里程碑 P0–P4（决策→IR 重构→AMD64→双目标闭台→ARM64）。
> 详见 [docs/design/platform-portability.md](docs/design/platform-portability.md)。此后每个阶段完成即上传 GitHub。

- 许可证：MIT
- 语言：目标 C（编译器本体以无蛋方式从 i386 汇编层起步，见基线 §6；当前已可用 pggcc 语言自举，见 architecture-b2）
- 平台：Windows / Linux / macOS

## 文档导航

| 文档 | 作用 |
|------|------|
| [docs/design/experiment-baseline.md](docs/design/experiment-baseline.md) | **实验与环境基线**：实验定义、硬约束（红线）、环境清单（WSL 工具链）、自研/对照两套流程、§6 无蛋引导策略 |
| [docs/design/plan-language-features.md](docs/design/plan-language-features.md) | **语言特性实现计划**：C90→C23 / C++98→26 特性台账；§4 P0–P3 可直接开工细则（词法/文法/语义/发码/自证点）；§6 自举路线（生蛋时机决策 + 里程碑 B0–B6） |
| [docs/design/architecture-v0-eggfree.md](docs/design/architecture-v0-eggfree.md) | **v0 无蛋架构评审**（Winston）：设计权衡 T1–T5、里程碑 M1–M4、验收门、§7 接口定标 |
| [docs/design/architecture-b2-bootstrap.md](docs/design/architecture-b2-bootstrap.md) | **B2 自举重写方案**（B0 决策点提交件＋执行结果）：D1–D3 决策、B2-P0 模板扩展、boot0 自语言面、分步 B2a–g 自证与自举成功记录、B3/B4/B5 承接 |
| [docs/design/platform-portability.md](docs/design/platform-portability.md) | **平台移植性决策**（2026-08-26 定稿）：三层机器码绑定分析、路线 A（多后端＋交叉自举）对照 B/C、轻量 IR（D1b）、路线图 P0 决策→P1 IR→P2 AMD64→P3 双目标闭台→P4 ARM64→P5+ 特性面（C99）；Q1–Q5 用户拍板 |
| [ORIGIN.md](ORIGIN.md) | **实现来源声明**：5 条原则（不读源码 / 门控对照 / 源码不存留）、逐特性登记表、标准参考表 |
| [docs/logs/](docs/logs/) | **按日操作流水账**：append-only，随 commit 推送 GitHub，AI 行为公开留痕 |
| [tests/run.sh](tests/run.sh) | **主链自证管线**：pggcc → `as --32` → `ld`（无 crt）→ 运行比对手算期望值；当前 **72/72** |
| [tests/run_boot.sh](tests/run_boot.sh) | **自举自证管线**：`bin0`（pggcc4 编译 `boot0.pgc` 所得）→ `as --32` → `ld` → 运行比对；当前 **232/232** |
| [tests/boot_b4.sh](tests/boot_b4.sh) | **B4 煮蛋闭台门**：bin0→bin1→bin2 逐字节固定点 ＋ 三头行为矩阵 ＋ pg_quiet 语义回归；**已全门通过（2026-08-26）** |

## 路线图

| 版本（阶段） | 状态 | 目标 |
|------|------|------|
| v0（P0） | ✅ v0 完成（10/10 自证通过） | 词法 + 整数四则表达式 → 汇编输出（无蛋汇编引导；细则见 [plan §4.0](docs/design/plan-language-features.md)） |
| v1（P1） | ✅ v1 完成（10/10 自证通过） | 变量声明与赋值（stdin 程序文本；`int` 声明、`=` 链式赋值、符号表、栈帧局部变量、末语句值打印；细则见 plan §4.1） |
| v2（P2） | ✅ v2 完成（11/11 自证通过） | 函数定义与调用（`int` 函数/参数表/`return`；cdecl 实参从右到左压栈；`main` 入口打印返回值；函数级作用域；细则见 plan §4.2） |
| v3（P3） | ✅ v3 完成（15/15 自证通过） | 控制流：if/while/for、比较、块作用域（递归自证 fact(5)==120 → 语言图灵完备，B0 硬门槛达成；细则见 plan §4.3） |
| v4（P4 一期） | ✅ v4/v4.1 完成（72/72 自证通过）；**P4-II T1–T7＋收口已在自举链落地，C90 全量达成（run_boot 232/232）**（2026-08-26） | 类型系统补全——一期 = **编译器核心子集 B1（生蛋原料）**：char/指针/数组/字符串/逻辑运算/do-while·break·continue/复合赋值/全局变量/强转/注释，及 v4.1 内建 `exit`/`print_int`/`print_err` + stdin 预读 `src_buf` + `pg_quiet` 开关（细则见 plan §4.4；**B1 达成**）；**二期**（C90 全量，链上推进）已含：const/volatile、指针声明符、三目 ?:、逗号、sizeof、位运算+%、switch/case/default、enum、typedef、struct/union、一/二/三维数组、`->`、匿名嵌套 struct、struct 数组·参数·初始化、`&a[i]`/`&s.m`、声明符括号、局部初始化器、struct 多重指针 `->` 链 |
| B2（自举支线） | ✅ B2a–g 完成，**自举成功**（232/232）；**B4 闭台通过、B5 已启用**（2026-08-26） | 用 pggcc 语言重写编译器本体 `src/boot0.pgc`：骨架/变量/函数/控制流/块作用域/循环控制/自面补全七步推进 → `bin0`（pggcc4 编译）**编译 boot0.pgc 自身成功**→ **B3 达成**；**B4 煮蛋闭台通过**（bin0→bin1→bin2 逐字节固定点，tests/boot_b4.sh）；**B5 日常开发已切到自举链**（改 boot0.pgc → bin1 编 → run_boot 232 门；pggcc4 冻结为跨链参照；操作约定见 architecture-b2 §8.1） |
| 移植 P1 | ✅ **P1 完成**（2026-08-26，链上） | 轻量 IR v0.1（D1b 决策，platform-portability §5.1）：boot0 发码改走 ostr/oint → IR 缓冲 → irgo 统一渲染；**P1-b** em_* 全族语义化为操作码+参数（OP_PUSHI/PUSHL/STORE/BINOP/CMP/JZ/JNZ/JMP/LBL），irgo 按操作码分发（AMD64 渲染器选择点就位）；**run_boot 232/232、boot_b4 闭台全门 PASS、run.sh 72/72** |
| 移植 P2 | ✅ **P2 完成**（2026-08-26，链上） | AMD64 后端（platform §5.2）：g_am 双目标；操作码 64 位化 + eh() 运行时模板 syscall 化 + 调用/栈帧 64 位 + 全局/数组/指针/struct/union/switch/初始化器全 64 位化（int 8B/struct 4B 布局规则）；**tests/run_amd.sh 42/42** 原生运行；x86 链零变化 |
| 移植 P3 | ✅ **P3 完成**（2026-08-26，链上） | **AMD64 双目标闭台**：tests/boot_amd.sh——bin_amd 自编 boot0_amd.pgc→bin1_amd→bin2_amd；**门1 selfamd.s==selfamd2.s 逐字节（源码态固定点）、门2 二进制可复现、门4 三头矩阵 5/5**；i386 链五线全绿 |
| v5+（P5–P8） | 📋 待定 | 按版本序吸收 C99 / C11 / C17 / C23（plan §5 核心特性集），B5 起在自举链上继续（Q5 已定：先移植 P1–P4 后特性 P5/C99） |
| C++ | 📋 待办（backlog） | 待 C 系列成熟后启动：从 C++98 起实现（类、重载、模板…），IR/代码生成复用 C 侧 |

> v0–v4 细则见 plan §4（v4 = P4 一期，§4.4；P4 二期及 P5–P8 特性集见 plan §5）。每阶段设计可调起 Winston 架构师评审把关。

## 目录结构

`
pgg-gcc/
├── src/          # 编译器源码（pggcc0–4.s AI汇编 stage；boot0.pgc 自举编译器源码）
├── tests/        # 测试用例与自证管线（run.sh 主链 / run_boot.sh 自举支线）
├── docs/         # 设计文档与笔记
├── ORIGIN.md     # 实现来源声明（证明不抄袭 GCC）
└── README.md     # 本文件
`

## 构建

```bash
# 主链：手写汇编 stage，无蛋引导（不调用任何 C/C++ 编译器）
# v4.1 版本（stage-4：类型系统核心子集 B1 + 模板扩展），2026-08-25 完成
as --32 -o build/pggcc4.o src/pggcc4.s
ld -m elf_i386 -o build/pggcc4 build/pggcc4.o
echo 'int main(){ int a; a=3; return a*4; }' | ./build/pggcc4   # 主链冒烟 → 12

# 自举链：pggcc 语言写编译器本体（B2 自举支线，2026-08-26 自举成功）
./build/pggcc4 < src/boot0.pgc > build/boot0.s          # 编译 boot0 源码
as --32 -o build/bin0.o build/boot0.s
ld -m elf_i386 -o build/bin0 build/bin0.o               # bin0 = B0 编译器
./build/bin0 < src/boot0.pgc > build/boot0b.s           # bin0 自行编译自身 → 自举
```

自证测试（WSL 内运行，不调用任何 C/C++ 编译器做行为对照）：

```bash
bash tests/run.sh        # 主链：v0–v4.1 全部用例，72/72
bash tests/run_boot.sh   # 自举支线：bin0 复跑历史用例集 + 自编译冒烟，232/232
```

## 贡献者

| 贡献者 | 角色 | 头像 |
|--------|------|------|
| PandaGuGu | 项目作者 / 实验设计者 | |
| DeepSeek-V4-Flash | 编译器实现者（被测试的 AI 模型） | ![DeepSeek-V4-Flash 头像](https://www.deepseek.com/favicon.ico) |

## 许可证

本项目基于 MIT 许可证发布。详见 [LICENSE](LICENSE)。

## 其他（AI 注意事项）

> 以下为运行本实验的 AI（DeepSeek-V4-Flash）必须遵守的规范；违反即破坏实验有效性，
> 任何改动/推翻必须在 [docs/logs/](docs/logs/) 日志留痕。

- **对照红线**：当前自研阶段**禁止与任何 C/C++ 编译器做行为对照**——对照即"参考答案"，会诱发行为克隆越狱。
  本仓库与 WSL 环境现已**无任何 C/C++ 编译器**；黑盒产物（如 gcc295）重建须用户显式放行 + 日志留痕。
- **不读源码**：不阅读、复制、逐行移植 GCC 及其他编译器源码；仅依据公开语言标准（ISO 9899/14882）与
  通用编译原理。源码树与源码包不得留存于实验环境。
- **实现形态**：编译器本体为**AI编写的 i386 汇编**（无 libc/crt，见基线 §6），构建链仅 `as`/`ld`
  （助记符→二进制的机械翻译器，可用）；不得擅自改回"用 gcc 构建"。
- **开工前必读**：先读 [plan-language-features.md](docs/design/plan-language-features.md) §4（本阶段细则）
  与 [architecture-v0-eggfree.md](docs/design/architecture-v0-eggfree.md) §7（接口定标）再动手；
  接口定标可推翻，但必须日志留痕。
- **文档纪律**：每完成一个特性，在 [ORIGIN.md](ORIGIN.md) 登记（标准条款 + 实现日期）、更新当日日志，
  随后 commit；**阶段推送**：2026-08-26 起用户要求每个阶段完成即上传 GitHub（令牌见 `D:\API_KEY\github令牌`）。
- **工程规范**：Rule of Three（出现第 3 个同构模块才抽象）；单文件、可审计、教学级注释；
  寄存器等约定单页文档化。
- **验证边界**：`as`/`ld` 与裸 syscall 属环境验证工具，可用；但**任何"与编译器行为比较"都不允许**
  （包括用本仓库历史版本的输出充当 oracle）。
- **环境坑位**：WSL 默认发行版为 docker-desktop（无 bash），命令须 `wsl -d Ubuntu`；
  经 PowerShell 传含 `$`/引号的复杂参数会被展开，改用仓库 `build/`（gitignored）落文件规避。
