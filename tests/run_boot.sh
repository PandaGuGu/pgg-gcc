#!/bin/bash
# B2f 自举第六步自证：pggcc4（自研 stage-4）编译 src/boot0.pgc -> bin0（B2f 面：+do-while/break/continue；比较/if-else/while/for/递归/块作用域）
#   bin0 读入 v3 程序文本（stdin，函数序列，入口 main 返回其返回值）-> 输出 .s -> as --32 -> ld -m elf_i386 -> 运行比对
# 全程无任何 C/C++ 编译器参与（as/ld 为项目地板层机械工具，无编译语义）。
# 协议（v3，architecture-b2-bootstrap §4）：程序=函数定义序列；main 返回值打印；错误 exit 2（缺 main/未定义/重定义/语法）。
set -u
cd "$(dirname "$0")/.." || exit 1
mkdir -p build

echo "== 构建 pggcc4（as + ld，无蛋） =="
as --32 -o build/pggcc4.o src/pggcc4.s || { echo "BUILD FAILED(as)"; exit 1; }
ld -m elf_i386 -o build/pggcc4 build/pggcc4.o || { echo "BUILD FAILED(ld)"; exit 1; }

echo "== 构建 bin0（bin0 = pggcc4 编译 boot0.pgc 所得自举编译器） =="
# boot0.pgc 本体自编译在 WSL/mnt 下实测 ~4.6s（含 wpf 长编译），timeout 5 边界抖动会误杀 → 余量提到 30
if ! timeout 30 ./build/pggcc4 < src/boot0.pgc > build/boot0.s 2>build/boot0_err.txt; then
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

echo "== v2 继承（函数/参数/调用/return；期望值手算） =="
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

echo "== v3/B2d：比较算子（setCC 0/1；期望值手算） =="
run_case "int main(){ return 3==3; }" 1
run_case "int main(){ return 3!=3; }" 0
run_case "int main(){ return 2<3; }" 1
run_case "int main(){ return 3<=2; }" 0
run_case "int main(){ return 4>3; }" 1
run_case "int main(){ return 3>=3; }" 1
run_case "int main(){ return 1+2==3; }" 1
run_case "int main(){ int a; a=7; return a>=7; }" 1

echo "== v3/B2d：if/else 与 else-if =="
run_case "int main(){ int a; a=1; if(a>0){ return 10; } else { return 20; } }" 10
run_case "int main(){ int a; a=0; if(a>0){ return 10; } else { return 20; } }" 20
run_case "int main(){ int x; x=2; if(x==1){ return 1; } else if(x==2){ return 2; } else { return 3; } }" 2
run_case "int main(){ int x; x=5; if(x==1){ return 1; } else if(x==2){ return 2; } else { return 3; } }" 3
run_case "int main(){ if(1){ if(0){ return 1; } else { return 2; } } return 3; }" 2

echo "== v3/B2d：while =="
run_case "int main(){ int i; int s; i=0; s=0; while(i<5){ s=s+i; i=i+1; } return s; }" 10
run_case "int main(){ int i; i=10; while(i>0){ i=i-1; } return i; }" 0
run_case "int main(){ int i; i=0; while(0){ i=i+1; } return i; }" 0

echo "== v3/B2d：for（含空增量/嵌套） =="
run_case "int main(){ int s; int i; s=0; for(i=0;i<5;i=i+1){ s=s+i; } return s; }" 10
run_case "int main(){ int i; for(i=0;i<3;){ i=i+1; } return i; }" 3
run_case "int main(){ int s; int i; int j; s=0; for(i=0;i<3;i=i+1){ for(j=0;j<3;j=j+1){ s=s+1; } } return s; }" 9
run_case "int main(){ int s; int i; s=0; for(i=0;i<0;i=i+1){ s=s+1; } return s; }" 0

