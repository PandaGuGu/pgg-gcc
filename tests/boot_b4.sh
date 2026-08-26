#!/bin/bash
# B4 煮蛋闭台验证（architecture-b2-bootstrap §8 门控项，2026-08-26 用户放行执行）
# 链：
#   pggcc4（手写 stage-4）编译 src/boot0.pgc -> build/boot0.s -> bin0
#   bin0                            编译 src/boot0.pgc -> build/boot0b.s -> bin1
#   bin1                            编译 src/boot0.pgc -> build/boot0c.s -> bin2
# 门：
#   门1（固定点·源码态）cmp boot0b.s boot0c.s —— bin0 与 bin1 编译同一源码的 .s 逐字节一致
#   门2（固定点·二进制）cmp bin1 bin2      —— 编连产物逐字节一致（闭台判据）
#   门3（跨链比对）     cmp boot0.s boot0b.s —— pggcc4 直出 .s 与 bin0 直出 .s（同源码）
#   门4（行为等价）     bin0/bin1/bin2 编译运行同一程序切片，输出逐例一致且匹配手算期望
# 全程无任何 C/C++ 编译器参与（as/ld 为地板层机械工具）；期望值手算，不引用任何外部编译器行为。
set -u
cd "$(dirname "$0")/.." || exit 1
mkdir -p build
B=build
PASS=0; FAIL=0

echo "== B4-1 链首：pggcc4 编译 boot0.pgc -> boot0.s -> bin0 =="
as --32 -o $B/pggcc4.o src/pggcc4.s || { echo "BUILD FAILED(as)"; exit 1; }
ld -m elf_i386 -o $B/pggcc4 $B/pggcc4.o || { echo "BUILD FAILED(ld)"; exit 1; }
timeout 60 $B/pggcc4 < src/boot0.pgc > $B/boot0.s 2>$B/boot0_err.txt || { echo "pggcc4 编译 boot0.pgc 失败:"; cat $B/boot0_err.txt; exit 1; }
as --32 -o $B/boot0.o $B/boot0.s || exit 1
ld -m elf_i386 -o $B/bin0 $B/boot0.o || exit 1

echo "== B4-2 bin0 编译 boot0.pgc -> boot0b.s -> bin1 =="
timeout 120 $B/bin0 < src/boot0.pgc > $B/boot0b.s 2>$B/boot0b_err.txt || { echo "bin0 编译 boot0.pgc 失败:"; cat $B/boot0b_err.txt; exit 1; }
as --32 -o $B/bin1.o $B/boot0b.s || exit 1
ld -m elf_i386 -o $B/bin1 $B/bin1.o || exit 1

echo "== B4-3 bin1 编译 boot0.pgc -> boot0c.s -> bin2 =="
timeout 120 $B/bin1 < src/boot0.pgc > $B/boot0c.s 2>$B/boot0c_err.txt || { echo "bin1 编译 boot0.pgc 失败:"; cat $B/boot0c_err.txt; exit 1; }
# 门2 逐字节比较前提：ld 会在 .symtab 嵌入输入 .o 的文件名符号（boot0b.o/boot0c.o 各不同），
# 属 ELF 符号噪声非机器码差异——用同名 .o 路径再次编连以消除（.o 内容与 boot0b.o 一致）。
as --32 -o $B/bin1.o $B/boot0c.s || exit 1
ld -m elf_i386 -o $B/bin2 $B/bin1.o || exit 1

echo ""
echo "== B4-4 逐字节比对（门1/门2/门3） =="
printf 'boot0.s  = %d 字节（pggcc4 直出）\n' "$(wc -c < $B/boot0.s)"
printf 'boot0b.s = %d 字节（bin0 直出）\n' "$(wc -c < $B/boot0b.s)"
printf 'boot0c.s = %d 字节（bin1 直出）\n' "$(wc -c < $B/boot0c.s)"
if cmp -s $B/boot0b.s $B/boot0c.s; then
    echo "门1 PASS：boot0b.s == boot0c.s（一代/二代 .s 逐字节一致，固定点·源码态成立）"
else
    echo "门1 FAIL：boot0b.s != boot0c.s（diff 行数 $(diff $B/boot0b.s $B/boot0c.s | wc -l)）"; FAIL=$((FAIL+1))
fi
if cmp -s $B/bin1 $B/bin2; then
    echo "门2 PASS：bin1 == bin2（编连产物二进制逐字节一致，煮蛋闭台判据成立）"
else
    echo "门2 FAIL：bin1 != bin2"; FAIL=$((FAIL+1))
fi
if cmp -s $B/boot0.s $B/boot0b.s; then
    echo "门3 PASS：boot0.s == boot0b.s（跨链比对：pggcc4 直出 == bin0 直出，逐字节一致）"
else
    d=$(diff $B/boot0.s $B/boot0b.s | wc -l)
    echo "门3 异型：boot0.s != boot0b.s（diff 行数 $d）——跨链 .s 非逐字节一致，行为等价以门4 校"
    echo "--- diff 前 10 行 ---"; diff $B/boot0.s $B/boot0b.s | head -10
fi

echo ""
echo "== B4-5 行为等价矩阵（门4：bin0/bin1/bin2 三头编译运行，输出逐例一致且匹配期望） =="

