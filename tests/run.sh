#!/bin/bash
# pggcc v2 自证测试（当前阶段不调用任何 C/C++ 编译器做行为对照）
# v2（P2）函数定义与调用：stdin 函数序列；入口固定 main，结束打印 main 返回值
# 流程：as --32 构建 pggcc2 -> echo 程序 | pggcc2 -> as --32 -> ld -m elf_i386(无crt) -> 运行比对期望值
# 用例程序无 libc（自带 _start + write/exit syscall）；期望值手算，与任何编译器无关
set -u
cd "$(dirname "$0")/.." || exit 1
mkdir -p build

echo "== 构建 pggcc2（无蛋：as + ld 汇编引导，不调用任何 C/C++ 编译器） =="
as --32 -o build/pggcc2.o src/pggcc2.s || { echo "BUILD FAILED(as)"; exit 1; }
ld -m elf_i386 -o build/pggcc2 build/pggcc2.o || { echo "BUILD FAILED(ld)"; exit 1; }

PASS=0; FAIL=0
run_case() {   # 成功用例：比对运行输出
    local prog="$1" expect="$2"
    if ! echo "$prog" | ./build/pggcc2 > /tmp/pggc2_case.s 2>/tmp/pggc2_err.txt; then
        echo "FAIL [$prog]: 编译失败: $(cat /tmp/pggc2_err.txt)"
        FAIL=$((FAIL+1)); return
    fi
    if ! as --32 -o /tmp/pggc2_case.o /tmp/pggc2_case.s 2>/tmp/pggc2_as_err.txt; then
        echo "FAIL [$prog]: 汇编失败"; FAIL=$((FAIL+1)); return
    fi
    if ! ld -m elf_i386 -o /tmp/pggc2_case.out /tmp/pggc2_case.o 2>/tmp/pggc2_ld_err.txt; then
        echo "FAIL [$prog]: 链接失败: $(cat /tmp/pggc2_ld_err.txt)"; FAIL=$((FAIL+1)); return
    fi
    local got
    got=$(/tmp/pggc2_case.out)
    if [ "$got" = "$expect" ]; then
        PASS=$((PASS+1))
        echo "PASS [$prog] = $got"
    else
        echo "FAIL [$prog]: 期望 $expect 得 $got"
        FAIL=$((FAIL+1))
    fi
}
run_err() {    # 错误用例：断言编译失败且退出码=2
    local prog="$1" expect="$2"
    if echo "$prog" | ./build/pggcc2 > /dev/null 2>/dev/null; then
        echo "FAIL [$prog]: 应编译失败但成功"; FAIL=$((FAIL+1)); return
    fi
    echo "$prog" | ./build/pggcc2 > /dev/null 2>/dev/null
    local rc=$?
    if [ "$rc" = "$expect" ]; then
        PASS=$((PASS+1))
        echo "PASS [$prog] -> exit $rc (期望 $expect)"
    else
        echo "FAIL [$prog]: 退出码 期望 $expect 得 $rc"
        FAIL=$((FAIL+1))
    fi
}

# 成功用例：main 返回 / 多参数 / 嵌套调用 / 局部+参数 / 纯表达式 / 负参
run_case "int main() { return 5; }" 5
run_case "int add(int a, int b) { return a+b; } int main() { return add(2,3); }" 5
run_case "int f(int a, int b, int c) { return a*100+b*10+c; } int main() { return f(1,2,3); }" 123
run_case "int g(int x) { return x*2; } int main() { return g(g(3)); }" 12
run_case "int main() { int a; a=7; return a+3; }" 10
run_case "int sum(int a, int b) { int c; c=a+b; return c; } int main() { return sum(10,4); }" 14
run_case "int main() { return (2+3)*4; }" 20
run_case "int neg(int a) { return -a; } int main() { return neg(-7); }" 7
# 错误用例：缺 main exit 2；未定义函数 exit 2；重复函数 exit 2
run_err "int f() { return 1; }" 2
run_err "int main() { return foo(1); }" 2
run_err "int f() { return 1; } int f() { return 2; } int main() { return f(); }" 2

echo "=============================="
echo "PASS=$PASS FAIL=$FAIL (用例 $((PASS+FAIL)) 个)"
[ "$FAIL" -eq 0 ]