echo "== v3/B2d：递归（栈管理 + 递归调用） =="
run_case "int fact(int n){ if(n<=1){ return 1; } return n*fact(n-1); } int main(){ return fact(5); }" 120
run_case "int fact(int n){ if(n<=1){ return 1; } return n*fact(n-1); } int main(){ return fact(10); }" 3628800
run_case "int fib(int n){ if(n<2){ return n; } return fib(n-1)+fib(n-2); } int main(){ return fib(7); }" 13

echo "== v3/B2e：块作用域（内层遮蔽外层 / 出块符号表弹回 + addl 栈回收 / 槽位复用） =="
run_case "int main(){ int a; a=1; { int a; a=2; } return a; }" 1
run_case "int main(){ int a; a=1; { int a; a=a+5; return a; } }" 6
run_case "int main(){ int a; a=1; { int a; a=2; { int a; a=3; return a; } } }" 3
run_case "int main(){ int s; s=0; while(0){ int x; x=1; s=s+x; } return s; }" 0
run_case "int main(){ int a; a=0; { int b; b=1; int c; c=2; return b*10+c; } }" 12
run_case "int main(){ int a; a=3; { int b; b=4; } int c; c=a+1; return c; }" 4

echo "== v3/B2f：do-while / break / continue（循环控制标号栈 lcs/lbl） =="
run_case "int main(){ int i; int s; i=0; s=0; do { s=s+i; i=i+1; } while(i<5); return s; }" 10
run_case "int main(){ int i; i=0; do { i=i+1; } while(0); return i; }" 1
run_case "int main(){ int i; i=0; while(1){ i=i+1; if(i==3){ break; } } return i; }" 3
run_case "int main(){ int i; int s; s=0; for(i=0;i<10;i=i+1){ if(i==4){ break; } s=s+i; } return s; }" 6
run_case "int main(){ int i; int s; s=0; for(i=0;i<5;i=i+1){ if(i==2){ continue; } s=s+i; } return s; }" 8
run_case "int main(){ int i; int s; i=0; s=0; while(i<5){ i=i+1; if(i==3){ continue; } s=s+i; } return s; }" 12
run_case "int main(){ int i; int s; i=0; s=0; do { i=i+1; if(i==2){ continue; } s=s+i; } while(i<4); return s; }" 8
run_case "int main(){ int i; int j; int s; s=0; for(i=0;i<3;i=i+1){ for(j=0;j<5;j=j+1){ if(j==2){ break; } s=s+1; } } return s; }" 6

echo "== v4/B2g：全局（标量·初值·数组·char）与字符字面量 =="
run_case "int g=7; int main(){ return g; }" 7
run_case "int a; int b; int main(){ a=1; b=2; return a*10+b; }" 12
run_case "int ia[3]; int main(){ ia[0]=7; ia[1]=8; ia[2]=9; return ia[0]+ia[1]+ia[2]; }" 24
run_case "char cb[4]; int main(){ cb[0]=65; cb[1]=66; return cb[0]+cb[1]; }" 131
run_case "int main(){ return 'A'+1; }" 66
run_case "int main(){ char c; c='Z'; return c; }" 90

echo "== v4/B2g：字符串字面量 + 内建 print_str/print_int/print_err（%eax 传参） =="
run_case "int main(){ print_str(\"hi\"); return 5; }" "hi5"
run_case "int main(){ print_str(\"a\"); print_str(\"b\"); return 1; }" "ab1"
run_case "int main(){ print_int(123); return 4; }" "1234"
run_case "int main(){ print_int(-7); return 0; }" "-70"
run_case "int main(){ print_err(\"oops\"); return 7; }" 7
run_case "int main(){ print_str(\"x\\ny\"); return 2; }" "x
y2"

