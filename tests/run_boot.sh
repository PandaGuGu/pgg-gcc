#!/bin/bash
# B2b 自举第二步自证：pggcc4（自研 stage-4）编译 src/boot0.pgc -> bin0（v1 面：声明/赋值/符号表）
#   bin0 读入 v1 程序文本（stdin）-> 输出 .s -> as --32 -> ld -m elf_i386 -> 运行比对
# 全程无任何 C/C++ 编译器参与（as/ld 为项目地板层机械工具，无编译语义）。
# 协议（v1，architecture-b2-bootstrap §4）：语句以 ';' 结尾；打印最后一条语句的值（声明语句无值，沿用最后值=0 语义）；
#   空程序=0；语法错误 exit 2（未声明/重名/超长/表满/缺分号等）；非法字符 exit 1。
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

echo "== v0 继承（v1 表达式语句协议；期望值手算，与 v0 时代一致） =="
run_case "1+2*3;" 7
run_case "2*(3+4);" 14
run_case "10-4/2;" 8
run_case "(1+2)*(3-4);" -3
run_case "5+3*4-2;" 15
run_case "-3+5;" 2
run_case "100/7;" 14
run_case "2*3-4*5+6;" -8
run_case "((1+2)*3-4)/2;" 2
run_case "-(-5);" 5
run_case "-------5;" -5
run_case "(((((((((1)))))))));" 1

echo "== v0 错误继承（协议演进：空程序 v0=exit2 -> v1=打印0；'a' v0=非法字符1 -> v1=未声明2） =="
run_err "1+;" 2
run_err "1 2;" 2
run_err "(1+2;" 2
run_err "1);" 2
run_err "a;" 2

echo "== v1 主用例（声明/赋值/符号表；期望值手算） =="
run_case "" 0
run_case "int a; int b;" 0
run_case "int a; a=5; a=a+1;" 6
run_case "int a; int b; int c; a=1; b=2; c=3; a+b+c;" 6
run_case "int a; int b; int c; a=b=c=7;" 7
run_case "int a; int b; a=3; int c; c=4; int d; a+c;" 7
run_case "int a; a=3; int b;" 0

echo "== v1 错误用例（未声明/重名/缺分号/畸形声明） =="
run_err "int a; x=1;" 2
run_err "int a; int a;" 2
run_err "int a; a=1" 2
run_err "int;" 2
run_err "int a,;" 2

echo "== v1 边界冒烟（标识符规则/链赋值/名字边界/表容量） =="
run_case "int a; int b; a=7; b=a;" 7
run_case "int a1; int _x; int A2; a1=2; _x=3; A2=a1+_x;" 5
run_case "int a; a=7; a=a-3;" 4
run_case "int a; int b; int c; int d; a=b=c=d=7;" 7
run_case "int abcdefghijklmnop; abcdefghijklmnop=5;" 5
run_case "int a; int b; int c; int d; int e; int f; int g; int h; int i; int j; int k; int l; int m; int n; int o; int p2; int q2; int r2; int s2; int t2; int u2; int v2; int w2; int x2; int y2; int z2; int aa; int ab; int ac; int ad; int ae; int af;" 0
run_err "int abcdefghijklmnopq;" 2
run_err "int int;" 2
run_err "int a; int b; int c; int d; int e; int f; int g; int h; int i; int j; int k; int l; int m; int n; int o; int p2; int q2; int r2; int s2; int t2; int u2; int v2; int w2; int x2; int y2; int z2; int aa; int ab; int ac; int ad; int ae; int af; int ag;" 2
run_err "@" 1

echo "=============================="
echo "PASS=$PASS FAIL=$FAIL (用例 $((PASS+FAIL)) 个)"
[ "$FAIL" -eq 0 ]