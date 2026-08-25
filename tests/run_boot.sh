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

echo "== v2 错误用例（缺 main/未定义/重定义/语法） =="
run_err "int f(){ return 1; }" 2
run_err "int main(){ return g(1); }" 2
run_err "int f(){ return 1; } int f(){ return 2; } int main(){ return 0; }" 2
run_err "int main(){ return f(3; }" 2
run_err "int main(){ return 1 }" 2

echo "== v3/B2d 错误用例（缺括号/非法算子） =="
run_err "int main(){ int i; for(i=0;i<3;{ i=i+1; } }" 2
run_err "int main(){ return 2&&3; }" 1

echo "== v3/B2e 错误用例（同作用域重声明：同块 / 参数·函数体顶层） =="
run_err "int main(){ int a; int a; return 0; }" 2
run_err "int f(int a){ int a; return a; } int main(){ return 0; }" 2

echo "== v3/B2f 错误用例（循环外 break/continue、do-while 缺分号） =="
run_err "int main(){ break; return 0; }" 2
run_err "int main(){ continue; return 0; }" 2
run_err "int main(){ int i; i=0; do { i=i+1; } while(0) }" 2

echo "=============================="
echo "PASS=$PASS FAIL=$FAIL (用例 $((PASS+FAIL)) 个)"
[ "$FAIL" -eq 0 ]