echo "== v4/B2g：逻辑 && || !（非短路，0/1 规整）与 void/注释 =="
run_case "int main(){ return (1&&1) + (1&&0); }" 1
run_case "int main(){ return (0||1) + (0||0); }" 1
run_case "int main(){ return !0 + !7; }" 1
run_case "void f(){ print_str(\"z\"); } int main(){ f(); return 4; }" "z4"
run_case "int main(){ /* 注释 */ int a; a=3; return a; }" 3

echo "== B5 面扩张：char*/int* 形参（链上扩张演示轮；期望值手算） =="
run_case "int sl(char *s){ int n; n=0; while(s[n]!=0){ n=n+1; } return n; } int main(){ print_int(sl(\"hello\")); return 0; }" 50
run_case "char b[4]; int sl(char *s){ int n; n=0; while(s[n]!=0){ n=n+1; } return n; } int main(){ b[0]='x'; b[1]='y'; b[2]=0; print_int(sl(b)); return 0; }" 20
run_case "char b[4]; int sl(char *s){ int n; n=0; while(s[n]!=0){ n=n+1; } return n; } int main(){ b[0]='x'; b[1]='y'; b[2]='z'; b[3]=0; return sl(b)*10+sl(\"ok\"); }" 32
run_case "int sum2(int *p, int n){ int i; int s; s=0; i=0; while(i<n){ s=s+p[i]; i=i+1; } return s; } int ga[3]; int main(){ ga[0]=1; ga[1]=2; ga[2]=3; return sum2(ga,3); }" 6
run_case "int cv(char *a, char *b){ return a[0]+b[0]; } int main(){ return cv(\"AB\",\"yz\"); }" 186
run_case "void sh(char *s){ print_str(s); } int main(){ sh(\"hi\"); return 1; }" hi1
run_case "int b[3]; void seta(int *p, int i, int v){ p[i]=v; } int main(){ int s; seta(b,1,7); s=b[1]; return s; }" 7
run_case "char c[3]; void setc(char *p, int v){ p[0]=v; } int main(){ setc(c,65); return c[0]; }" 65
run_case "char g[4]; void put(char *s, int i){ g[i]=s[0]; } int main(){ put(\"Z\",2); return g[2]; }" 90
run_case "int f(char *s){ return s[0]; } int main(){ return f(\"a\")+f(\"b\"); }" 195

echo "== P4-II T1：const/volatile 吸收 + 指针声明符（多级 *、*+[N]；期望值手算） =="
run_case "int const g=7; int main(){ const int x; x=5; volatile int y; y=x*g; return y; }" 35
run_case "int f(const int a, volatile int b){ return a+b; } int main(){ return f(1,2); }" 3
run_case "char const *s; int main(){ s=\"ab\"; return 1; }" 1
run_case "int main(){ char *s; s=\"ab\"; return s[0]; }" 97
run_case "int main(){ int *p; int **q; p=7; q=8; return p+q; }" 15
run_case "int f(char *p){ return p[0]+p[1]; } int main(){ char *s; s=\"hi\"; return f(s); }" 209
run_case "int *g; int main(){ g=5; return 1; }" 1
run_case "int *a[3]; int main(){ a[0]=1; a[1]=2; a[2]=3; return a[0]+a[1]+a[2]; }" 6

echo "== P4-II T2：三目 ?: + 逗号表达式 + sizeof（期望值手算） =="
run_case "int main(){ return 1?7:9; }" 7
run_case "int main(){ return 0?7:9; }" 9
run_case "int main(){ int a; a=3; return a>2?a*2:a*3; }" 6
run_case "int main(){ return (1?2:3) + (0?4:5); }" 7
run_case "int main(){ int x; x=5; return x>0?(x<3?1:2):3; }" 2
run_case "int main(){ int x; x=-1; return x>0?1:x<0?-1:0; }" -1
run_case "int f(int a){ return a?1:2; } int main(){ return f(0)+f(9); }" 3
run_case "int main(){ int a; int b; a=(1,2,3); b=7; return a+b; }" 10
run_case "int main(){ int x; x=(1,2,3,9); return x; }" 9
run_case "int main(){ int s; s=0; s=(s+1,s+2); return s; }" 2
run_case "int main(){ return sizeof(int); }" 4
run_case "int main(){ return sizeof(char); }" 1
run_case "char c[4]; int ia[3]; int main(){ return sizeof(c)+sizeof(ia); }" 16
run_case "int main(){ char *p; return sizeof(p); }" 4

