#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# magpie-workbuddy-autotasks —— 跟随上游 + 自动重放本地改动
#
# 做的事：拉上游最新代码 → 归一化行尾 → 打上本地补丁（4 个文件）→ 断言改动
#         都在 → 备份现有安装目录 → 同步进 magpie 卷 → 重启容器 → 健康检查
#         → 失败自动回滚。
#
# 用法：
#   ./sync-upstream.sh                 # 有更新就同步并部署
#   ./sync-upstream.sh --stage-only    # 只准备到 staging，不动线上
#   ./sync-upstream.sh --force         # 上游没更新也重新部署（修本地被改坏的文件）
#   ./sync-upstream.sh --check         # 只报告上游是否有更新，退出码 0/10
#
# 退出码：0 成功/无更新  2 补丁冲突（已保留 staging 供人工处理）
#         3 断言失败（补丁打上了但改动不完整）  4 部署后健康检查失败（已回滚）
#         10 --check 模式：有新版本
#
# 安全：本脚本会把上游代码同步进容器并执行。上游是被信任源，一旦上游被投毒，
#       这一层无法自动识别。保留最近若干份备份 + 变更摘要日志，用于事后追查。
# ---------------------------------------------------------------------------
set -Eeuo pipefail

UPSTREAM_REPO="${UPSTREAM_REPO:-https://github.com/jichie/magpie-workbuddy-tasks.git}"
UPSTREAM_BRANCH="${UPSTREAM_BRANCH:-main}"

BASE="${BASE:-/opt/wbtasks-sync}"
BARE="$BASE/upstream.git"
STAGE="$BASE/staging"
BACKUPS="$BASE/backups"
STATE="$BASE/state"
PATCH_FILE="${PATCH_FILE:-$BASE/local-changes.patch}"

INSTALL_DIR="${INSTALL_DIR:-/var/lib/docker/volumes/magpie_magpie-config/_data/magpie/plugins/node_modules/magpie-workbuddy-tasks}"
CONTAINER="${CONTAINER:-magpie}"
OWNER="${OWNER:-65532:65532}"

PROXY="${PROXY:-http://127.0.0.1:7891}"
HEALTH_URL="${HEALTH_URL:-http://127.0.0.1:4390/api/hello}"
HEALTH_TRIES="${HEALTH_TRIES:-45}"     # × 2s = 90s

KEEP_BACKUPS="${KEEP_BACKUPS:-5}"
LOG="$STATE/sync.log"

MODE="deploy"
FORCE=0

# ---------------------------------------------------------------------------
log()  { printf '%s [%s] %s\n' "$(date '+%F %T')" "$1" "$2" | tee -a "$LOG" >&2; }
info() { log INFO "$*"; }
warn() { log WARN "$*"; }
die()  { log ERROR "$*"; exit "${2:-1}"; }

usage() { sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --stage-only) MODE="stage"; shift ;;
    --force)      FORCE=1; shift ;;
    --check)      MODE="check"; shift ;;
    -h|--help)    usage; exit 0 ;;
    *)            die "未知参数：$1（--help 看用法）" ;;
  esac
done

mkdir -p "$BASE" "$BACKUPS" "$STATE"
touch "$LOG"

[ -f "$PATCH_FILE" ] || die "补丁不存在：$PATCH_FILE（本地改动无法重放，拒绝继续）"

# 单实例：并发跑会互相覆盖 staging
exec 9>"$STATE/sync.lock"
flock -n 9 || die "已有同步进程在跑（lock: $STATE/sync.lock）"

export GIT_TERMINAL_PROMPT=0
export NO_PROXY="127.0.0.1,localhost,${NO_PROXY:-}"
GIT_PROXY=(-c "http.proxy=$PROXY" -c 'http.lowSpeedLimit=1000' -c 'http.lowSpeedTime=60')

# ---------------------------------------------------------------------------
# 1. 上游镜像
# ---------------------------------------------------------------------------
if [ ! -d "$BARE" ]; then
  info "首次克隆上游：$UPSTREAM_REPO"
  git "${GIT_PROXY[@]}" clone --bare --quiet "$UPSTREAM_REPO" "$BARE" \
    || die "克隆上游失败（检查 PROXY=$PROXY 是否可用）"
