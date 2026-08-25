#!/bin/bash
# B2c 自举第三步自证：pggcc4（自研 stage-4）编译 src/boot0.pgc -> bin0（v2 面：函数/参数/调用/return）
#   bin0 读入 v2 程序文本（stdin，函数序列，入口 main 返回其返回值）-> 输出 .s -> as --32 -> ld -m elf_i386 -> 运行比对
# 全程无任何 C/C++ 编译器参与（as/ld 为项目地板层机械工具，无编译语义）。
# 协议（v2，architecture-b2-bootstrap §4）：程序=函数定义序列；main 返回值打印；错误 exit 2（缺 main/未定义/重定义/语法）。
set -u
cd "$(dirname "$0")/.." || exit 1
mkdir -p build

echo "== 构建 pggcc4（as + ld，无蛋） =="
as --32 -o build/pggcc4.o src/pggcc4.s || { echo "BUILD FAILED(as)"; exit 1; }
ld -m elf_i386 -o build/pggcc4 build/pggcc4.o || { echo "BUILD FAILED(ld)"; exit 1; }

echo "== 构建 bin0（bin0 = pggcc4 编译 boot0.pgc 所得自举编译器） =="
if ! timeout 5 ./build/pggcc4 < src/boot0.pgc > build/boot0.s 2>build/boot0_err.txt; then
    echo "boot0.pgc 编译失败:"; cat build/boot0_err.txt; exit 1
fi
as --32 -o build/boot0.o build/boot0.s || { echo "boot0.s 汇编失败"; exit 1; }
ld -m elf_i386 -o build/bin0 build/boot0.o || { echo "boot0 链接失败"; exit 1; }

PASS=0; FAIL=0
run_case() {
    local prog="$1" expect="$2"
    if ! printf '%s' "$prog" | timeout 5 ./build/bin0 > /tmp/b0_case.s 2>/tmp/b0_err.txt; then
        echo "FAIL [$prog]: bin0 编译失败: $(cat /tmp/b0_err.txt)"; FAIL=$((FAIL+1)); return
    fi
    if ! as --32 -o /tmp/b0_case.o /tmp/b0_case.s 2>/tmp/b0_as_err.txt; then
        echo "FAIL [$prog]: 汇编失败: $(cat /tmp/b0_as_err.txt)"; FAIL=$((FAIL+1)); return
    fi
    if ! ld -m elf_i386 -o /tmp/b0_case.out /tmp/b0_case.o 2>/tmp/b0_ld_err.txt; then
        echo "FAIL [$prog]: 链接失败"; FAIL=$((FAIL+1)); return
    fi
    local got
    got=$(timeout 5 /tmp/b0_case.out)
    if [ "$got" = "$expect" ]; then
        PASS=$((PASS+1)); echo "PASS [$prog] = $got"
    else
        echo "FAIL [$prog]: 期望 $expect 得 $got"; FAIL=$((FAIL+1))
    fi
}
run_err() {
    local prog="$1" expect="$2"
    printf '%s' "$prog" | timeout 5 ./build/bin0 > /dev/null 2>/dev/null
    local rc=$?
    if [ "$rc" = "$expect" ]; then
        PASS=$((PASS+1)); echo "PASS [$prog] -> exit $rc"
    else
        echo "FAIL [$prog]: 退出码 期望 $expect 得 $rc"; FAIL=$((FAIL+1))
    fi
}

echo "== v0 继承（四则表达式包进 main return；期望值手算，与 v0 时代一致） =="
run_case "int main(){ return 1+2*3; }" 7
run_case "int main(){ return (1+2)*(3-4); }" -3
run_case "int main(){ return 100/7; }" 14
run_case "int main(){ return -(-5); }" 5
run_case "int main(){ return 2*3-4*5+6; }" -8
run_case "int main(){ return ((1+2)*3-4)/2; }" 2

echo "== v1 继承（声明/赋值包进 main return） =="
run_case "int main(){ int a; a=5; a=a+1; return a; }" 6
run_case "int main(){ int a; int b; int c; a=b=c=7; return a+b+c; }" 21
run_case "int main(){ int a; int b; a=7; b=a; return a*10+b; }" 77

echo "== v2 主用例（函数/参数/调用/return；期望值手算） =="
run_case "int main(){ return 42; }" 42
run_case "int f(int a){ return a; } int main(){ return f(5); }" 5
run_case "int g(int x){ return x*2; } int main(){ return g(g(3)); }" 12
run_case "int f(int a,int b){ return a+b; } int main(){ return f(3,4); }" 7
run_case "int f(int a,int b,int c){ return a*100+b*10+c; } int main(){ return f(1,2,3); }" 123
run_case "int f(int a){ int b; b=a+1; return b; } int main(){ return f(9); }" 10
run_case "int f(int a){ a=a*2; return a-1; } int main(){ int x; x=3; return f(x); }" 5
run_case "int f(){ return 10; } int main(){ return f()+f(); }" 20
run_case "int main(){ return -7; }" -7

echo "== v2 边界冒烟（链式嵌套/多函数互调/参数·局部同名/负参数/空函数体） =="
run_case "int f(int n){ return n-1; } int main(){ return f(f(f(5))); }" 2
run_case "int add(int a,int b){ return a+b; } int sub(int a,int b){ return a-b; } int main(){ return add(5,3)*10+sub(5,3); }" 82
run_case "int a2(int x){ int a2; a2=x+2; return a2; } int main(){ return a2(8); }" 10
run_case "int f(int a,int b){ return a-b; } int main(){ return f(3,5); }" -2
run_case "int f(){ } int main(){ return f(); }" 0
run_case "int f(int n){ return n+n; } int main(){ return f(21); }" 42

echo "== v2 错误用例（缺 main/未定义/重定义/语法） =="
run_err "int f(){ return 1; }" 2
run_err "int main(){ return g(1); }" 2
run_err "int f(){ return 1; } int f(){ return 2; } int main(){ return 0; }" 2
run_err "int main(){ return f(3; }" 2
run_err "int main(){ return 1 }" 2

echo "=============================="
echo "PASS=$PASS FAIL=$FAIL (用例 $((PASS+FAIL)) 个)"
[ "$FAIL" -eq 0 ]