echo "== P4-II T3：位运算 & | ^ ~ << >> + % 取模（期望值手算；% 由旧错误用例转正） =="
run_case "int main(){ return 2%3; }" 2
run_case "int main(){ return 6%4; }" 2
run_case "int main(){ return -7%3; }" -1
run_case "int main(){ return 7%3 + 5%2; }" 2
run_case "int main(){ return 12 & 10; }" 8
run_case "int main(){ return 12 | 3; }" 15
run_case "int main(){ return 12 ^ 6; }" 10
run_case "int main(){ return ~0; }" -1
run_case "int main(){ return 1 << 4; }" 16
run_case "int main(){ return 256 >> 3; }" 32
run_case "int main(){ return (1<<4) + (8>>1) + (5%3); }" 22
run_case "int main(){ int a; a=(1<<3)|2; return a; }" 10
run_case "int main(){ return 7 & 3; }" 3
run_case "int main(){ return 1 | 2 | 4; }" 7
run_case "int main(){ return 1|2&3; }" 3
run_case "int main(){ return 1+2<<1; }" 6
run_case "int main(){ return 5 ^ 1 ^ 4; }" 0
run_case "int main(){ return ~5 & 3; }" 2

echo "== P4-II T4：switch/case/default（fallthrough；期望值手算） =="
run_case "int main(){ int x; x=2; switch(x){ case 1: return 10; case 2: return 20; case 3: return 30; } return 99; }" 20
run_case "int main(){ int x; x=5; switch(x){ case 1: return 10; case 2: return 20; default: return 40; } }" 40
run_case "int main(){ int x; x=1; switch(x){ case 1: break; case 2: return 20; } return 7; }" 7
run_case "int main(){ int x; x=1; switch(x){ case 1: x=5; case 2: x=x+1; break; } return x; }" 6
run_case "int main(){ int s; int i; s=0; for(i=0;i<4;i=i+1){ switch(i){ case 0: s=s+1; break; case 1: s=s+10; break; case 2: s=s+100; break; default: s=s+1000; } } return s; }" 1111
run_case "int x; void f(int v){ switch(v){ case 65: x=1; break; default: x=2; } } int main(){ f(65); return x; }" 1
run_case "int main(){ int x; x=3; switch(x){ case 1: return 10; case 3: return 30; case 2: return 20; } return 0; }" 30
run_case "int main(){ int x; x=0; switch(x){ case 0: x=9; break; default: x=8; } return x; }" 9
run_case "int main(){ int x; x=99; switch(x){ default: x=1; case 5: x=x*10; break; } return x; }" 10
run_case "int main(){ int x; x=2; switch(x){ case 1: { int y; y=1; return y; } case 2: { int y; y=2; return y; } } return 0; }" 2
run_case "int main(){ int x; x=1; switch(x){ case 1: switch(x){ case 1: return 11; default: return 12; } default: return 13; } }" 11

echo "== P4-II T5：enum 枚举常量 + typedef 类型别名（期望值手算） =="
run_case "enum { A, B, C }; int main(){ return A*100+B*10+C; }" 12
run_case "enum { X=5, Y, Z }; int main(){ return X*100+Y*10+Z; }" 567
run_case "enum E { P, Q }; int main(){ return Q; }" 1
run_case "enum { RED, GRN, BLU }; int main(){ int c; c=GRN; switch(c){ case RED: return 1; case GRN: return 2; case BLU: return 3; } return 0; }" 2
run_case "enum { A=10, B=20 }; int main(){ int x; x=A+B; return x; }" 30
run_case "typedef int I; int main(){ I a; I b; a=3; b=4; return a+b; }" 7
run_case "typedef char C; int main(){ C c; c=65; return c; }" 65
run_case "typedef int I; int f(I a, I b){ return a*b; } int main(){ return f(3,4); }" 12
run_case "typedef int I; I g; int main(){ g=9; return g; }" 9
run_case "typedef int I; void f(I *p){ p[0]=5; } int g[2]; int main(){ f(g); return g[0]; }" 5