fi

info "拉取上游 $UPSTREAM_BRANCH"
git -C "$BARE" "${GIT_PROXY[@]}" fetch --quiet --prune origin \
  "+refs/heads/$UPSTREAM_BRANCH:refs/remotes/origin/$UPSTREAM_BRANCH" \
  || die "fetch 失败（检查 PROXY=$PROXY）"

SHA="$(git -C "$BARE" rev-parse "refs/remotes/origin/$UPSTREAM_BRANCH")"
[ -n "$SHA" ] || die "取不到上游 commit"
LAST_FILE="$STATE/last-deployed"
LAST="$( [ -f "$LAST_FILE" ] && cat "$LAST_FILE" || true )"

if [ "$SHA" = "$LAST" ] && [ "$FORCE" -eq 0 ] && [ -d "$INSTALL_DIR" ]; then
  info "上游无更新（$SHA），跳过"
  exit 0
fi

if [ "$MODE" = "check" ]; then
  echo "上游最新：$SHA"
  echo "已部署：  ${LAST:-（未知）}"
  [ "$SHA" = "$LAST" ] && exit 0 || exit 10
fi

info "上游 ${LAST:-<首次>} → ${SHA:0:12}"
if [ -n "$LAST" ] && git -C "$BARE" cat-file -e "$LAST^{commit}" 2>/dev/null; then
  git -C "$BARE" log --oneline "$LAST..$SHA" 2>/dev/null | head -20 | while read -r l; do log CHANGE "  $l"; done
  git -C "$BARE" diff --stat "$LAST" "$SHA" 2>/dev/null | tail -25 | while read -r l; do log CHANGE "  $l"; done
fi

# ---------------------------------------------------------------------------
# 2. 取干净树（含行尾归一化：上游仓库用 CRLF，本地补丁按 LF 生成）
# ---------------------------------------------------------------------------
if [ "$MODE" != "check" ]; then
  rm -rf "$STAGE"; mkdir -p "$STAGE"
  git -C "$BARE" archive "$SHA" | tar -x -C "$STAGE" || die "解出上游代码失败"
  find "$STAGE" -type f \
    \( -name '*.mjs' -o -name '*.js' -o -name '*.json' -o -name '*.html' \
       -o -name '*.css' -o -name '*.md' -o -name '*.yml' -o -name '*.yaml' \) \
    -exec sed -i 's/\r$//' {} + 2>/dev/null || true
  info "上游代码已解到 $STAGE"
fi

# ---------------------------------------------------------------------------
# 3. 重放本地改动
# ---------------------------------------------------------------------------
FUZZY=0
if patch -d "$STAGE" -p1 --dry-run --batch --silent < "$PATCH_FILE" 2>/dev/null; then
  patch -d "$STAGE" -p1 --batch --silent < "$PATCH_FILE"
  info "本地补丁已应用（精确匹配）"
elif patch -d "$STAGE" -p1 --dry-run --batch --silent --fuzz=2 < "$PATCH_FILE" 2>/dev/null; then
  patch -d "$STAGE" -p1 --batch --silent --fuzz=2 < "$PATCH_FILE"
  FUZZY=1
  warn "本地补丁靠 fuzz=2 才打上：上游改动了相邻代码，请人工复核 $STAGE"
else
  warn "本地补丁与上游冲突，未部署。staging 保留在 $STAGE"
  warn "处理方式：手动改 $STAGE，把结果回写成新的 $PATCH_FILE，再跑 --force"
  exit 2
fi

# ---------------------------------------------------------------------------
# 4. 断言：4 处改动必须都在（防止补丁错位或上游重写导致静默丢失）
# ---------------------------------------------------------------------------
fail=0
chk() { if eval "$2" >/dev/null 2>&1; then info "  断言 OK: $1"; else warn "  断言失败: $1"; fail=1; fi; }

