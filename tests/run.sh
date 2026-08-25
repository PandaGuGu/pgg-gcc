#!/bin/bash
# pggcc v1 自证测试（当前阶段不调用任何 C/C++ 编译器做行为对照）
# v1（P1）变量声明与赋值：stdin 程序文本，; 结尾；结束打印最后一条值语句的值（无则 0）
# 流程：as --32 构建 pggcc1 -> echo 程序 | pggcc1 -> as --32 -> ld -m elf_i386(无crt) -> 运行比对期望值
# 用例程序无 libc（自带 _start + write/exit syscall）；期望值手算，与任何编译器无关
set -u
cd "$(dirname "$0")/.." || exit 1
mkdir -p build

echo "== 构建 pggcc1（无蛋：as + ld 汇编引导，不调用任何 C/C++ 编译器） =="
as --32 -o build/pggcc1.o src/pggcc1.s || { echo "BUILD FAILED(as)"; exit 1; }
ld -m elf_i386 -o build/pggcc1 build/pggcc1.o || { echo "BUILD FAILED(ld)"; exit 1; }

PASS=0; FAIL=0
run_case() {   # 成功用例：比对运行输出
    local prog="$1" expect="$2"
    if ! echo "$prog" | ./build/pggcc1 > /tmp/pggc1_case.s 2>/tmp/pggc1_err.txt; then
        echo "FAIL [$prog]: 编译失败: $(cat /tmp/pggc1_err.txt)"
        FAIL=$((FAIL+1)); return
    fi
    if ! as --32 -o /tmp/pggc1_case.o /tmp/pggc1_case.s 2>/tmp/pggc1_as_err.txt; then
        echo "FAIL [$prog]: 汇编失败"; FAIL=$((FAIL+1)); return
    fi
    if ! ld -m elf_i386 -o /tmp/pggc1_case.out /tmp/pggc1_case.o 2>/tmp/pggc1_ld_err.txt; then
        echo "FAIL [$prog]: 链接失败: $(cat /tmp/pggc1_ld_err.txt)"; FAIL=$((FAIL+1)); return
    fi
    local got
    got=$(/tmp/pggc1_case.out)
    if [ "$got" = "$expect" ]; then
        PASS=$((PASS+1))
        echo "PASS [$prog] = $got"
    else
        echo "FAIL [$prog]: 期望 $expect 得 $got"
        FAIL=$((FAIL+1))
    fi
}
run_err() {    # 错误用例：断言编译失败且退出码正确（2=语法/语义错误）
    local prog="$1" expect="$2"
    if echo "$prog" | ./build/pggcc1 > /tmp/pggc1_err.s 2>/tmp/pggc1_err.txt; then
        echo "FAIL [$prog]: 应编译失败但成功"; FAIL=$((FAIL+1)); return
    fi
    # ./build/pggcc1 退出码 = 保存（脚本自身不因非 0 退出；仍用 $? 直接判）
    echo "$prog" | ./build/pggcc1 > /dev/null 2>/dev/null
    local rc=$?
    if [ "$rc" = "$expect" ]; then
        PASS=$((PASS+1))
        echo "PASS [$prog] -> exit $rc (期望 $expect)"
    else
        echo "FAIL [$prog]: 退出码 期望 $expect 得 $rc"
        FAIL=$((FAIL+1))
    fi
}

# 成功用例：声明/赋值/读回参与表达式/链赋值/多变量/声明夹语句/空程序
run_case "int a; a=5; a+1;"                 6
run_case "int a; int b; a=2; b=3; a*b;"     6
run_case "int a; int b; int c; a=b=c=7; a;" 7
run_case "int x; x=10; x=x+5; x;"           15
run_case "int a; int b; a=1; b=2; (a+b)*3;" 9
run_case "int q; q=-7; q/2;"                -3
run_case "int a; a=3; a; int b; b=a*2;"     6
run_case ""                                  0
# 错误用例：未声明使用 exit 2；重复声明 exit 2
run_err "a=4;"         2
run_err "int a; int a; a=1;"  2

echo "=============================="
echo "PASS=$PASS FAIL=$FAIL (用例 $((PASS+FAIL)) 个)"
[ "$FAIL" -eq 0 ]