echo "== P4-II T7：一元 * 解引用读 + & 取址 + 二维全局数组（期望值手算；*写/&a[0]登记不支持） =="
run_case "int main(){ int x; int *p; x=7; p=&x; return *p; }" 7
run_case "int g; int *p; int main(){ g=9; p=&g; return *p; }" 9
run_case "int f(int *p){ return *p; } int main(){ int x; int *q; x=6; q=&x; return f(q); }" 6
run_case "int a[3][2]; int main(){ a[0][1]=5; a[2][0]=7; return a[0][1]+a[2][0]; }" 12
run_case "int a[2][3]; int main(){ int s; int i; int j; s=0; for(i=0;i<2;i=i+1){ for(j=0;j<3;j=j+1){ a[i][j]=i*10+j; } } return a[1][2]+a[0][2]; }" 14
run_case "char c[2][2]; int main(){ c[0][1]=65; c[1][0]=66; return c[0][1]+c[1][0]; }" 131
run_case "int a[3][4]; int main(){ int s; s=0; s=s+sizeof(a); return s; }" 48

echo "== P4-II T6：struct/union（成员布局/点访问/嵌套/整值赋值/sizeof；期望值手算） =="
run_case "struct P { int x; int y; }; struct P g; int main(){ g.x=5; g.y=7; return g.x*10+g.y; }" 57
run_case "struct P { int a; int b; }; int main(){ struct P s; s.a=3; s.b=4; return s.a*10+s.b; }" 34
run_case "struct C { char c; int i; }; int main(){ struct C s; s.c=65; s.i=7; return s.c+s.i; }" 72
run_case "struct S { char a; int b; }; int main(){ return sizeof(struct S); }" 8
run_case "struct P { int x; int y; }; struct P g1; struct P g2; int main(){ g1.x=1; g1.y=2; g2=g1; return g2.x*10+g2.y; }" 12
run_case "struct P { int a; int b; }; int main(){ struct P s1; struct P s2; s1.a=5; s1.b=6; s2=s1; return s2.a*10+s2.b; }" 56
run_case "struct P { int x; int y; }; struct R { struct P p; int z; }; int main(){ struct R r; r.p.x=1; r.p.y=2; r.z=3; return r.p.x*100+r.p.y*10+r.z; }" 123
run_case "struct C { char c; char d; }; int main(){ struct C s; s.c=65; s.d=66; return s.c*10+s.d; }" 716
run_case "union U { char c; int i; }; int main(){ union U u; u.i=0; u.c=68; return u.c; }" 68
run_case "union U { char a; int b; }; int main(){ return sizeof(union U); }" 4
run_case "union U { char a; int b; }; union U g; int main(){ g.b=7; return g.b; }" 7
run_case "struct P { int x; int y; }; union U { char c; struct P p; }; int main(){ union U u; u.p.x=5; return u.p.x; }" 5

