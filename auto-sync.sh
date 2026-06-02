#!/bin/sh
# auto-sync.sh
#
# 自动同步 upstream 并补全 season_id / video_sn，最后 git push
#
# Token 配置（按优先级，推荐用文件）：
#   A. ~/.github_token 文件（最安全，权限 600）
#        echo "ghp_xxx" > ~/.github_token && chmod 600 ~/.github_token
#   B. 环境变量：export GITHUB_TOKEN="ghp_xxx"
#   C. --token 参数（仅测试用，会留在 shell 历史里）
#
# 用法：
#   sh auto-sync.sh                  # 普通运行
#   sh auto-sync.sh --force          # 跳过上游同步
#   sh auto-sync.sh --force-push     # 强制推送测试
#   sh auto-sync.sh --test-commit    # 创建测试提交
#   sh auto-sync.sh --test-full      # 测试完整流程
#   sh auto-sync.sh --publish        # 本机 npm publish
#   sh auto-sync.sh --dry-run        # 只检测，不修改
#
# cron 示例：
#   0 3 * * * sh /root/bangumi-data/helper/auto-sync.sh >> /root/bangumi-data/auto-sync.log 2>&1
#
set -e

# ── 配置 ─────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HELPER_DIR="$SCRIPT_DIR"
BANGUMI_DATA_DIR="$(cd "$SCRIPT_DIR/../bangumi-data" 2>/dev/null && pwd || echo "$SCRIPT_DIR/../bangumi-data")"
LOG_PREFIX="[auto-sync $(date '+%Y-%m-%d %H:%M:%S')]"

# Token（按优先级读取）
GITHUB_TOKEN=""
GITHUB_USER="wan0ge"

# GitHub 代理（fetch 用，push 时脚本会自动嵌入 GITHUB_TOKEN）
GITHUB_PROXIES="https://gh-proxy.org,https://hk.gh-proxy.org,https://cdn.gh-proxy.org,https://edgeone.gh-proxy.org"

# HTTP 代理备选（局域网设备，脚本启动时会自动测试连通性）
# 例：HTTP_PROXY_LIST="http://192.168.8.234:28235,socks5://192.168.8.231:2080"
HTTP_PROXY_LIST=""

DO_PUBLISH=0
DRY_RUN=0
FORCE=0
FORCE_PUSH=0
TEST_COMMIT=0
TEST_FULL=0

# ── 参数解析 ─────────────────────────────────────────────────────────────

while [ $# -gt 0 ]; do
  case "$1" in
    --publish)      DO_PUBLISH=1; shift ;;
    --dry-run)      DRY_RUN=1; shift ;;
    --force)        FORCE=1; shift ;;
    --force-push)   FORCE_PUSH=1; shift ;;
    --test-commit)  TEST_COMMIT=1; shift ;;
    --test-full)    TEST_FULL=1; shift ;;
    --token)
      shift
      if [ -n "$1" ] && ! echo "$1" | grep -q "^-"; then
        GITHUB_TOKEN="$1"
        echo "$LOG_PREFIX WARNING: --token 参数会将 token 留在 shell 历史里，建议使用 ~/.github_token 文件。" >&2
        shift
      fi
      ;;
    --user)
      shift
      if [ -n "$1" ] && ! echo "$1" | grep -q "^-"; then
        GITHUB_USER="$1"
        shift
      fi
      ;;
    --http-proxy)
      shift
      if [ -n "$1" ] && ! echo "$1" | grep -q "^-"; then
        HTTP_PROXY_LIST="$1"
        shift
      fi
      ;;
    -*) echo "未知参数: $1" >&2; exit 1 ;;
    *)  # 位置参数当作 token
      if [ -z "$GITHUB_TOKEN" ] && echo "$1" | grep -q "^ghp_"; then
        GITHUB_TOKEN="$1"
        echo "$LOG_PREFIX WARNING: 位置参数传 token 会留在 shell 历史里，建议使用 ~/.github_token 文件。" >&2
      fi
      shift
      ;;
  esac
done

# ── Token 读取（优先级：文件 > 环境变量 > git credential store > 参数） ──

if [ -n "$GITHUB_TOKEN" ]; then
  # 命令行参数传入的 token（已设置，跳过文件读取）
  GITHUB_TOKEN_SRC="命令行参数（不建议）"
elif [ -f ~/.github_token ]; then
  GITHUB_TOKEN="$(cat ~/.github_token | tr -d ' \n\r')"
  GITHUB_TOKEN_SRC="~/.github_token 文件"
elif [ -n "$GITHUB_TOKEN" ]; then
  # 这里 $GITHUB_TOKEN 是环境变量（上面没读到说明环境变量也没设）
  GITHUB_TOKEN=""
  GITHUB_TOKEN_SRC="未配置"
else
  GITHUB_TOKEN_SRC="未配置"
