#!/bin/bash
# P4-a ARM64 渲染冒烟门：bin_arm（g_ar=1 变体）直出 arm64.s → aarch64-linux-gnu-as/ld（静态无 libc）
# → qemu-aarch64 原生运行。x86/amd64 链由 run_boot/boot_b4/run_amd 覆盖（此脚本零影响）。
# 全程无任何 C/C++ 编译器参与（aarch64 交叉 as/ld + qemu 为项目地板层工具，Q2/Q4 已放行）。
set -u
cd "$(dirname "$0")/.." || exit 1
mkdir -p build

echo "== 构建 bin_arm（g_ar=1 常量折叠变体） =="
sed 's/int g_ar=0;/int g_ar=1;/; s/g_ar==1/1==1/g; s/g_ar==0/0==1/g' src/boot0.pgc > build/boot0_arm.pgc
as --32 -o build/pggcc4.o src/pggcc4.s || { echo "BUILD FAILED(as pggcc4)"; exit 1; }
ld -m elf_i386 -o build/pggcc4 build/pggcc4.o || { echo "BUILD FAILED(ld pggcc4)"; exit 1; }
if ! timeout 40 ./build/pggcc4 < build/boot0_arm.pgc > build/boot0_arm.s 2>build/arm_err.txt; then
    echo "boot0_arm.pgc 编译失败:"; cat build/arm_err.txt; exit 1
fi
as --32 -o build/bin_arm.o build/boot0_arm.s || { echo "FAIL as bin_arm"; exit 1; }
ld -m elf_i386 -o build/bin_arm build/bin_arm.o || { echo "FAIL ld bin_arm"; exit 1; }
echo "bin_arm OK ($(stat -c%s build/boot0_arm.s) B)"

PASS=0; FAIL=0
run64() {
    local prog="$1" expect="$2" name="$3"
    if ! printf '%s' "$prog" | timeout 10 ./build/bin_arm > build/arm64.s 2>build/arm64_err.txt; then
        echo "FAIL[$name]: bin_arm 编译失败: $(cat build/arm64_err.txt)"; FAIL=$((FAIL+1)); return
    fi
    if ! aarch64-linux-gnu-as -o build/arm64.o build/arm64.s 2>build/asarm_err.txt; then
        echo "FAIL[$name]: aarch64-as 失败: $(head -c 200 build/asarm_err.txt)"; FAIL=$((FAIL+1)); return
    fi
    if ! aarch64-linux-gnu-ld -o build/arm64.out build/arm64.o 2>build/ldarm_err.txt; then
        echo "FAIL[$name]: aarch64-ld 失败: $(head -c 200 build/ldarm_err.txt)"; FAIL=$((FAIL+1)); return
    fi
    local got
    got=$(timeout 10 qemu-aarch64 build/arm64.out)
    if [ "$got" = "$expect" ]; then
        PASS=$((PASS+1)); echo "PASS[$name] = $got"
    else
        echo "FAIL[$name]: 期望 $expect 得 '$got'"; FAIL=$((FAIL+1))
    fi
}

echo "== P4-a ARM64 冒烟（最简路径：常量/算术/调用/递归/打印/局部/负数） =="
run64 "int main(){ return 42; }" "42" "ret42"
run64 "int main(){ return 1+2; }" "3" "add"
run64 "int main(){ return 7*6; }" "42" "mul"
run64 "int f(int a){ return a+1; } int main(){ return f(41); }" "42" "call"
run64 "int pg_quiet=1; int main(){ print_int(123); return 0; }" "123" "printint"
run64 "int pg_quiet=1; int main(){ print_str(\"hi\"); return 5; }" "hi" "printstr"
run64 "int fact(int n){ if(n<=1){ return 1; } return n*fact(n-1); } int main(){ return fact(5); }" "120" "rec-fact"
run64 "int main(){ int a; a=3; return a*4; }" "12" "local"
run64 "int main(){ return (1+2)*(3-4); }" "-3" "neg"

echo "=============================="
echo "PASS=$PASS FAIL=$FAIL (用例 $((PASS+FAIL)) 个)"
[ "$FAIL" -eq 0 ]