echo "== P4-II T7：局部一/二维数组（int/char；3 维登记限制） =="
run_case "int main(){ int a[3]; a[0]=1; a[1]=2; a[2]=3; return a[0]+a[1]+a[2]; }" 6
run_case "int main(){ int a[2][3]; int s; int i; int j; s=0; for(i=0;i<2;i=i+1){ for(j=0;j<3;j=j+1){ a[i][j]=i*10+j; } } return a[1][2]+a[0][2]; }" 14
run_case "int main(){ char c[4]; c[0]=65; c[1]=66; return c[0]+c[1]; }" 131
run_case "int main(){ char c[2][2]; c[0][1]=65; c[1][0]=66; return c[0][1]+c[1][0]; }" 131
run_case "int sum(int *p,int n){ int i; int s; s=0; i=0; while(i<n){ s=s+p[i]; i=i+1; } return s; } int main(){ int a[3]; a[0]=1; a[1]=2; a[2]=3; return sum(a,3); }" 6
run_case "int main(){ int a[4]; return sizeof(a); }" 16
run_case "int main(){ int a[2][2]; a[0][0]=1; a[0][1]=2; a[1][0]=3; a[1][1]=4; return a[0][1]*10+a[1][0]; }" 23
run_case "int f(int *p){ return p[0]+p[1]; } int main(){ int a[2]; a[0]=7; a[1]=8; return f(a); }" 15
run_case "int main(){ int a[3]; a[0]=5; int *p; p=a; return p[0]; }" 5

echo "== P4-II T6/T7 错误用例 =="
run_err "struct P { int x; }; int main(){ struct P s; return s.y; }" 2

echo "== P4-II 剩余限制：匿名嵌套 struct =="
run_case "struct { int x; struct { int y; } s; } v; int main(){ v.x=1; v.s.y=2; return v.x+v.s.y; }" 3
run_case "struct S { struct { int a; int b; } in; int c; }; int main(){ struct S s; s.in.a=1; s.in.b=2; s.c=3; return s.in.a*100+s.in.b*10+s.c; }" 123

echo "== P4-II 剩余限制：struct 数组 / 参数 / 初始化 =="
run_case "struct P { int x; int y; }; struct P a[2] = { {3,4}, {5,6} }; int main(){ return a[0].x*100+a[0].y*10+a[1].x; }" 345
run_case "struct P { int x; }; struct P g = {7}; int main(){ return g.x; }" 7
run_case "int ia[3] = {9,10,11}; int main(){ return ia[0]+ia[2]; }" 20
run_case "char cb[3] = {65,66,67}; int main(){ return cb[0]+cb[1]+cb[2]; }" 198
run_case "struct P { int x; int y; }; int main(){ struct P arr[2]; arr[0].x=3; arr[0].y=4; arr[1].x=5; arr[1].y=6; return arr[1].x*10+arr[0].y; }" 54
run_case "struct P { int x; }; int f(struct P s){ return s.x; } int main(){ struct P a; a.x=5; return f(a); }" 5
run_case "struct P { int x; int y; }; int f(struct P s){ return s.x*10+s.y; } int main(){ struct P a; a.x=3; a.y=4; return f(a); }" 34
run_case "struct P { int x; }; struct P g; int f(struct P s){ return s.x+1; } int main(){ g.x=6; return f(g); }" 7

echo "== P4-II 剩余限制：&a[i] / &s.m / 声明符括号 / -> =="
run_case "int a[3]; struct { int m; } s; int main(){ a[0]=5; s.m=6; return *&a[0] + *&s.m; }" 11
run_case "int main(){ int a[3]; a[1]=7; int *p; p=&a[1]; return *p; }" 7
run_case "struct P { int x; int y; }; int main(){ struct P s; s.x=9; int *p; p=&s.x; return *p+1; }" 10
run_case "int (*p)[3]; int a[3] = {9,10,11}; int main(){ p=&a; return (*p)[1]; }" 10
run_case "struct P { int x; int y; }; int main(){ struct P s; struct P *p; s.x=5; s.y=7; p=&s; return p->x+p->y; }" 12
run_case "struct P { int x; }; int main(){ struct P s; struct P *p; s.x=0; p=&s; p->x=9; return s.x; }" 9
run_case "struct P { int a; int b; }; struct P g; int main(){ g.a=3; g.b=4; struct P *p; p=&g; return p->a*p->b; }" 12
run_case "struct C { char c; int i; }; int main(){ struct C s; struct C *p; s.c=65; s.i=7; p=&s; return p->c+p->i; }" 72

