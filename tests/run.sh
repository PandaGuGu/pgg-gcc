#!/bin/bash
# pggcc v3 自证测试（当前阶段不调用任何 C/C++ 编译器做行为对照）
# v3（P3）控制流：if/while/for、比较（== != < <= > >=）、块作用域；stdin 函数序列；
#       入口固定 main，结束打印 main 返回值；声明自证递归 fact(5)==120（B0 硬门槛）
# 流程：as --32 构建 pggcc3 -> echo 程序 | pggcc3 -> as --32 -> ld -m elf_i386(无crt) -> 运行比对期望值
# 用例程序无 libc（自带 _start + write/exit syscall）；期望值手算，与任何编译器无关
set -u
cd "$(dirname "$0")/.." || exit 1
mkdir -p build

echo "== 构建 pggcc3（无蛋：as + ld 汇编引导，不调用任何 C/C++ 编译器） =="
as --32 -o build/pggcc3.o src/pggcc3.s || { echo "BUILD FAILED(as)"; exit 1; }
ld -m elf_i386 -o build/pggcc3 build/pggcc3.o || { echo "BUILD FAILED(ld)"; exit 1; }

PASS=0; FAIL=0
run_case() {   # 成功用例：比对运行输出
    local prog="$1" expect="$2"
    if ! echo "$prog" | ./build/pggcc3 > /tmp/pggc3_case.s 2>/tmp/pggc3_err.txt; then
        echo "FAIL [$prog]: 编译失败: $(cat /tmp/pggc3_err.txt)"
        FAIL=$((FAIL+1)); return
    fi
    if ! as --32 -o /tmp/pggc3_case.o /tmp/pggc3_case.s 2>/tmp/pggc3_as_err.txt; then
        echo "FAIL [$prog]: 汇编失败: $(cat /tmp/pggc3_as_err.txt)"; FAIL=$((FAIL+1)); return
    fi
    if ! ld -m elf_i386 -o /tmp/pggc3_case.out /tmp/pggc3_case.o 2>/tmp/pggc3_ld_err.txt; then
        echo "FAIL [$prog]: 链接失败: $(cat /tmp/pggc3_ld_err.txt)"; FAIL=$((FAIL+1)); return
    fi
    local got
    got=$(/tmp/pggc3_case.out)
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
    if echo "$prog" | ./build/pggcc3 > /dev/null 2>/dev/null; then
        echo "FAIL [$prog]: 应编译失败但成功"; FAIL=$((FAIL+1)); return
    fi
    echo "$prog" | ./build/pggcc3 > /dev/null 2>/dev/null
    local rc=$?
    if [ "$rc" = "$expect" ]; then
        PASS=$((PASS+1))
        echo "PASS [$prog] -> exit $rc (期望 $expect)"
    else
        echo "FAIL [$prog]: 退出码 期望 $expect 得 $rc"
        FAIL=$((FAIL+1))
    fi
}

# 成功用例：if/else 双分支 / while 计数 / for 累和 / 循环体内块声明（栈平衡） /
#           块遮蔽出块恢复 / 递归 fact(5)==120 / 嵌套 if-else / else-if 链 / 比较作表达式
run_case "int main() { if (1) return 7; return 9; }" 7
run_case "int main() { if (0) return 1; else return 2; }" 2
run_case "int main() { int i; int s; i=0; s=0; while (i<5) { s=s+i; i=i+1; } return s; }" 10
run_case "int main() { int i; int s; s=0; for (i=0; i<5; i=i+1) { s=s+i; } return s; }" 10
run_case "int main() { int i; int s; s=0; for (i=0; i<5; i=i+1) { int t; t=i; s=s+t; } return s; }" 10
run_case "int main() { int a; a=1; { int a; a=2; } return a; }" 1
run_case "int fact(int n) { if (n<=1) return 1; return n*fact(n-1); } int main() { return fact(5); }" 120
run_case "int main() { if (2==2) { if (3!=3) return 5; else return 8; } return 0; }" 8
run_case "int main() { int a; a=5; if (a<3) return 1; else if (a<10) return 2; else return 3; }" 2
run_case "int main() { int a; a=3; return (a>2)*10 + (a<2); }" 10
run_case "int main() { int a; a=0; if (0) { a=5; } return a; }" 0
# 错误用例：同块重名 exit 2；缺 ')' exit 2；孤 else exit 2；cond 用未声明变量 exit 2
run_err "int main() { { int a; int a; } return 0; }" 2
run_err "int main() { if (1 return 2; }" 2
run_err "int main() { else return 1; }" 2
run_err "int main() { if (zzz) return 1; return 0; }" 2

echo "=============================="
echo "PASS=$PASS FAIL=$FAIL (用例 $((PASS+FAIL)) 个)"
[ "$FAIL" -eq 0 ]