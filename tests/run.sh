#!/bin/bash
# pggcc v0 自证测试（当前阶段不调用任何 C/C++ 编译器做行为对照）
# 注意：v0 源码已于 2026-08-25 重置删除；本脚本为重推后的自证管线（无蛋：stage-0 手写汇编 src/pggcc0.s）
# 前置环境与流程见 docs/design/experiment-baseline.md §6；用例程序无 libc（自带 _start + write/exit syscall）
# 流程：as --32 构建 pggcc0 -> pggcc "表达式" -> as --32 汇编 -> ld -m elf_i386(无crt) 链接 -> 运行比对期望值
set -u
cd "$(dirname "$0")/.." || exit 1
mkdir -p build

echo "== 构建 pggcc（无蛋：as + ld 汇编引导，不调用任何 C/C++ 编译器） =="
as --32 -o build/pggcc0.o src/pggcc0.s || { echo "BUILD FAILED(as)"; exit 1; }
ld -m elf_i386 -o build/pggcc build/pggcc0.o || { echo "BUILD FAILED(ld)"; exit 1; }

PASS=0; FAIL=0
run_case() {
    local expr="$1" expect="$2"
    if ! ./build/pggcc "$expr" > /tmp/pggcc_case.s 2>/tmp/pggcc_err.txt; then
        echo "FAIL [$expr]: 编译产出汇编失败: $(cat /tmp/pggcc_err.txt)"
        FAIL=$((FAIL+1)); return
    fi
    if ! as --32 -o /tmp/pggcc_case.o /tmp/pggcc_case.s 2>/tmp/pggcc_as_err.txt; then
        echo "FAIL [$expr]: 汇编失败"; FAIL=$((FAIL+1)); return
    fi
    if ! ld -m elf_i386 -o /tmp/pggcc_case.out /tmp/pggcc_case.o 2>/tmp/pggcc_ld_err.txt; then
        echo "FAIL [$expr]: 链接失败: $(cat /tmp/pggcc_ld_err.txt)"; FAIL=$((FAIL+1)); return
    fi
    local got
    got=$(/tmp/pggcc_case.out)
    if [ "$got" = "$expect" ]; then
        PASS=$((PASS+1))
        echo "PASS [$expr] = $got"
    else
        echo "FAIL [$expr]: 期望 $expect 得 $got"
        FAIL=$((FAIL+1))
    fi
}

# 用例：四则/括号/一元负/左结合/截断除法
run_case "1+2*3"      7
run_case "2*(3+4)"    14
run_case "10-4/2"     8
run_case "(1+2)*(3-4)" -3
run_case "5+3*4-2"    15
run_case "-3+5"       2
run_case "100/7"      14
run_case "2*3-4*5+6"  -8
run_case "((1+2)*3-4)/2" 2
run_case "-(-5)"      5

echo "=============================="
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]