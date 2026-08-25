#!/bin/bash
# B2a 自举第一步自证：pggcc4（自研 stage-4）编译 src/boot0.pgc -> bin0
#   bin0 读入 v0 表达式用例集（stdin）-> 输出 .s -> as --32 -> ld -m elf_i386 -> 运行比对
# 全程无任何 C/C++ 编译器参与（as/ld 为项目地板层机械工具，无编译语义）。
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
    local expr="$1" expect="$2"
    if ! printf '%s' "$expr" | timeout 5 ./build/bin0 > /tmp/b0_case.s 2>/tmp/b0_err.txt; then
        echo "FAIL [$expr]: bin0 编译失败: $(cat /tmp/b0_err.txt)"; FAIL=$((FAIL+1)); return
    fi
    if ! as --32 -o /tmp/b0_case.o /tmp/b0_case.s 2>/tmp/b0_as_err.txt; then
        echo "FAIL [$expr]: 汇编失败: $(cat /tmp/b0_as_err.txt)"; FAIL=$((FAIL+1)); return
    fi
    if ! ld -m elf_i386 -o /tmp/b0_case.out /tmp/b0_case.o 2>/tmp/b0_ld_err.txt; then
        echo "FAIL [$expr]: 链接失败"; FAIL=$((FAIL+1)); return
    fi
    local got
    got=$(timeout 5 /tmp/b0_case.out)
    if [ "$got" = "$expect" ]; then
        PASS=$((PASS+1)); echo "PASS [$expr] = $got"
    else
        echo "FAIL [$expr]: 期望 $expect 得 $got"; FAIL=$((FAIL+1))
    fi
}
run_err() {
    local expr="$1" expect="$2"
    printf '%s' "$expr" | timeout 5 ./build/bin0 > /dev/null 2>/dev/null
    local rc=$?
    if [ "$rc" = "$expect" ]; then
        PASS=$((PASS+1)); echo "PASS [$expr] -> exit $rc"
    else
        echo "FAIL [$expr]: 退出码 期望 $expect 得 $rc"; FAIL=$((FAIL+1))
    fi
}

# ---- v0 用例集（10 用例；期望值手算，与 v0 时代 run.sh 口径一致） ----
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

# ---- 错误/边界冒烟（v0 §7 协议退出码：空串=2、尾算子=2、非法字符=1、双数字=2、缺括号=2…） ----
run_err "" 2
run_err "1+" 2
run_err "1 2" 2
run_err "a" 1
run_err "1)" 2
run_err "()" 2
run_err "*1" 2
run_err "(1+2" 2

# ---- 补充冒烟（成功）：多重一元负 / 深括号 ----
run_case "-------5" -5
run_case "(((((((((1)))))))))" 1

echo "=============================="
echo "PASS=$PASS FAIL=$FAIL (用例 $((PASS+FAIL)) 个)"
[ "$FAIL" -eq 0 ]