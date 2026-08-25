#!/bin/bash
# pggcc v4 自证测试（当前阶段不调用任何 C/C++ 编译器做行为对照）
# v4（P4 一期 编译器核心子集 B1——生蛋原料）：
#   类型系统 int/char/指针/数组；字符/字符串字面量；逻辑短路；左值体系（& * [] ++ -- 复合赋值）；
#   do-while/break/continue；强转；全局变量与 .data/.bss/.rodata；注释。
#   输入 stdin 函数序列；入口固定 main，结束打印 main 返回值；运行时含 f_print_str。
# 流程：as --32 构建 pggcc4 -> printf 程序 | pggcc4 -> as --32 -> ld -m elf_i386(无crt) -> 运行比对
# 期望值手算，与任何编译器无关；错误用例退出码 2。
set -u
cd "$(dirname "$0")/.." || exit 1
mkdir -p build

echo "== 构建 pggcc4（无蛋：as + ld 汇编引导，不调用任何 C/C++ 编译器） =="
as --32 -o build/pggcc4.o src/pggcc4.s || { echo "BUILD FAILED(as)"; exit 1; }
ld -m elf_i386 -o build/pggcc4 build/pggcc4.o || { echo "BUILD FAILED(ld)"; exit 1; }

PASS=0; FAIL=0
run_case() {   # 成功用例：比对运行输出
    local prog="$1" expect="$2"
    if ! printf '%s' "$prog" | timeout 5 ./build/pggcc4 > /tmp/pg4_case.s 2>/tmp/pg4_err.txt; then
        echo "FAIL [$prog]: 编译失败: $(cat /tmp/pg4_err.txt)"
        FAIL=$((FAIL+1)); return
    fi
    if ! as --32 -o /tmp/pg4_case.o /tmp/pg4_case.s 2>/tmp/pg4_as_err.txt; then
        echo "FAIL [$prog]: 汇编失败: $(cat /tmp/pg4_as_err.txt)"; FAIL=$((FAIL+1)); return
    fi
    if ! ld -m elf_i386 -o /tmp/pg4_case.out /tmp/pg4_case.o 2>/tmp/pg4_ld_err.txt; then
        echo "FAIL [$prog]: 链接失败: $(cat /tmp/pg4_ld_err.txt)"; FAIL=$((FAIL+1)); return
    fi
    local got
    got=$(timeout 5 /tmp/pg4_case.out)
    if [ "$got" = "$expect" ]; then
        PASS=$((PASS+1))
        echo "PASS [$prog] = $got"
    else
        echo "FAIL [$prog]: 期望 $expect 得 $got"
        FAIL=$((FAIL+1))
    fi
}
run_err() {    # 错误用例：断言编译失败且退出码=2
    local prog="$1" expect="$2"
    if printf '%s' "$prog" | timeout 5 ./build/pggcc4 > /dev/null 2>/dev/null; then
        echo "FAIL [$prog]: 应编译失败但成功"; FAIL=$((FAIL+1)); return
    fi
    printf '%s' "$prog" | timeout 5 ./build/pggcc4 > /dev/null 2>/dev/null
    local rc=$?
    if [ "$rc" = "$expect" ]; then
        PASS=$((PASS+1))
        echo "PASS [$prog] -> exit $rc (期望 $expect)"
    else
        echo "FAIL [$prog]: 退出码 期望 $expect 得 $rc"
        FAIL=$((FAIL+1))
    fi
}

# ---- 基线回归（v0-v3 保留路径） ----
run_case "int main() { return 42; }" 42
run_case "int fact(int n) { if (n<=1) return 1; return n*fact(n-1); } int main() { return fact(5); }" 120
run_case "int main() { int i; int s; s=0; for (i=0; i<5; i=i+1) { s=s+i; } return s; }" 10

