#!/bin/bash
# P2-a amd64 渲染冒烟门：bin_amd（g_am=1 变体）直出 amd64.s → as --64 → ld → 本机运行
# 构建：sed 生成 g_am=1 变体（临时），验证 64 位渲染通路；x86 链由 run_boot/boot_b4 覆盖。
# 全程无任何 C/C++ 编译器参与（as/ld 为项目地板层机械工具）。
set -u
cd "$(dirname "$0")/.." || exit 1
mkdir -p build

echo "== 构建 bin_amd（g_am=1 变体） =="
sed 's/int g_am=0;/int g_am=1;/' src/boot0.pgc > build/boot0_amd.pgc
as --32 -o build/pggcc4.o src/pggcc4.s || { echo "BUILD FAILED(as)"; exit 1; }
ld -m elf_i386 -o build/pggcc4 build/pggcc4.o || { echo "BUILD FAILED(ld)"; exit 1; }
if ! timeout 30 ./build/pggcc4 < build/boot0_amd.pgc > build/boot0_amd.s 2>build/amd_err.txt; then
    echo "boot0_amd.pgc 编译失败:"; cat build/amd_err.txt; exit 1
fi
as --32 -o build/bin_amd.o build/boot0_amd.s || { echo "FAIL as bin_amd"; exit 1; }
ld -m elf_i386 -o build/bin_amd build/bin_amd.o || { echo "FAIL ld bin_amd"; exit 1; }

PASS=0; FAIL=0
run64() {
    local prog="$1" expect="$2" name="$3"
    if ! printf '%s' "$prog" | timeout 5 ./build/bin_amd > build/amd64.s 2>build/amd64_err.txt; then
        echo "FAIL[$name]: bin_amd 编译失败: $(cat build/amd64_err.txt)"; FAIL=$((FAIL+1)); return
    fi
    if ! as --64 -o build/amd64.o build/amd64.s 2>build/as64_err.txt; then
        echo "FAIL[$name]: as --64 失败"; FAIL=$((FAIL+1)); return
    fi
    if ! ld -o build/amd64.out build/amd64.o 2>build/ld64_err.txt; then
        echo "FAIL[$name]: ld 64 失败"; FAIL=$((FAIL+1)); return
    fi
    local got
    got=$(timeout 5 build/amd64.out)
    if [ "$got" = "$expect" ]; then
        PASS=$((PASS+1)); echo "PASS[$name] = $got"
    else
        echo "FAIL[$name]: 期望 $expect 得 $got"; FAIL=$((FAIL+1))
    fi
}

echo "== P2-a amd64 冒烟（最简路径：常量/算术/调用/递归/打印/局部） =="
run64 "int main(){ return 42; }" "42" "ret42"
run64 "int main(){ return 1+2; }" "3" "add"
run64 "int main(){ return 7*6; }" "42" "mul"
run64 "int f(int a){ return a+1; } int main(){ return f(41); }" "42" "call"
run64 "int pg_quiet=1; int main(){ print_int(123); return 0; }" "123" "printint"
run64 "int pg_quiet=1; int main(){ print_str(\"hi\"); return 5; }" "hi" "printstr"
run64 "int fact(int n){ if(n<=1){ return 1; } return n*fact(n-1); } int main(){ return fact(5); }" "120" "rec-fact"
run64 "int main(){ int a; a=3; return a*4; }" "12" "local"
run64 "int main(){ return (1+2)*(3-4); }" "-3" "neg"
run64 "int g; int main(){ g=7; return g; }" "7" "glob"
run64 "int ga[3]; int main(){ ga[0]=1; ga[1]=2; ga[2]=3; return ga[0]+ga[1]+ga[2]; }" "6" "globarr"
run64 "int main(){ int a[3]; a[0]=1; a[1]=2; a[2]=3; return a[0]+a[1]+a[2]; }" "6" "locarr"
run64 "int main(){ int a[2][2]; a[0][1]=5; a[1][0]=7; return a[0][1]+a[1][0]; }" "12" "loc2darr"
run64 "int ga[2][2]; int main(){ ga[0][1]=5; ga[1][0]=7; return ga[0][1]+ga[1][0]; }" "12" "glob2darr"
run64 "int sum(int *p,int n){ int i; int s; s=0; i=0; while(i<n){ s=s+p[i]; i=i+1; } return s; } int main(){ int a[3]; a[0]=1; a[1]=2; a[2]=3; return sum(a,3); }" "6" "ptr-arr"
run64 "char cb[4]; int main(){ cb[0]=65; cb[1]=66; return cb[0]+cb[1]; }" "131" "globchar"
run64 "int main(){ char c[4]; c[0]=65; c[1]=66; return c[0]+c[1]; }" "131" "locchar"
run64 "int main(){ int s; int i; s=0; for(i=0;i<5;i=i+1){ s=s+i; } return s; }" "10" "for-loop"
run64 "int main(){ int a; int b; a=(1,2,3); b=7; return a+b; }" "10" "comma"

echo "=============================="
echo "PASS=$PASS FAIL=$FAIL (用例 $((PASS+FAIL)) 个)"
[ "$FAIL" -eq 0 ]