matrix() {
    local prog="$1" expect="$2" gen ok=1
    for gen in bin0 bin1 bin2; do
        if ! printf '%s' "$prog" | timeout 10 ./$B/$gen > /tmp/b4m_$gen.s 2>/tmp/b4m_$gen.err; then
            echo "  FAIL [$prog][$gen]: 编译失败 $(cat /tmp/b4m_$gen.err)"; ok=0; continue
        fi
        as --32 -o /tmp/b4m_$gen.o /tmp/b4m_$gen.s 2>/tmp/b4m_$gen.aerr || { echo "  FAIL [$prog][$gen]: 汇编失败"; ok=0; continue; }
        ld -m elf_i386 -o /tmp/b4m_$gen.out /tmp/b4m_$gen.o 2>/tmp/b4m_$gen.lerr || { echo "  FAIL [$prog][$gen]: 链接失败"; ok=0; continue; }
        local got
        got=$(timeout 5 /tmp/b4m_$gen.out)
        if [ "$got" != "$expect" ]; then echo "  FAIL [$prog][$gen]: 期望 '$expect' 得 '$got'"; ok=0; fi
    done
    if [ "$ok" = 1 ]; then echo "PASS [$prog] 三头一致 = $expect"; PASS=$((PASS+1)); else FAIL=$((FAIL+1)); fi
}

matrix_err() {
    local prog="$1" expect="$2" gen ok=1
    for gen in bin0 bin1 bin2; do
        printf '%s' "$prog" | timeout 10 ./$B/$gen >/dev/null 2>/dev/null
        local rc=$?
        [ "$rc" = "$expect" ] || { echo "  FAIL [$prog][$gen]: 退出码期望 $expect 得 $rc"; ok=0; }
    done
    if [ "$ok" = 1 ]; then echo "PASS [$prog] 三头同退出码 $expect"; PASS=$((PASS+1)); else FAIL=$((FAIL+1)); fi
}

# v0-v3 面：四则/变量/函数/递归/比较/控制流/块作用域/循环控制
matrix "int main(){ return 1+2*3; }" 7
matrix "int main(){ return 2*3-4*5+6; }" -8
matrix "int main(){ int a; int b; int c; a=b=c=7; return a+b+c; }" 21
matrix "int f(int a,int b,int c){ return a*100+b*10+c; } int main(){ return f(1,2,3); }" 123
matrix "int fact(int n){ if(n<=1){ return 1; } return n*fact(n-1); } int main(){ return fact(5); }" 120
matrix "int main(){ int i; int s; s=0; for(i=0;i<5;i=i+1){ s=s+i; } return s; }" 10
matrix "int main(){ int a; a=1; { int a; a=2; } return a; }" 1
matrix "int main(){ int i; int s; i=0; s=0; do { s=s+i; i=i+1; } while(i<5); return s; }" 10
matrix "int main(){ int i; int s; s=0; for(i=0;i<5;i=i+1){ if(i==2){ continue; } s=s+i; } return s; }" 8
# v4 面：全局/数组/字符串/内建/逻辑/void/注释
matrix "int ia[3]; int main(){ ia[0]=7; ia[1]=8; ia[2]=9; return ia[0]+ia[1]+ia[2]; }" 24
matrix "int main(){ print_str(\"hi\"); return 5; }" hi5
matrix "int main(){ print_str(\"a\"); print_str(\"b\"); return 1; }" ab1
matrix "int main(){ print_int(123); return 4; }" 1234
matrix "int main(){ print_int(-7); return 0; }" -70
matrix "int main(){ return (1&&1) + (1&&0); }" 1
matrix "int main(){ return (0||1) + (0||0); }" 1
matrix "int main(){ return !0 + !7; }" 1
matrix "int main(){ return 'A'+1; }" 66
matrix "void f(){ print_str(\"z\"); } int main(){ f(); return 4; }" z4
matrix "int main(){ /* 注释 */ int a; a=3; return a; }" 3
# 错误面：缺 main / 循环外 break / do-while 缺分号（三头均 exit 2）
matrix_err "int f(){ return 1; }" 2
matrix_err "int main(){ break; return 0; }" 2
matrix_err "int main(){ int i; i=0; do { i=i+1; } while(0) }" 2
matrix_err "int main(){ return 2%3; }" 1

echo ""
echo "== B4-5 门5：pg_quiet=1 目标 stdout 必须 0 字节（v4.1 语义回归；B4 整改项） =="
P5=0; F5=0
for gen in bin0 bin1 bin2; do
    if ! printf '%s' 'int pg_quiet=1; int main(){ return 42; }' | timeout 10 ./$B/$gen > /tmp/b4p.s 2>/tmp/b4p.err; then
        echo "  FAIL [$gen] 编译失败 $(cat /tmp/b4p.err)"; F5=$((F5+1)); continue
    fi
    as --32 -o /tmp/b4p.o /tmp/b4p.s 2>/tmp/b4p.aerr || { echo "  FAIL [$gen] 汇编失败"; F5=$((F5+1)); continue; }
    ld -m elf_i386 -o /tmp/b4p.out /tmp/b4p.o 2>/tmp/b4p.lerr || { echo "  FAIL [$gen] 链接失败"; F5=$((F5+1)); continue; }
    n=$(/tmp/b4p.out | wc -c)
    if [ "$n" = "0" ]; then echo "PASS [$gen] pg_quiet=1 目标 stdout=0 字节"; P5=$((P5+1)); else echo "  FAIL [$gen] pg_quiet=1 目标 stdout=$n 字节"; F5=$((F5+1)); fi
done

echo ""
echo "=============================="
echo "B4 门4（行为等价矩阵）PASS=$PASS FAIL=$FAIL"
echo "B4 门5（pg_quiet 语义）  PASS=$P5  FAIL=$F5"
[ "$FAIL" -eq 0 ] && [ "$F5" -eq 0 ] && echo "B4 煮蛋闭台验证：全部门通过" || echo "B4 存在失败门，见上"