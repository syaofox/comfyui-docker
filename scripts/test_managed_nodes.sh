#!/bin/bash
# 自定义节点托管台账/清理逻辑的本地单元测试
#
# 说明：
#   - 在宿主机直接运行，不需要容器；依赖 bash / git / awk / sort / date。
#   - 从 entrypoint.sh 中按标记提取 managed-nodes-helpers 函数，用假目录验证
#     “收养 / 软删除 / 恢复 / delete / off / held / 未知值回退”等行为，
#     不会触碰真实 custom_nodes。
#   - 用法：bash scripts/test_managed_nodes.sh
#     需要保留测试现场时：KEEP_TEST_ARTIFACTS=1 bash scripts/test_managed_nodes.sh
#
# 相关文档：docs/自定义节点清理与托管台账.md
set -u

EP="$(cd "$(dirname "$0")/.." && pwd)/entrypoint.sh"
ROOT="$(mktemp -d)"
if [ "${KEEP_TEST_ARTIFACTS:-0}" != "1" ]; then
    trap 'rm -rf "$ROOT"' EXIT
else
    echo "test artifacts: $ROOT"
fi

[ -f "$EP" ] || { echo "FAIL: entrypoint.sh not found: $EP"; exit 1; }
mkdir -p "$ROOT/app/custom_nodes" "$ROOT/hash"

sed -n '/# >>> managed-nodes-helpers/,/# <<< managed-nodes-helpers/p' "$EP" > "$ROOT/helpers.sh"
[ -s "$ROOT/helpers.sh" ] || { echo "FAIL: cannot extract helpers from $EP"; exit 1; }

export APP_DIR="$ROOT/app"
export NODE_MANIFEST="$APP_DIR/custom_nodes/.managed_nodes"
export NODE_PRUNE_LOG="$APP_DIR/custom_nodes/.pruned.log"
export HASH_DIR="$ROOT/hash"
export GH=""
export PRUNE_CUSTOM_NODES=disabled

# shellcheck disable=SC1090
source "$ROOT/helpers.sh"

mk_git_dir() { # path origin
    mkdir -p "$1"
    git -C "$1" init -q
    git -C "$1" remote add origin "$2"
}
fail() { echo "FAIL: $1"; exit 1; }

# 场景 1：第一次运行（无台账）→ 收养 origin 匹配的目录
DEFAULT_NODES=("owner/adopt.git|adopt")
mk_git_dir "$APP_DIR/custom_nodes/adopt" "https://github.com/owner/adopt.git"
sync_custom_nodes >/dev/null
[ "$(manifest_state adopt)" = "active" ] || fail "adopt 应被收养"

# 场景 2：origin 不匹配的同名目录 → 不纳管、不动磁盘
DEFAULT_NODES=("owner/fake.git|fake" "owner/adopt.git|adopt")
mk_git_dir "$APP_DIR/custom_nodes/fake" "https://github.com/other/fake.git"
sync_custom_nodes >/dev/null
[ -z "$(manifest_state fake)" ] || fail "origin 不匹配不应纳管"
[ -d "$APP_DIR/custom_nodes/fake" ] || fail "手工目录被动过"

# 场景 3：注释掉托管的 adopt → 软删除为 adopt.disabled；无关目录不动
mkdir -p "$APP_DIR/custom_nodes/stranger"   # 无台账、不在列表
DEFAULT_NODES=("owner/fake.git|fake")
sync_custom_nodes >/dev/null
[ -d "$APP_DIR/custom_nodes/adopt.disabled" ] || fail "adopt 应被软删除"
[ ! -d "$APP_DIR/custom_nodes/adopt" ] || fail "adopt 原目录应已改名"
[ -d "$APP_DIR/custom_nodes/stranger" ] || fail "stranger 不应被动"
grep -q '^adopt|owner/adopt.git|disabled$' "$NODE_MANIFEST" || fail "台账 state 应为 disabled"
grep -q 'disable adopt' "$NODE_PRUNE_LOG" || fail "缺少 .pruned.log 记录"

# 场景 4：off 模式 → 只维护台账，不处理磁盘；disabled 记录保留（供恢复）
PRUNE_CUSTOM_NODES=off
DEFAULT_NODES=()
sync_custom_nodes >/dev/null
[ -d "$APP_DIR/custom_nodes/adopt.disabled" ] || fail "off 不应删目录"
[ "$(manifest_state adopt)" = "disabled" ] || fail "off 模式应保留 disabled 记录"

# 场景 5：取消注释（重新加入 desired）→ 记录保持 disabled（下一次启动由 clone 段恢复）
DEFAULT_NODES=("owner/adopt.git|adopt")
sync_custom_nodes >/dev/null
[ "$(manifest_state adopt)" = "disabled" ] || fail "重新加入列表后应保持 disabled 以便恢复"

# 场景 6：delete 模式 → 已禁用目录被彻底删除，记录消失
PRUNE_CUSTOM_NODES=delete
DEFAULT_NODES=()
sync_custom_nodes >/dev/null
[ ! -e "$APP_DIR/custom_nodes/adopt.disabled" ] || fail "delete 应删除 .disabled"
[ -z "$(manifest_state adopt)" ] || fail "delete 后不应保留记录"

# 场景 7：delete 模式删除仍在磁盘上的托管节点
mk_git_dir "$APP_DIR/custom_nodes/gone" "https://github.com/owner/gone.git"
printf 'gone|owner/gone.git|active\n' >> "$NODE_MANIFEST"
sync_custom_nodes >/dev/null
[ ! -e "$APP_DIR/custom_nodes/gone" ] || fail "delete 应删除 gone"
[ -z "$(manifest_state gone)" ] || fail "gone 记录应消失"

# 场景 8：未知 PRUNE_CUSTOM_NODES → 回退 disabled 并告警，不误删
mk_git_dir "$APP_DIR/custom_nodes/gone2" "https://github.com/owner/gone2.git"
printf 'gone2|owner/gone2.git|active\n' >> "$NODE_MANIFEST"
PRUNE_CUSTOM_NODES=bogus
sync_custom_nodes 2>&1 | grep -q 'WARNING' || fail "未知模式应告警"
[ -d "$APP_DIR/custom_nodes/gone2.disabled" ] || fail "未知模式应回退软删除"

# 场景 9：desired 目录是 .disabled 且无台账记录 → held（手工禁用，不自动恢复）
PRUNE_CUSTOM_NODES=disabled
mkdir -p "$APP_DIR/custom_nodes/heldNode.disabled"
DEFAULT_NODES=("owner/held.git|heldNode")
sync_custom_nodes >/dev/null
[ "$(manifest_state heldNode)" = "held" ] || fail "手工禁用应为 held（当前: $(manifest_state heldNode)）"

# 场景 10：held 记录 + 从列表移除 → 保持 held（不变成可自动恢复的 disabled）
printf 'held2|owner/held2.git|held\n' >> "$NODE_MANIFEST"
mkdir -p "$APP_DIR/custom_nodes/held2.disabled"
DEFAULT_NODES=()
sync_custom_nodes >/dev/null
[ "$(manifest_state held2)" = "held" ] || fail "held 记录移除后应保持 held（当前: $(manifest_state held2)）"

# 场景 11：held 节点重新加入列表 → 仍是 held（entrypoint 不得自动启用）
DEFAULT_NODES=("owner/held2.git|held2")
sync_custom_nodes >/dev/null
[ "$(manifest_state held2)" = "held" ] || fail "held 重新加入列表后应仍为 held（当前: $(manifest_state held2)）"

echo "ALL TESTS PASSED"