fi

# 检测 git credential store 是否配置了 gh-proxy 认证
CREDENTIAL_STORE_OK=0
if command -v git >/dev/null 2>&1; then
  if git config --global credential.helper 2>/dev/null | grep -q "store" && [ -f ~/.git-credentials ]; then
    if grep -q "gh-proxy" ~/.git-credentials 2>/dev/null; then
      CREDENTIAL_STORE_OK=1
    fi
  fi
fi

# --test-full 自动开启 test-commit + publish 模式
if [ "$TEST_FULL" = "1" ]; then
  TEST_COMMIT=1
  DO_PUBLISH=1
fi

STATS_FILE="/tmp/auto-sync-stats.json"

# ── 钉钉通知配置 ─────────────────────────────────────────────────────────────

DINGTALK_PROXY_URL="http://127.0.0.1:5000/dingtalk/api/notify"
ENABLE_DINGTALK_NOTIFY=1
NOTIFY_TIMEOUT=5

# ── 工具函数 ─────────────────────────────────────────────────────────────

log() {
  echo "$LOG_PREFIX $1"
}

get_cst_time() {
  TZ='CST-8' date '+%Y年%m月%d日 %H:%M:%S'
}

# 获取上游 bangumi-data 最新 tag 信息
# 输出到全局变量：UPSTREAM_VER, UPSTREAM_TAG_DT, UPSTREAM_TAG_DT_CST
get_upstream_info() {
  # 通过 GitHub API 获取最新 tag（匿名，无 rate limit 问题）
  # -m 10: 10秒超时，避免路由器上网络不通时无限等待
  local api_out
  api_out=$(curl -s -m 10 "https://api.github.com/repos/bangumi-data/bangumi-data/tags?per_page=1" 2>/dev/null || echo "[]")

  # 解析 tag_name 和 commit 的 created_at
  # 用环境变量传参，避免 bash 变量嵌进 JS 字符串导致语法错误
  UPSTREAM_VER=$(echo "$api_out" | node -e "
    let d=[];
    try { d=JSON.parse(require('fs').readFileSync('/dev/stdin','utf8').trim()||'[]'); } catch(e){}
    if(d[0] && d[0].name) console.log(d[0].name.replace(/^v/,''));
  " 2>/dev/null)

  local commit_url
  commit_url=$(echo "$api_out" | node -e "
    let d=[];
    try { d=JSON.parse(require('fs').readFileSync('/dev/stdin','utf8').trim()||'[]'); } catch(e){}
    if(d[0] && d[0].commit && d[0].commit.url) console.log(d[0].commit.url);
  " 2>/dev/null)

  UPSTREAM_TAG_DT=""
  UPSTREAM_TAG_DT_CST=""
  if [ -n "$commit_url" ]; then
    # 同样加超时
    local commit_out
    commit_out=$(curl -s -m 10 "$commit_url" 2>/dev/null || echo "{}")
    UPSTREAM_TAG_DT=$(echo "$commit_out" | node -e "
      let d={};
      try { d=JSON.parse(require('fs').readFileSync('/dev/stdin','utf8').trim()||'{}'); } catch(e){}
      if(d.committer && d.committer.date) console.log(d.committer.date);
      else if(d.commit && d.commit.committer && d.commit.committer.date) console.log(d.commit.committer.date);
    " 2>/dev/null)
    # 转成 CST
    if [ -n "$UPSTREAM_TAG_DT" ]; then
      UPSTREAM_TAG_DT_CST=$(TZ='CST-8' date -d "$UPSTREAM_TAG_DT" '+%Y-%m-%d %H:%M UTC+8' 2>/dev/null \
        || echo "$UPSTREAM_TAG_DT")
    fi
  fi

  # API 失败时回退用 ls-remote 只拿版本号
  if [ -z "$UPSTREAM_VER" ]; then
    UPSTREAM_VER=$(git ls-remote --tags https://github.com/bangumi-data/bangumi-data.git 2>/dev/null \
      | grep -v '\^{}' | awk '{print $2}' \
      | sed 's|refs/tags/v||' | sort -V | tail -1)
  fi

  # 兜底
  [ -z "$UPSTREAM_VER" ] && UPSTREAM_VER="0.3.208"
  [ -z "$UPSTREAM_TAG_DT_CST" ] && UPSTREAM_TAG_DT_CST="未知时间"
}

# 计算下一个发布版本号
# 规则：max(当前 package.json 版+1, 上游版+1, 0.3.200)
# 用环境变量传参，避免 bash 变量嵌进 JS 导致语法错误
calc_next_version() {
  CUR_VER="$1"
  UP_VER="$2"
  node -e "
    const cur = process.env.CUR_VER.split('.').map(Number);
    const up  = process.env.UP_VER.split('.').map(Number);
    const base = '0.3.200'.split('.').map(Number);
    let next = [cur[0], cur[1], cur[2]+1];
    function cmp(a,b) { for(let i=0;i<3;i++){ if(a[i]>b[i]) return 1; if(a[i]<b[i]) return -1; } return 0; }
    if(cmp([up[0],up[1],up[2]+1], next) > 0) next = [up[0],up[1],up[2]+1];
    if(cmp([base[0],base[1],base[2]], next) > 0) next = base;
    console.log(next.join('.'));
  " 2>/dev/null || echo "0.3.200"
}

send_dingtalk_notification() {
  local title="$1"
  local message="$2"

  if [ "$ENABLE_DINGTALK_NOTIFY" -ne 1 ]; then return 0; fi
  if ! command -v curl >/dev/null 2>&1; then
    log "警告: curl 不可用，无法发送钉钉通知。"
    return 1
  fi

  local escaped_message=$(echo "$message" | sed 's/\\/\\\\/g' | sed 's/"/\\"/g' | sed ':a;N;$!ba;s/\n/\\n/g')
  local escaped_title=$(echo "$title" | sed 's/\\/\\\\/g' | sed 's/"/\\"/g')
  local json_data="{\"title\":\"${escaped_title}\",\"message\":\"${escaped_message}\"}"

  curl -s -X POST "$DINGTALK_PROXY_URL" \
    -H "Content-Type: application/json" \
    -d "$json_data" \
    -m "$NOTIFY_TIMEOUT" >/dev/null 2>&1 || true
}

die() {
  echo "$LOG_PREFIX ERROR: $1" >&2
  send_dingtalk_notification "auto-sync 执行失败" "❌ 错误: $1

时间: $(get_cst_time)
来自：bangumi data"
  exit 1
}

# ── Git 代理回退函数 ─────────────────────────────────────────────────────────
#
# 【push 认证处理（关键！）】
#   gh-proxy 类代理需要认证信息放在代理 URL 的 auth 位置：
#     https://wan0ge:ghp_xxx@cdn.gh-proxy.org/https://github.com/...
#   这样代理会用该认证信息代你向 GitHub 发起 push。
#
#   insteadOf 正确构造方式：
#     key:   "url.https://user:token@proxy/https://github.com/.insteadOf"
#     value: "https://github.com/"
#     效果：https://github.com/foo/bar → https://user:token@proxy/https://github.com/foo/bar
#
# 【fetch 代理（只读，无需认证）】
#   fetch 使用 url.insteadOf 重写，不需要认证信息。
#
# 【http.proxy 备选】
#   HTTP_PROXY_LIST 中的局域网代理（如 http://192.168.8.234:28235）
#   通过 HTTP CONNECT 隧道转发，认证对代理透明。
#   作为备选放在最后，因为需要用户设备开启代理服务。
#

git_with_proxy() {
  local action="$1"
  local remote="$2"
  local branch="$3"
  local repo_path="$4"
  local extra_args="${5:-}"

  export GIT_TERMINAL_PROMPT=0

  # ── push：优先直连（remote URL 已嵌入 token）──
  if [ "$action" = "push" ]; then
    if git $action "$remote" "$branch" $extra_args 2>/dev/null; then
      log "$action ($repo_path) 直连成功"
      return 0
    fi
    log "$action ($repo_path) 直连失败，回退尝试代理..."

    # 尝试通过 gh-proxy 代理 push（需要 GITHUB_TOKEN 或 credential store）
    if [ -n "$GITHUB_TOKEN" ]; then
      # 方式 A：嵌入 token 到代理 URL auth 位置
      OLD_IFS="$IFS"
      IFS=','
      for proxy in $GITHUB_PROXIES; do
        IFS="$OLD_IFS"

        local proxy_host="${proxy#https://}"
        local auth_base="https://${GITHUB_USER}:${GITHUB_TOKEN}@${proxy_host}"
        local instead_of_key="url.${auth_base}/https://github.com/.insteadOf"
        local instead_of_val="https://github.com/"

        if git -c "$instead_of_key=$instead_of_val" \
              $action "$remote" "$branch" $extra_args --quiet 2>/dev/null; then
          log "$action ($repo_path) 通过代理 $proxy (token 嵌入) 成功"
          return 0
        fi
        log "$action ($repo_path) 代理 $proxy 失败，错误详情："
        local proxy_err
        proxy_err=$(git -c "$instead_of_key=$instead_of_val" \
            $action "$remote" "$branch" $extra_args 2>&1) || true
        echo "$proxy_err" | sed 's/^/  | /' >&2
        IFS=','
      done
      IFS="$OLD_IFS"
    elif [ "$CREDENTIAL_STORE_OK" = "1" ]; then
      # 方式 B：git credential store 已配置 gh-proxy 认证
      # remote URL 已经指向 gh-proxy（如 https://cdn.gh-proxy.org/https://github.com/...）
      # git 会自动从 credential store 提供认证信息
      log "$action ($repo_path) 使用 git credential store 认证尝试代理 push..."
      OLD_IFS="$IFS"
      IFS=','
      for proxy in $GITHUB_PROXIES; do
        IFS="$OLD_IFS"
        local instead_of_key="url.${proxy}/https://github.com/.insteadOf"
        local instead_of_val="https://github.com/"

        if git -c "$instead_of_key=$instead_of_val" \
              $action "$remote" "$branch" $extra_args --quiet 2>/dev/null; then
          log "$action ($repo_path) 通过代理 $proxy (credential store) 成功"
          return 0
        fi
        log "$action ($repo_path) 代理 $proxy (credential store) 失败，错误详情："
        local proxy_err
        proxy_err=$(git -c "$instead_of_key=$instead_of_val" \
            $action "$remote" "$branch" $extra_args 2>&1) || true
        echo "$proxy_err" | sed 's/^/  | /' >&2
        IFS=','
      done
      IFS="$OLD_IFS"
    else
      log "$action ($repo_path) 未设置 GITHUB_TOKEN，且未配置 git credential store，跳过代理 push（代理需要认证）"
    fi

    # 尝试 HTTP CONNECT 隧道代理（http.proxy 备选）
    if [ -n "$HTTP_PROXY_LIST" ]; then
      OLD_IFS="$IFS"
      IFS=','
      for hp in $HTTP_PROXY_LIST; do
        IFS="$OLD_IFS"
        log "$action ($repo_path) 尝试 HTTP 隧道代理 $hp ..."
        if git -c "http.proxy=$hp" \
              $action "$remote" "$branch" $extra_args --quiet 2>/dev/null; then
          log "$action ($repo_path) 通过 HTTP 隧道代理 $hp 成功"
          return 0
        fi
        log "$action ($repo_path) HTTP 隧道代理 $hp 失败"
        IFS=','
      done
      IFS="$OLD_IFS"
    fi

    # push 所有路径失败，输出详细错误
    log "$action ($repo_path) 所有路径均失败，错误详情："
    local final_out
    final_out=$(git $action "$remote" "$branch" $extra_args 2>&1) || true
    echo "$final_out" | sed 's/^/  | /' >&2

    # push 特殊处理：Everything up-to-date 但无传输中断 → 数据已成功送达远端
    if echo "$final_out" | grep -q "Everything up-to-date" \
      && ! echo "$final_out" | grep -qE "(send-pack: unexpected disconnect|the remote end hung up unexpectedly)"; then
      log "$action ($repo_path) 虽所有路径报错，但 Everything up-to-date（数据已成功推送，连接断开为网络波动）"
      return 0
    fi

    echo "$LOG_PREFIX ERROR: $action ($repo_path) 所有代理和直连均不可用（错误详情见上方输出）" >&2
    return 1
  fi

  # ── fetch（只读，代理不需要认证）──
  OLD_IFS="$IFS"
  IFS=','
  for proxy in $GITHUB_PROXIES; do
    IFS="$OLD_IFS"
    if git -c "url.${proxy}/https://github.com/.insteadOf=https://github.com/" \
          $action "$remote" "$branch" $extra_args --quiet 2>/dev/null; then
      log "$action ($repo_path) 通过代理 $proxy 成功"
      return 0
    fi
    # 代理失败，输出错误详情
    log "$action ($repo_path) 代理 $proxy 失败，错误详情："
    local fetch_err
    fetch_err=$(git -c "url.${proxy}/https://github.com/.insteadOf=https://github.com/" \
        $action "$remote" "$branch" $extra_args 2>&1) || true
    echo "$fetch_err" | sed 's/^/  | /' >&2
    IFS=','
  done
  IFS="$OLD_IFS"

  # fetch 操作：代理全失败后回退直连
  log "$action ($repo_path) 所有代理不可用，尝试直连 GitHub..."
  if git $action "$remote" "$branch" $extra_args 2>/dev/null; then
    log "$action ($repo_path) 直连成功"
    return 0
  fi

  # 最后一次尝试：输出详细错误
  log "$action ($repo_path) 所有路径均失败，错误详情："
  final_out=$(git $action "$remote" "$branch" $extra_args 2>&1) || true
  echo "$final_out" | sed 's/^/  | /' >&2

  echo "$LOG_PREFIX ERROR: $action ($repo_path) 所有代理和直连均不可用（错误详情见上方输出）" >&2
  return 1
}

# 清理上一次运行遗留的未解决合并冲突
cleanup_merge() {
  local repo_path="$1"
  (
    cd "$repo_path"
    if git ls-files --unmerged 2>/dev/null | grep -q .; then
      log "检测到未解决的合并冲突，正在中止并重置到 HEAD..."
      git merge --abort 2>/dev/null || true
      git reset --hard HEAD 2>/dev/null || true
      log "冲突已清理，仓库恢复到干净状态。"
    fi
  )
}

# HTTP 代理连通性测试（用 git 真实测试）
test_http_proxy() {
  local hp="$1"
  # 用 git ls-remote 测试：通过代理访问 GitHub，5 秒超时
  if GIT_TERMINAL_PROMPT=0 git -c "http.proxy=$hp" \
        -c "http.sslVerify=false" \
        ls-remote --heads https://github.com/wan0ge/bangumi-data.git 2>/dev/null \
        | head -1 | grep -q "refs/heads"; then
    return 0
  else
    return 1
  fi
}

# ── 检查依赖 ─────────────────────────────────────────────────────────────

command -v git  >/dev/null 2>&1 || die "git 未安装"
command -v node >/dev/null 2>&1 || die "node 未安装"

log "=== 开始自动同步 ==="
log "helper:       $HELPER_DIR"
log "bangumi-data: $BANGUMI_DATA_DIR"
log "token:        ${GITHUB_TOKEN_SRC}"
if [ "$CREDENTIAL_STORE_OK" = "1" ]; then
  log "cred store:   ~/.git-credentials (gh-proxy 可用)"
fi

# ── HTTP 代理连通性测试（只保留可用的） ────────────────────────────────────

if [ -n "$HTTP_PROXY_LIST" ]; then
  log "测试 HTTP 代理连通性..."
  TESTED_LIST=""
  OLD_IFS="$IFS"
  IFS=','
  for hp in $HTTP_PROXY_LIST; do
    IFS="$OLD_IFS"
    if test_http_proxy "$hp"; then
      TESTED_LIST="${TESTED_LIST}${hp},"
      log "HTTP 代理可用: $hp"
    else
      log "HTTP 代理不可用（已跳过）: $hp"
    fi
    IFS=','
  done
  IFS="$OLD_IFS"
  HTTP_PROXY_LIST="$TESTED_LIST"
  if [ -z "$HTTP_PROXY_LIST" ]; then
    log "所有 HTTP 代理均不可用，已清空备选列表。"
  fi
fi

# ── 同步 bangumi-data 上游 ────────────────────────────────────────────────────

UPSTREAM_UPDATED=0  # 记录上游是否带来新提交（用于决定是否发布新版本）

if [ "$FORCE" = "1" ]; then
  log "--force 模式：跳过上游同步，直接进行补全..."
else
  log "同步 bangumi-data 上游..."
  cd "$BANGUMI_DATA_DIR"

  git remote get-url upstream >/dev/null 2>&1 || \
    git remote add upstream https://github.com/bangumi-data/bangumi-data.git

  cleanup_merge "$BANGUMI_DATA_DIR"
  git_with_proxy fetch upstream master "bangumi-data/bangumi-data"
  git checkout master --quiet 2>/dev/null || true

  # 记录 fetch 前的 HEAD，用于判断上游是否有新内容
  _before=$(git rev-parse HEAD 2>/dev/null || echo "")
  git merge upstream/master --no-edit -X ours || true
  _after=$(git rev-parse HEAD 2>/dev/null || echo "")
  if [ "$_before" != "$_after" ]; then
    UPSTREAM_UPDATED=1
    log "上游有新提交，将触发版本发布。"
  else
    log "上游无新提交。"
  fi

  log "bangumi-data 同步完成。"
fi

# ── 同步 helper 上游 ────────────────────────────────────────────────────

if [ "$FORCE" = "1" ]; then
  log "--force 模式：跳过 helper 上游同步。"
else
  log "同步 helper 上游..."
  cd "$HELPER_DIR"

  git remote get-url upstream >/dev/null 2>&1 || \
    git remote add upstream https://github.com/bangumi-data/helper.git

  cleanup_merge "$HELPER_DIR"
  git_with_proxy fetch upstream master "bangumi-data/helper"
  git merge upstream/master --no-edit || true
  log "helper 同步完成。"
fi

# ── 运行 fill-missing-ids.js 补全缺失字段 ────────────────────────────────────

log "开始补全缺失的 season_id / video_sn..."
cd "$BANGUMI_DATA_DIR"

if [ "$DRY_RUN" = "1" ]; then
  node "$HELPER_DIR/fill-missing-ids.js" --dry-run
  log "[dry-run] 完成，未写入文件。"
  exit 0
fi

if node "$HELPER_DIR/fill-missing-ids.js" --stats-file "$STATS_FILE"; then
  log "补全完成。"
else
  send_dingtalk_notification "补全任务失败" "❌ fill-missing-ids.js 执行失败

时间: $(get_cst_time)
来自：bangumi data"
  die "fill-missing-ids.js 执行失败"
fi

# ── 提交数据变更 ──────────────────────────────────────────────────────────────

cd "$BANGUMI_DATA_DIR"

# 检查 data/ 目录是否有文件变更
if git diff --quiet data/ && git diff --cached --quiet data/; then
  if [ "$TEST_COMMIT" = "1" ]; then
    log "--test-commit：创建测试提交以验证推送链路..."
    echo "# test-commit $(date '+%Y-%m-%d %H:%M:%S')" >> .gitignore
    git add .gitignore
    git commit -m "test: 推送链路测试 [$(date '+%Y-%m-%d %H:%M:%S')]"
    DATA_COMMITTED=1
  elif [ "$UPSTREAM_UPDATED" = "1" ]; then
    # 上游有更新但补全后数据文件无变化：仍需一个提交以触发 GitHub Actions 发布
    log "上游有更新，补全后数据文件无变化，创建触发提交以触发 GitHub Actions 发布..."
    echo "# upstream-sync $(date '+%Y-%m-%d %H:%M:%S')" >> .gitignore
    git add .gitignore
    git commit -m "chore: 跟随上游更新 [$(date '+%Y-%m-%d')]"
    DATA_COMMITTED=1
  else
    log "数据文件无变化，跳过提交。"
    DATA_COMMITTED=0
  fi
else
  log "提交数据更新..."
  git add data/
  git commit -m "data: 自动同步并补全 season_id/video_sn [$(date '+%Y-%m-%d')]"
  DATA_COMMITTED=1
fi

# ── 可选：npm publish（建议改用 GitHub Actions）────────────────────────
#
# 版本号策略：
#   测试模式 (--test-commit / --test-full)：
#     使用 0.3.200-test.1, 0.3.200-test.2 ... 格式
#     -test 后缀保证和正式版完全隔离，npm 不会冲突
#   正式模式：
#     调用 get_upstream_info() 获取上游最新 tag 版本
#     调用 calc_next_version() 计算：max(当前版+1, 上游版+1, 0.3.200)
#
# 触发条件：上游有更新（UPSTREAM_UPDATED=1）或数据文件有补全提交（DATA_COMMITTED=1）
#   只要上游发布了新版本，无论补全是否有新数据，都应该跟随发布新版本。
#
if [ "$DO_PUBLISH" = "1" ] && ([ "$UPSTREAM_UPDATED" = "1" ] || [ "$DATA_COMMITTED" = "1" ]); then
  if ! command -v npm >/dev/null 2>&1; then
    log "WARNING: npm 未安装，跳过发布。"
  else
    log "构建并发布到 npm... (DATA_COMMITTED=$DATA_COMMITTED, DO_PUBLISH=$DO_PUBLISH)"
    set +e

    # 获取上游版本信息（用于版本号计算和通知）
    log "正在获取上游版本信息..."
    get_upstream_info
    log "上游版本信息获取完成: UPSTREAM_VER=$UPSTREAM_VER"

    CURRENT_VER=$(node -e "console.log(require('./package.json').version)" 2>/dev/null || echo "0.3.200")
    log "当前 package.json 版本: $CURRENT_VER"

    if [ "$TEST_COMMIT" = "1" ] || [ "$TEST_FULL" = "1" ]; then
      # 测试模式：0.3.200-test.1, 0.3.200-test.2, ...
      # 用本地文件记录测试序号，避免调用 npm view（路由器上会卡住）
      TEST_BASE="0.3.200-test"
      TEST_COUNTER_FILE="$HELPER_DIR/.test_version_counter"
      if [ -f "$TEST_COUNTER_FILE" ]; then
        LATEST_TEST=$(cat "$TEST_COUNTER_FILE" 2>/dev/null || echo "0")
      else
        LATEST_TEST="0"
      fi
      TEST_NUM=$((LATEST_TEST + 1))
      echo "$TEST_NUM" > "$TEST_COUNTER_FILE"
      NEXT_VER="${TEST_BASE}.${TEST_NUM}"
      log "测试模式：版本号 = $NEXT_VER (基于 0.3.200-test 序列)"
    else
      # 正式模式：max(当前版+1, 上游版+1, 0.3.200)
      log "调用 calc_next_version..."
      NEXT_VER=$(calc_next_version "$CURRENT_VER" "$UPSTREAM_VER")
      log "正式模式：当前版=$CURRENT_VER, 上游版=$UPSTREAM_VER, 下一个版=$NEXT_VER"
      log "上游 tag 时间: $UPSTREAM_TAG_DT_CST"
    fi

    log "开始 npm run build..."
    npm run build
    BUILD_EXIT=$?
    log "npm run build 完成，退出码: $BUILD_EXIT"

    log "设置 package.json 版本: $NEXT_VER"
    npm pkg set version="$NEXT_VER"
    PKG_EXIT=$?
    log "npm pkg set 完成，退出码: $PKG_EXIT"

    log "提交版本变更..."
    git add package.json
    git commit -m "chore(release): $NEXT_VER [skip ci]"
    COMMIT_EXIT=$?
    log "git commit 完成，退出码: $COMMIT_EXIT"
    git tag -f "v$NEXT_VER" >/dev/null 2>&1
    log "git tag v$NEXT_VER 完成"

    log "开始 npm publish..."
    if npm publish --access public 2>&1; then
      log "已发布 @wan0ge/bangumi-data@$NEXT_VER"
      PUBLISH_STATUS="✅ 已发布 v$NEXT_VER"
    else
      PUBLISH_EXIT=$?
      log "WARNING: npm publish 失败（可能未登录），退出码: $PUBLISH_EXIT，版本提交和 tag 将随推送一起提交，由 GitHub Actions 发布。"
      send_dingtalk_notification "npm publish 失败" "⚠️ npm publish 失败，版本提交已创建，将由 GitHub Actions 发布。

版本: v${NEXT_VER}
时间: $(get_cst_time)
来自：bangumi data" 2>/dev/null || true
      PUBLISH_STATUS="⚠️ 本地发布失败，走 Actions"
    fi
    log "npm publish 部分完成"
    set -e
  fi
fi

# ── 推送到 GitHub ──────────────────────────────────────────────────────────────

if [ "$DATA_COMMITTED" = "1" ] || [ "$FORCE_PUSH" = "1" ]; then
  [ "$FORCE_PUSH" = "1" ] && log "--force-push 模式：即使无数据变更也测试推送链路..."

  # 推送 bangumi-data（含重试，先 pull 再 push）
  log "推送 bangumi-data 到 GitHub..."
  cd "$BANGUMI_DATA_DIR"
  PUSH_TRIES=0
  PUSH_OK=0
  while [ $PUSH_TRIES -lt 3 ]; do
    PUSH_TRIES=$((PUSH_TRIES + 1))
    cleanup_merge "$BANGUMI_DATA_DIR"
    git_with_proxy pull origin master "bangumi-data/bangumi-data" "--allow-unrelated-histories --no-rebase --no-edit -X ours" || log "pull 失败，跳过同步远程..."
    # 先推 master 分支（不含 tags）
    if git_with_proxy push origin master "bangumi-data/bangumi-data"; then
      PUSH_OK=1
      log "bangumi-data master 推送成功。"
      break
    fi
    if [ $PUSH_TRIES -lt 3 ]; then
      log "bangumi-data 推送失败 (尝试 $PUSH_TRIES/3)，30秒后重试..."
      sleep 30
    fi
  done
  if [ $PUSH_OK -ne 1 ]; then
    die "bangumi-data 推送失败（master 分支），已重试3次"
  fi

  # 推 tags：用本次构建的 NEXT_VER，不重新读 package.json（避免在 helper 目录读到旧版本）
  log "推送 bangumi-data tags..."
  NEXT_VER_TAG="v$NEXT_VER"
  if [ -n "$NEXT_VER_TAG" ] && [ "$NEXT_VER_TAG" != "v" ]; then
    remote_ref="$(git ls-remote --tags origin "refs/tags/$NEXT_VER_TAG" 2>/dev/null | awk '{print $1}')"
    local_ref="$(git rev-parse "$NEXT_VER_TAG" 2>/dev/null)"
    if [ -z "$remote_ref" ]; then
      log "tag $NEXT_VER_TAG 远端不存在，创建..."
      git tag -f "$NEXT_VER_TAG" >/dev/null 2>&1
      git_with_proxy push origin "refs/tags/$NEXT_VER_TAG" "bangumi-data/bangumi-data (tag $NEXT_VER_TAG)"
    elif [ "$local_ref" != "$remote_ref" ]; then
      log "tag $NEXT_VER_TAG 远端指向不同 commit ($remote_ref)，强制更新..."
      git tag -f "$NEXT_VER_TAG" >/dev/null 2>&1
      git_with_proxy push origin "refs/tags/$NEXT_VER_TAG" "bangumi-data/bangumi-data (tag $NEXT_VER_TAG)" "--force"
    else
      log "tag $NEXT_VER_TAG 远端已存在且相同，跳过。"
    fi
  else
    log "NEXT_VER 为空，跳过 tag 推送。"
  fi
  log "bangumi-data 推送完成。"

  # 推送 helper（含重试，先 pull 再 push）
  log "推送 helper 到 GitHub..."
  cd "$HELPER_DIR"
  PUSH_TRIES=0
  PUSH_OK=0
  while [ $PUSH_TRIES -lt 3 ]; do
    PUSH_TRIES=$((PUSH_TRIES + 1))
    cleanup_merge "$HELPER_DIR"
    git_with_proxy pull origin master "bangumi-data/helper" "--no-rebase --no-edit" || log "pull 失败，跳过同步远程..."
    if git_with_proxy push origin master "bangumi-data/helper"; then
      PUSH_OK=1
      break
    fi
    if [ $PUSH_TRIES -lt 3 ]; then
      log "helper 推送失败 (尝试 $PUSH_TRIES/3)，30秒后重试..."
      sleep 30
    fi
  done
  if [ $PUSH_OK -ne 1 ]; then
    die "helper 推送失败，已重试3次"
  fi
  log "helper 推送完成。"
else
  log "无数据变更，跳过推送。"
fi

log "=== 自动同步完成 ==="

# ── 钉钉通知（仅在有实际数据提交时发送）────────────────────────────
# 注意：无变更的静默运行不发送通知，避免每天刷屏
#
if [ "$DATA_COMMITTED" = "1" ]; then
  # 读取补全统计
  if [ -f "$STATS_FILE" ]; then
    SEASON_FILLED=$(node -e "console.log(require('$STATS_FILE').season_id_filled || 0)" 2>/dev/null || echo "0")
    SEASON_FAILED=$(node -e "console.log(require('$STATS_FILE').season_id_failed || 0)" 2>/dev/null || echo "0")
    VIDEO_FILLED=$(node -e "console.log(require('$STATS_FILE').video_sn_filled || 0)" 2>/dev/null || echo "0")
    VIDEO_FAILED=$(node -e "console.log(require('$STATS_FILE').video_sn_failed || 0)" 2>/dev/null || echo "0")
    FILES_MODIFIED=$(node -e "console.log(require('$STATS_FILE').files_modified || 0)" 2>/dev/null || echo "0")
    GAMER_LABEL=$(node -e "console.log(require('$STATS_FILE').gamer_url_label || '?')" 2>/dev/null || echo "?")
    SKIPPED=$(node -e "console.log(require('$STATS_FILE').skipped_count || 0)" 2>/dev/null || echo "0")
    SKIP_ACTIVE=$(node -e "console.log(require('$STATS_FILE').skip_list_active || 0)" 2>/dev/null || echo "0")
    SKIP_TOTAL=$(node -e "console.log(require('$STATS_FILE').skip_list_total || 0)" 2>/dev/null || echo "0")
    STATS_SECTION="
📊 **补全统计:**
* season_id: 补全 ${SEASON_FILLED} 条 / 失败 ${SEASON_FAILED} 条
* video_sn: 补全 ${VIDEO_FILLED} 条 / 失败 ${VIDEO_FAILED} 条
* 修改文件: ${FILES_MODIFIED} 个
* gamer 线路: ${GAMER_LABEL}

📋 **Skip-list:**
* 本次跳过: ${SKIPPED} 条
* 活跃跳过: ${SKIP_ACTIVE} 条 / 追踪 ${SKIP_TOTAL} 条"
    rm -f "$STATS_FILE"
  else
    STATS_SECTION=""
  fi

  # 读取当前版本号 + 上游版本信息
  CURRENT_VER="$(node -e "console.log(require('$HELPER_DIR/package.json').version)" 2>/dev/null)"

  # 确保有上游信息（正式模式时 get_upstream_info 已在 publish 部分调用过）
  if [ -z "$UPSTREAM_VER" ]; then
    get_upstream_info
  fi

  if [ -n "$NEXT_VER" ] && [ -n "${PUBLISH_STATUS:-}" ]; then
    VERSION_SECTION="
📦 **发布:**
* 我们的版本: v${NEXT_VER}
* 上游版本: v${UPSTREAM_VER} (${UPSTREAM_TAG_DT_CST})
* 状态: ${PUBLISH_STATUS}"
  elif [ -n "$NEXT_VER" ]; then
    VERSION_SECTION="
📦 **版本:** v${NEXT_VER}
* 基于上游: v${UPSTREAM_VER} (${UPSTREAM_TAG_DT_CST})"
  else
    VERSION_SECTION="
* 上游版本: v${UPSTREAM_VER} (${UPSTREAM_TAG_DT_CST})"
  fi

  # 判断是数据补全还是测试提交
  if [ "$TEST_COMMIT" = "1" ] || [ "$FORCE_PUSH" = "1" ]; then
    RUN_MODE="🧪 **测试模式**"
  else
    RUN_MODE=""
  fi

  send_dingtalk_notification "auto-sync 执行成功" "✅ 自动同步任务已完成。${RUN_MODE}
${VERSION_SECTION}
${STATS_SECTION}

🚀 **推送:** ✅ 已推送至 GitHub

时间: $(get_cst_time)
来自：bangumi data"
else
  log "无数据变更，跳过钉钉通知。"

  # 清理 stats 文件（有数据但无变更时也可能存在）
  [ -f "$STATS_FILE" ] && rm -f "$STATS_FILE"
fi