echo "== P4-II 剩余限制：三维数组（局部/全局/int/char/初始化） =="
run_case "int a[2][2][2]; int main(){ a[1][1][1]=5; a[0][0][0]=2; return a[1][1][1]+a[0][0][0]; }" 7
run_case "int ga[2][2][2] = { {1,2}, {3,4}, {5,6}, {7,8} }; int main(){ return ga[1][1][1]; }" 8
run_case "int main(){ int a[2][2][2]; a[0][1][1]=5; a[1][0][1]=3; return a[0][1][1]-a[1][0][1]; }" 2
run_case "int main(){ int a[2][3][2]; a[1][2][1]=7; int *p; p=a; return a[1][2][1]; }" 7
run_case "int ca[2][2][2]; int main(){ ca[1][0][1]=65; return ca[1][0][1]; }" 65

echo "== v2 错误用例（缺 main/未定义/重定义/语法） =="
run_err "int f(){ return 1; }" 2
run_err "int main(){ return g(1); }" 2
run_err "int f(){ return 1; } int f(){ return 2; } int main(){ return 0; }" 2
run_err "int main(){ return f(3; }" 2
run_err "int main(){ return 1 }" 2

echo "== v3/B2d 错误用例（缺括号） =="
run_err "int main(){ int i; for(i=0;i<3;{ i=i+1; } }" 2

echo "== v3/B2e 错误用例（同作用域重声明：同块 / 参数·函数体顶层） =="
run_err "int main(){ int a; int a; return 0; }" 2
run_err "int f(int a){ int a; return a; } int main(){ return 0; }" 2

echo "== v3/B2f 错误用例（循环外 break/continue、do-while 缺分号） =="
run_err "int main(){ break; return 0; }" 2
run_err "int main(){ continue; return 0; }" 2
run_err "int main(){ int i; i=0; do { i=i+1; } while(0) }" 2

echo "== P4-II 收口（2026-08-26）：& 三维/全局下标取址 =="
run_case "int ga[2][2][2]; int main(){ ga[0][0][0]=3; ga[1][1][1]=4; return *&ga[1][1][1]+ga[0][0][0]; }" 7
run_case "int main(){ int a[2][2][2]; a[0][1][1]=6; int *p; p=&a[0][1][1]; return *p; }" 6
run_case "int ga[2][2]; int main(){ ga[1][1]=9; return *&ga[1][1]; }" 9

echo "== P4-II 收口：后缀 [i] 写（数组指针 (*p)[i]=v，局部/全局） =="
run_case "int (*p)[3]; int a[3]; int main(){ p=&a; (*p)[2]=77; return a[2]; }" 77
run_case "int main(){ int a[2]; int (*p)[2]; p=&a; (*p)[1]=55; return a[1]; }" 55

echo "== P4-II 收口：struct 数组传参（元素 by-ref / 整体数组指针 / 指针下标 p[i].m） =="
run_case "struct P { int x; int y; }; struct P ga[2]; int f(struct P s){ return s.x*10+s.y; } int main(){ ga[0].x=3; ga[0].y=4; return f(ga[0]); }" 34
run_case "struct P { int x; }; struct P ga[2]; void f(struct P *p){ p[1].x=99; } int main(){ f(ga); return ga[1].x; }" 99
run_case "struct P { int x; int y; }; int sum2(struct P *p, int n){ int s; int i; s=0; i=0; while(i<n){ s=s+p[i].x; i=i+1; } return s; } int main(){ struct P a[2]; a[0].x=3; a[1].x=4; return sum2(a,2); }" 7
run_case "struct P { int x; }; int main(){ struct P s; struct P *p; s.x=5; p=&s; p[0].x=9; return s.x; }" 9

