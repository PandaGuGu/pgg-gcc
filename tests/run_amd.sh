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
run64 "struct P { int x; int y; }; int main(){ struct P s; s.x=3; s.y=4; return s.x*10+s.y; }" "34" "struct-rw"
run64 "struct P { int x; int y; }; struct P g; int main(){ g.x=5; g.y=7; return g.x*10+g.y; }" "57" "struct-glob"
run64 "struct C { char c; int i; }; int main(){ struct C s; s.c=65; s.i=7; return s.c+s.i; }" "72" "struct-char"
run64 "struct P { int x; int y; }; int f(struct P s){ return s.x*10+s.y; } int main(){ struct P a; a.x=3; a.y=4; return f(a); }" "34" "struct-param"
run64 "struct P { int x; int y; }; struct P a[2] = { {3,4}, {5,6} }; int main(){ return a[0].x*100+a[0].y*10+a[1].x; }" "345" "struct-arr"
run64 "struct P { int a; int b; }; struct R { struct P p; int z; }; int main(){ struct R r; r.p.a=1; r.p.b=2; r.z=3; return r.p.a*100+r.p.b*10+r.z; }" "123" "struct-nest"
run64 "union U { char c; int i; }; int main(){ union U u; u.i=0; u.c=68; return u.c; }" "68" "union"
run64 "struct P { int x; int y; }; int main(){ struct P s1; struct P s2; s1.x=5; s1.y=6; s2=s1; return s2.x*10+s2.y; }" "56" "struct-copy"
run64 "struct P { int x; int y; }; int main(){ struct P s; struct P *p; s.x=5; s.y=7; p=&s; return p->x+p->y; }" "12" "arrow"
run64 "struct N { int v; }; struct M { struct N *n; }; int main(){ struct N a; struct M m; a.v=7; m.n=&a; return m.n->v; }" "7" "multi-arrow"
run64 "int a[3]; struct { int m; } s; int main(){ a[0]=5; s.m=6; return *&a[0] + *&s.m; }" "11" "addr"
run64 "int main(){ int x; x=2; switch(x){ case 1: return 10; case 2: return 20; default: return 30; } }" "20" "switch"
run64 "enum { A, B, C }; int main(){ return A*100+B*10+C; }" "12" "enum"
run64 "typedef int I; int main(){ I a; a=3; return a+4; }" "7" "typedef"
run64 "int ia[3] = {9,10,11}; int main(){ return ia[0]+ia[2]; }" "20" "glob-init"
run64 "int main(){ int s; s=0; int i; i=3; s = (1<<4) + (8>>1) + (5%3); return s; }" "22" "bitwise"
run64 "int main(){ return 1?7:9; }" "7" "ternary"
run64 "struct P { int x; int y; }; struct P s = {3,4}; int main(){ return s.x*10+s.y; }" "34" "struct-init"
run64 "int main(){ int s; int i; s=0; for(i=0;i<4;i=i+1){ switch(i){ case 0: s=s+1; break; case 1: s=s+10; break; default: s=s+100; } } return s; }" "211" "switch-loop"
run64 "int a[2][2][2]; int main(){ a[1][1][1]=5; a[0][0][0]=2; return a[1][1][1]+a[0][0][0]; }" "7" "glob-3d"
run64 "int main(){ return (1&&1) + (0||1) + !0; }" "3" "logic"
run64 "void f(){ } int main(){ f(); return 7; }" "7" "void-fn"
run64 "int main(){ int a; int b; a=(1,2,3); b=7; return a+b; }" "10" "comma2"

echo "=============================="
echo "PASS=$PASS FAIL=$FAIL (用例 $((PASS+FAIL)) 个)"
[ "$FAIL" -eq 0 ]