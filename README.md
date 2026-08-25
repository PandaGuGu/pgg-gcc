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
> 编译器本体由**手写 i386 汇编**（stage-0，无 libc）经 `as`/`ld` 直接构建；环境内 gcc 已卸载。
> v0 无蛋架构评审见 [docs/design/architecture-v0-eggfree.md](docs/design/architecture-v0-eggfree.md)。

- 许可证：MIT
- 语言：目标 C（编译器本体以无蛋方式从 i386 汇编层起步，见基线 §6）
- 平台：Windows / Linux / macOS

## 文档导航

| 文档 | 作用 |
|------|------|
| [docs/design/experiment-baseline.md](docs/design/experiment-baseline.md) | **实验与环境基线**：实验定义、硬约束（红线）、环境清单（WSL 工具链）、自研/对照两套流程、§6 无蛋引导策略 |
| [docs/design/plan-language-features.md](docs/design/plan-language-features.md) | **语言特性实现计划**：C90→C23 / C++98→26 特性台账；§4 P0–P3 可直接开工细则（词法/文法/语义/发码/自证点） |
| [docs/design/architecture-v0-eggfree.md](docs/design/architecture-v0-eggfree.md) | **v0 无蛋架构评审**（Winston）：设计权衡 T1–T5、里程碑 M1–M4、验收门、§7 接口定标 |
| [ORIGIN.md](ORIGIN.md) | **实现来源声明**：5 条原则（不读源码 / 门控对照 / 源码不存留）、逐特性登记表、标准参考表 |
| [docs/logs/](docs/logs/) | **按日操作流水账**：append-only，随 commit 推送 GitHub，AI 行为公开留痕 |
| [tests/run.sh](tests/run.sh) | **自证测试管线**：pggcc → `as --32` → `ld`（无 crt）→ 运行比对手算期望值 |

## 路线图

| 版本（阶段） | 状态 | 目标 |
|------|------|------|
| v0（P0） | ✅ v0 完成（10/10 自证通过） | 词法 + 整数四则表达式 → 汇编输出（无蛋汇编引导；细则见 [plan §4.0](docs/design/plan-language-features.md)） |
| v1（P1） | 📋 细则已定 | 变量声明与赋值（stdin 程序文本；细则见 plan §4.1） |
| v2（P2） | 📋 细则已定 | 函数定义与调用（main 入口、cdecl 约定；细则见 plan §4.2） |
| v3（P3） | 📋 细则已定 | 控制流：if/while/for、比较、块作用域（细则见 plan §4.3） |
| v4（P4） | 📋 待定 | 类型系统补全：指针/数组/struct/union/enum/typedef/const·volatile → C90 全量（plan §5） |
| v5+（P5–P8） | 📋 待定 | 按版本序吸收 C99 / C11 / C17 / C23（plan §5 核心特性集） |
| C++ | 📋 待办（backlog） | 待 C 系列成熟后启动：从 C++98 起实现（类、重载、模板…），IR/代码生成复用 C 侧 |

> v0–v3 与 P0–P3 一一对应，细则见 plan §4；P4–P8 特性集见 plan §5。每阶段设计可调起 Winston 架构师评审把关。

## 目录结构

`
pgg-gcc/
├── src/          # 编译器源码
├── tests/        # 测试用例
├── docs/         # 设计文档与笔记
├── ORIGIN.md     # 实现来源声明（证明不抄袭 GCC）
└── README.md     # 本文件
`

## 构建

```bash
# v0 版本（无蛋引导：手写汇编 stage-0，不调用任何 C/C++ 编译器；2026-08-25 重推完成，自证 10/10）
as --32 -o build/pggcc0.o src/pggcc0.s
ld -m elf_i386 -o build/pggcc build/pggcc0.o
./build/pggcc "1+2*3"
```

自证测试（WSL 内运行，不调用任何 C/C++ 编译器做行为对照）：

```bash
bash tests/run.sh
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
- **实现形态**：编译器本体为**手写 i386 汇编**（无 libc/crt，见基线 §6），构建链仅 `as`/`ld`
  （助记符→二进制的机械翻译器，可用）；不得擅自改回"用 gcc 构建"。
- **开工前必读**：先读 [plan-language-features.md](docs/design/plan-language-features.md) §4（本阶段细则）
  与 [architecture-v0-eggfree.md](docs/design/architecture-v0-eggfree.md) §7（接口定标）再动手；
  接口定标可推翻，但必须日志留痕。
- **文档纪律**：每完成一个特性，在 [ORIGIN.md](ORIGIN.md) 登记（标准条款 + 实现日期）、更新当日日志，
  随后 commit；**不主动 push GitHub，除非用户明确要求**。
- **工程规范**：Rule of Three（出现第 3 个同构模块才抽象）；单文件、可审计、教学级注释；
  寄存器等约定单页文档化。
- **验证边界**：`as`/`ld` 与裸 syscall 属环境验证工具，可用；但**任何"与编译器行为比较"都不允许**
  （包括用本仓库历史版本的输出充当 oracle）。
- **环境坑位**：WSL 默认发行版为 docker-desktop（无 bash），命令须 `wsl -d Ubuntu`；
  经 PowerShell 传含 `$`/引号的复杂参数会被展开，改用仓库 `build/`（gitignored）落文件规避。