echo "== P4-II 收口：局部初始化器（标量/一维数组/char 字符串/struct/struct 数组/多声明链） =="
run_case "int main(){ int a=3; int b; b=a+1; return a*10+b; }" 34
run_case "int main(){ int a[3]={1,2,3}; return a[0]+a[1]+a[2]; }" 6
run_case "int main(){ char s[4]=\"ab\"; return s[0]+s[1]; }" 195
run_case "struct P { int x; int y; }; int main(){ struct P s={3,4}; return s.x*10+s.y; }" 34
run_case "struct C { char c; int i; }; int main(){ struct C s={65,7}; return s.c+s.i; }" 72
run_case "struct P { int x; }; int main(){ struct P a[2]={7,8}; return a[0].x+a[1].x; }" 15
run_case "int main(){ int a=5, b=6; return a*10+b; }" 56

echo "== P4-II 收口：struct 多重指针 -> 链（指针成员 m.n->v / 链写 / 偏置成员 / 全局） =="
run_case "struct N { int v; }; struct M { struct N *n; }; int main(){ struct N a; struct M m; a.v=7; m.n=&a; return m.n->v; }" 7
run_case "struct N { int v; }; struct M { struct N *n; }; int main(){ struct N a; struct M m; m.n=&a; m.n->v=9; return a.v; }" 9
run_case "struct N { int w; int v; }; struct M { struct N *n; int pad; }; int main(){ struct N a; struct M m; a.w=3; a.v=4; m.pad=0; m.n=&a; return m.n->w*10+m.n->v; }" 34
run_case "struct N { int v; }; struct M { struct N *n; }; struct N g1; struct M g2; int main(){ g1.v=5; g2.n=&g1; return g2.n->v; }" 5

echo "== B5 回归（2026-08-26 修复）：经典冒泡排序（嵌套 for + 变址比较 + swap） =="
run_case "int main(){ int a[5]; int i; int j; int t; int n; a[0]=5; a[1]=3; a[2]=4; a[3]=1; a[4]=2; n=5; for(i=0;i<n-1;i=i+1){ for(j=0;j<n-1-i;j=j+1){ if(a[j]>a[j+1]){ t=a[j]; a[j]=a[j+1]; a[j+1]=t; } } } return a[0]*10000+a[1]*1000+a[2]*100+a[3]*10+a[4]; }" 12345
run_case "int main(){ int a[4]; int i; int j; int t; int n; a[0]=4; a[1]=3; a[2]=2; a[3]=1; n=4; for(i=0;i<n-1;i=i+1){ for(j=0;j<n-1-i;j=j+1){ if(a[j]>a[j+1]){ t=a[j]; a[j]=a[j+1]; a[j+1]=t; } } } return a[0]*1000+a[1]*100+a[2]*10+a[3]; }" 1234

echo "== B5 回归：struct 自引用链表（自引用指针成员 + 多字母类型名 + 指针成员读 RHS） =="
run_case "struct node { int v; struct node *next; }; int main(){ struct node a; struct node b; struct node *p; int c; a.v=1; b.v=2; a.next=&b; b.next=0; c=0; p=&a; while(p!=0){ c=c+p->v; p=p->next; } return c; }" 3
run_case "struct node { int v; struct node *next; }; struct node g; int main(){ struct node a; struct node b; struct node c; int s; g.v=4; a.v=1; b.v=2; c.v=3; a.next=&b; b.next=&c; c.next=&g; g.next=0; s=0; struct node *p; p=&a; while(p!=0){ s=s+p->v; p=p->next; } return s; }" 10
run_case "struct ab { int x; }; int main(){ struct ab s; int v; s.x=5; v=s.x; return v*2; }" 10

echo "=============================="
echo "PASS=$PASS FAIL=$FAIL (用例 $((PASS+FAIL)) 个)"
[ "$FAIL" -eq 0 ]