chk "CORS: ACAO null"        "grep -q 'Access-Control-Allow-Origin\", \"null\"' '$STAGE/daemon.mjs'"
chk "CORS: OPTIONS 预检"     "grep -q 'Access-Control-Max-Age' '$STAGE/daemon.mjs'"
chk "生命周期: selfName"     "grep -q 'const selfName = basename(selfDir)' '$STAGE/daemon.mjs'"
chk "生命周期: 目录存在兜底" "grep -q 'existsSync(selfDir)' '$STAGE/daemon.mjs'"
chk "page.service 声明"      "python3 -c \"import json,sys; d=json.load(open('$STAGE/package.json')); sys.exit(0 if d['magpie']['page'].get('service',{}).get('port')==4390 else 1)\""
chk "embed.js 存在"          "test -f '$STAGE/page/embed.js' && grep -q 'location.replace' '$STAGE/page/embed.js'"
chk "index.html 引入"        "grep -q 'embed.js' '$STAGE/page/index.html'"
chk "package.json 可解析"    "python3 -m json.tool '$STAGE/package.json'"

[ "$fail" -eq 0 ] || die "断言未全通过，未部署（staging 在 $STAGE）" 3

# 语法检查：宿主没有 node 就跳过，部署后靠 /api/hello 兜底
if command -v node >/dev/null 2>&1; then
  node --check "$STAGE/daemon.mjs" || die "daemon.mjs 语法错误，未部署" 3
  info "  daemon.mjs 语法 OK"
fi

if [ "$MODE" = "stage" ]; then
  info "仅 stage 模式：已准备 $STAGE（未部署）"
  [ "$FUZZY" -eq 1 ] && warn "注意：本次是 fuzz 匹配"
  exit 0
fi

# ---------------------------------------------------------------------------
# 5. 备份现有安装
# ---------------------------------------------------------------------------
TS="$(date +%Y%m%d-%H%M%S)"
BK="$BACKUPS/plugin-$TS"
if [ -d "$INSTALL_DIR" ]; then
  cp -a "$INSTALL_DIR" "$BK" || die "备份失败，未部署"
  info "已备份到 $BK"
else
  warn "安装目录不存在：$INSTALL_DIR（将新建）"
fi

cleanup_backups() {
  ls -1dt "$BACKUPS"/plugin-* 2>/dev/null | tail -n +$((KEEP_BACKUPS+1)) | while read -r old; do
    rm -rf "$old" && info "清理旧备份 $old"
  done
}

# ---------------------------------------------------------------------------
# 6. 部署 + 健康检查 + 失败回滚
# ---------------------------------------------------------------------------
wait_healthy() {
  local i out
  for i in $(seq 1 "$HEALTH_TRIES"); do
    out="$(docker exec "$CONTAINER" curl -s -m 3 "$HEALTH_URL" 2>/dev/null || true)"
    case "$out" in *'"ready":true'*) return 0 ;; esac
    sleep 2
  done
  return 1
}

rollback() {
  warn "开始回滚…"
  if [ -d "$BK" ]; then
    rsync -a --delete "$BK/" "$INSTALL_DIR/" && chown -R "$OWNER" "$INSTALL_DIR" 2>/dev/null || true
    docker restart "$CONTAINER" >/dev/null 2>&1 || true
    if wait_healthy; then warn "已回滚到上一版本，健康检查通过"; else warn "回滚后仍不健康，需要人工介入"; fi
  else
    warn "没有备份可回滚"
  fi
}

info "同步到安装目录：$INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
rsync -a --delete --exclude '.bun-tag' "$STAGE"/ "$INSTALL_DIR"/ || { warn "rsync 失败"; rollback; exit 4; }
chown -R "$OWNER" "$INSTALL_DIR" 2>/dev/null || warn "chown 失败（非 root？）"

info "重启 $CONTAINER"
docker restart "$CONTAINER" >/dev/null || { warn "重启失败"; rollback; exit 4; }

if wait_healthy; then
  info "健康检查通过"
else
  warn "健康检查失败（$HEALTH_URL 未返回 ready:true）"
  rollback
  exit 4
fi

echo "$SHA" > "$LAST_FILE"
cleanup_backups
info "完成：已部署 ${SHA:0:12}"
[ "$FUZZY" -eq 1 ] && warn "提醒：本次补丁是模糊匹配，建议人工复核 daemon.mjs"
exit 0