# ---- 1. 字符串：len("hello")==5；char 数组逐字节写读；print_str ----
#    注：本阶段限定"函数先定义后调用"（无处前向声明/隐式声明），故 len 均置于 main 前（登记限制）
run_case "int len(char *s){ int n; n=0; while(s[n]!=0){ n=n+1; } return n; } int main(){ return len(\"hello\"); }" 5
run_case "int len(char *s){ int n; n=0; while(s[n]!=0){ n=n+1; } return n; } int main(){ char buf[8]; buf[0]='A'; buf[1]='B'; buf[2]=0; return buf[0]+buf[1]+len(buf); }" 133
run_case "int main(){ print_str(\"hi\"); return 5; }" "hi5"
run_case "int len(char *s){ int n; n=0; while(s[n]!=0){ n=n+1; } return n; } int main(){ return len(\"a\\nb\\tc\"); }" 5

# ---- 2. 数组：sum(a,5)==15；a[2]==2；a 与 &a[0] 相等 ----
run_case "int sum(int *a, int n){ int i; int s; s=0; for(i=0;i<n;i=i+1){ s=s+a[i]; } return s; } int main(){ int a[5]; a[0]=1;a[1]=2;a[2]=3;a[3]=4;a[4]=5; return sum(a,5); }" 15
run_case "int main(){ int a[3]; a[2]=2; return a[2]; }" 2
run_case "int main(){ int a[2]; a[0]=7; return a==(&a[0]); }" 1
run_case "int main(){ char c[3]; c[0]='x'; c[1]='y'; return c[0]+c[1]; }" 241

# ---- 3. 指针：swap；指针遍历累加；p++ 步进；int* 步进 4 / char* 步进 1 ----
run_case "void swap(int *x,int *y){ int t; t=*x; *x=*y; *y=t; } int main(){ int a; int b; a=3; b=5; swap(&a,&b); return a*10+b; }" 53
run_case "int main(){ int a[4]; int *p; int i; int s; a[0]=1;a[1]=2;a[2]=3;a[3]=4; s=0; p=&a[0]; i=0; while(i<4){ s=s+(*p); p=p+1; i=i+1; } return s; }" 10
run_case "int main(){ int a[3]; int *p; a[0]=7; a[1]=8; a[2]=9; p=&a[0]; p++; return *p; }" 8
run_case "int main(){ int a[2]; int *p; a[0]=1; a[1]=2; p=a; p=p+1; return *p; }" 2

# ---- 4. char：'A'+1=='B'；'\377' 零扩展=255；字符比较 ----
run_case "int main(){ return 'A'+1=='B'; }" 1
run_case "int main(){ char c; c='\\377'; return c; }" 255
run_case "int main(){ char c; c=200; return c; }" 200
run_case "int main(){ char a; char b; a='x'; b='y'; return (a<b) + (a==a) + (b>a); }" 3

# ---- 5. 逻辑短路：(1||f()) 不调用 f；&& / ! 返回 0/1 ----
run_case "int n; int f(){ n=n+1; return 1; } int main(){ n=0; if((0&&f())||(1||f())){ } return n; }" 0
run_case "int main(){ return (1&&0) + (1&&1) + !0 + !7; }" 2
run_case "int main(){ return (1||0) && (0||1); }" 1

# ---- 6. do-while / break / continue ----
run_case "int main(){ int i; int s; i=0; s=0; do { s=s+i; i=i+1; } while(i<5); return s; }" 10
run_case "int main(){ int i; int s; s=0; for(i=0;i<10;i=i+1){ if(i==4){ break; } s=s+i; } return s; }" 6
run_case "int main(){ int i; int s; s=0; for(i=0;i<5;i=i+1){ if(i==2){ continue; } s=s+i; } return s; }" 8
run_case "int main(){ int i; int s; i=0; s=0; while(i<5){ i=i+1; if(i==3){ continue; } s=s+i; } return s; }" 12
run_case "int main(){ int i; int s; i=0; s=0; do { i=i+1; if(i==2){ continue; } s=s+i; } while(i<4); return s; }" 8

