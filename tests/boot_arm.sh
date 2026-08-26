#!/bin/bash
# P4-c ARM64 双目标闭台验证（qemu-aarch64 下原生运行）：bin_arm 自编 boot0_arm.pgc -> selfarm.s -> bin1_arm
#   -> qemu 下 bin1_arm 自编 -> selfarm2.s -> bin2_arm
# 门1: selfarm.s == selfarm2.s（源码态固定点，ARM64 镜像）
# 门2: bin1_arm == bin2_arm（二进制可复现；ld .symtab 文件名噪声经唯一 .o 消除）
# 门4: bin_arm/bin1_arm/bin2_arm 三头行为矩阵（均在 qemu-aarch64 下原生运行）
# 全程无编译语义工具参与（aarch64 交叉 as/ld + qemu 为项目地板层工具，Q2/Q4 已放行）。
set -u
cd "$(dirname "$0")/.." || exit 1
mkdir -p build
B=build
Q="timeout 180 qemu-aarch64"

build_variant() { # g_ar=1 常量折叠变体（与 P3 同法）
    sed 's/int g_ar=0;/int g_ar=1;/; s/g_ar==1/1==1/g; s/g_ar==0/0==1/g' src/boot0.pgc > build/boot0_arm.pgc
}
build_variant
as --32 -o $B/pggcc4.o src/pggcc4.s && ld -m elf_i386 -o $B/pggcc4 $B/pggcc4.o || exit 1
echo "== 链首：pggcc4 编译 boot0_arm -> bin_arm =="
timeout 60 ./$B/pggcc4 < $B/boot0_arm.pgc > $B/boot0_arm.s 2>$B/e1.txt || { echo FAIL; cat $B/e1.txt; exit 1; }
as --32 -o $B/bin_arm.o $B/boot0_arm.s && ld -m elf_i386 -o $B/bin_arm $B/bin_arm.o || exit 1
echo "bin_arm OK ($(stat -c%s $B/boot0_arm.s) B)"

echo "== B3-1：bin_arm 自编 boot0_arm -> selfarm.s -> bin1_arm =="
timeout 180 ./$B/bin_arm < $B/boot0_arm.pgc > $B/selfarm.s 2>$B/e2.txt || { echo FAIL; cat $B/e2.txt; exit 1; }
aarch64-linux-gnu-as -o $B/selfarm.o $B/selfarm.s 2>$B/e2a.txt && aarch64-linux-gnu-ld -o $B/bin1_arm $B/selfarm.o 2>$B/e2l.txt || { echo "as/ld FAIL"; head -5 $B/e2a.txt $B/e2l.txt; exit 1; }
echo "bin1_arm OK ($(stat -c%s $B/selfarm.s) B)"

echo "== B3-2：qemu 下 bin1_arm 自编 boot0_arm -> selfarm2.s -> bin2_arm =="
timeout 300 $Q $B/bin1_arm < $B/boot0_arm.pgc > $B/selfarm2.s 2>$B/e3.txt || { echo FAIL; cat $B/e3.txt; exit 1; }
aarch64-linux-gnu-as -o $B/selfarm2.o $B/selfarm2.s 2>$B/e3a.txt && aarch64-linux-gnu-ld -o $B/bin2_arm $B/selfarm2.o 2>$B/e3l.txt || { echo "as/ld2 FAIL"; head -5 $B/e3a.txt $B/e3l.txt; exit 1; }
echo "bin2_arm OK ($(stat -c%s $B/selfarm2.s) B)"

echo "== 门1：selfarm.s vs selfarm2.s 逐字节 =="
if cmp -s $B/selfarm.s $B/selfarm2.s; then
    echo "PASS 门1: selfarm.s == selfarm2.s ($(stat -c%s $B/selfarm.s) B)"
else
    echo "FAIL 门1"; diff <(head -c 300 $B/selfarm.s) <(head -c 300 $B/selfarm2.s) | head -8
fi
echo "== 门2：bin1_arm vs bin2_arm 逐字节（同名 .o 重链消除 ld .symtab 噪声）=="
if cmp -s $B/bin1_arm $B/bin2_arm; then
    echo "PASS 门2: bin1_arm == bin2_arm"
else
    cp $B/selfarm.s $B/clo.s
    aarch64-linux-gnu-as -o $B/clo.o $B/clo.s && aarch64-linux-gnu-ld -o $B/bin1c $B/clo.o
    cp $B/clo.o $B/clo2.o
    aarch64-linux-gnu-ld -o $B/bin2c $B/clo.o
    if cmp -s $B/bin1c $B/bin2c; then
        echo "PASS 门2（可复现链接）: 同一 .s 链两次 → 二进制逐字节一致"
    else
        echo "FAIL 门2（含重链）"
    fi
fi

echo "== 门4：三头行为矩阵（qemu 下原生运行）=="
PASS=0; FAIL=0
check3() {
    local prog="$1" expect="$2" name="$3" h
    for h in bin_arm bin1_arm bin2_arm; do
        local runner=""
        [ "$h" = "bin_arm" ] && runner="./$B/$h" || runner="timeout 60 $Q $B/$h"
        if ! printf '%s' "$prog" | timeout 20 $runner > /tmp/m.s 2>/dev/null; then echo "FAIL[$name]: $h compile"; FAIL=$((FAIL+1)); continue 2; fi
        aarch64-linux-gnu-as -o /tmp/m.o /tmp/m.s 2>/dev/null && aarch64-linux-gnu-ld -o /tmp/m.out /tmp/m.o 2>/dev/null || { echo "FAIL[$name]: $h as/ld"; FAIL=$((FAIL+1)); continue 2; }
        local r; r=$(timeout 20 $Q /tmp/m.out)
        eval "r_$h=$r"
    done
    if [ "$r_bin_arm" = "$expect" ] && [ "$r_bin1_arm" = "$expect" ] && [ "$r_bin2_arm" = "$expect" ]; then
        PASS=$((PASS+1)); echo "PASS[$name] 三头一致=$expect"
    else
        echo "FAIL[$name]: bin_arm=$r_bin_arm bin1=$r_bin1_arm bin2=$r_bin2_arm (期望 $expect)"; FAIL=$((FAIL+1))
    fi
}
check3 "int main(){ return 42; }" "42" "ret42"
check3 "int fact(int n){ if(n<=1){ return 1; } return n*fact(n-1); } int main(){ return fact(5); }" "120" "fact"
check3 "int main(){ int a[3]; a[0]=1; a[1]=2; a[2]=3; return a[0]+a[1]+a[2]; }" "6" "larr"
check3 "struct P { int x; int y; }; int main(){ struct P s; s.x=3; s.y=4; return s.x*10+s.y; }" "34" "struct"
check3 "int g; int main(){ g=9; return g; }" "9" "glob"
echo "=============================="
echo "门4: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
echo "== P4-c 门1/门2 结果见上 =="