# ---- 7. 复合赋值与 ++/-- 前后缀 ----
run_case "int main(){ int s; int i; s=0; i=3; s+=i; return s; }" 3
run_case "int main(){ int a; int b; int c; a=1; b=2; c=3; a+=b+=c; return a*100+b*10+c; }" 653
run_case "int main(){ int a; int b; a=5; b=2; a+=b; a-=1; a*=3; a/=2; return a; }" 9
run_case "int main(){ int i; int a; int b; i=5; a=i++; b=i; return a*10+b; }" 56
run_case "int main(){ int i; int a; i=5; a=++i; return a*10+i; }" 66
run_case "int main(){ int i; i=4; --i; return i--; }" 3
run_case "int main(){ char c; c='A'; c++; c++; return c; }" 67

# ---- 8. 全局变量：跨函数累计；全局数组初始化；char 全局；.bss 写读 ----
run_case "int g; void bump(){ g=g+1; } int main(){ g=10; bump(); bump(); return g; }" 12
run_case "int ga[3] = {1,2,3}; int main(){ int s; s=0; s=ga[0]+ga[1]+ga[2]; return s; }" 6
run_case "char gc = 'K'; int main(){ return gc; }" 75
run_case "int gz; int main(){ gz=7; return gz; }" 7
run_case "char gs[5] = {'a','b',0}; int main(){ return gs[0]+gs[1]; }" 195
run_case "char s[4] = \"hi\"; int main(){ return s[0]+s[1]; }" 209
run_case "int gm[4] = {1,2}; int main(){ return gm[0]+gm[1]+gm[2]+gm[3]; }" 3

# ---- 9. 强转：截断/保值/指针字节读写 ----
run_case "int main(){ char c; int i; i=300; c=(char)i; return c; }" 44
run_case "int main(){ char c; c='A'; return (int)c; }" 65
run_case "int main(){ int x; char *p; x=1*16777216+2*65536+3*256+4; p=(char *)&x; return p[0]+p[1]*10; }" 34
run_case "int main(){ int x; int *p; x=5; p=(int *)x; return (int)p; }" 5
run_case "int main(){ int i; i=300; return (char)i + (char)i; }" 88

# ---- 10. 综合：strcpy/strcmp 双函数互调（B2 预演） ----
run_case "char *strcpy(char *d, char *s){ int i; i=0; while(s[i]!=0){ d[i]=s[i]; i=i+1; } d[i]=0; return d; }
int strcmp(char *a, char *b){ int i; i=0; while(a[i]!=0 || b[i]!=0){ if(a[i]!=b[i]){ if(a[i]<b[i]) return -1; return 1; } i=i+1; } return 0; }
int main(){ char x[8]; char y[8]; strcpy(x,\"abc\"); strcpy(y,\"abc\"); if(strcmp(x,y)==0){ strcpy(y,\"abd\"); return strcmp(x,y)+5; } return 99; }" 4
run_case "char *strcpy(char *d, char *s){ int i; i=0; while(s[i]!=0){ d[i]=s[i]; i=i+1; } d[i]=0; return d; }
int main(){ char a[6]; strcpy(a,\"cba\"); return strcpy(a,a)==a; }" 1

# ---- 注释 ----
run_case "int main(){ /* 注释 */ int a; /* 中间注释 */ a=3; return a; /* 尾注释 */ }" 3

# ---- 错误用例：非左值赋值 / 括号非左值 / 数组整体赋值 / break 在循环外 / 复合声明符 / 非常量全局初值 / 重定义内建 ----
run_err "int main(){ 3=4; return 0; }" 2
run_err "int main(){ int a; int b; (a+b)=5; return 0; }" 2
run_err "int main(){ int a[3]; int b[3]; a=b; return 0; }" 2
run_err "int main(){ break; return 0; }" 2
run_err "int main(){ int *p[3]; return 0; }" 2
run_err "int g = i; int main(){ return 0; }" 2
run_err "int print_str(int x){ return x; } int main(){ return 0; }" 2
run_err "int main(){ char s[3] = {1,2,3,4}; return 0; }" 2

echo "=============================="
echo "PASS=$PASS FAIL=$FAIL (用例 $((PASS+FAIL)) 个)"
[ "$FAIL" -eq 0 ]