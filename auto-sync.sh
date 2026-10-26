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

# ── Netlify 边缘反代 ────────────────────────────────────────────────
#
# 三个专用路径按「整段 URL 前缀替换」的方式工作：目标地址的 GitHub 前缀整体
# 换成对应的反代路径，而不是把完整 URL 拼接在反代之后。映射关系由 Netlify
# Edge Function 的 PROXY_CONFIG 定义：
#
#   /gh-wan0ge    ← https://github.com/wan0ge              自有仓库，读写
#   /gh-upstream  ← https://github.com/bangumi-data        上游仓库，只读
#   /gh-api       ← https://api.github.com/repos/bangumi-data/bangumi-data
#
# 重写交由 git 的 url.<base>/.insteadOf 前缀匹配完成，例如：
#   https://github.com/wan0ge/helper.git
#     → https://elegy233.netlify.app/gh-wan0ge/helper.git
#
# 写操作需要凭据随链路抵达 GitHub：凭据置于反代 URL 的 userinfo 段，使 git
# 向反代主机发出 Basic Authorization，边缘函数以 headers: request.headers
# 原样转发请求头，GitHub 据此完成鉴权。只读操作不带凭据。
NETLIFY_PROXY="https://elegy233.netlify.app"
WRITE_PROXY="${NETLIFY_PROXY}/gh-wan0ge"
READ_PROXY="${NETLIFY_PROXY}/gh-upstream"
API_PROXY="${NETLIFY_PROXY}/gh-api"

# 各反代路径承接的 GitHub 源前缀
WRITE_PROXY_PREFIX="https://github.com/wan0ge/"
READ_PROXY_PREFIX="https://github.com/bangumi-data/"
API_PROXY_PREFIX="https://api.github.com/repos/bangumi-data/bangumi-data"

# 公共 GitHub 代理（读写操作的次级链路）
#
# 形态上把完整目标 URL 拼接在代理之后（https://<代理>/https://github.com/…），
# 与 Netlify 边缘反代的前缀替换不同，两者各自构造一套重写规则。
# 这类服务不向 GitHub 转交 Authorization，写操作通常止步于 GitHub 的匿名写保护，
# 但仍保留在链路里：读操作无需凭据即可受益，且个别节点在透传认证时可用。
GITHUB_PROXIES="https://gh-proxy.org,https://hk.gh-proxy.org,https://cdn.gh-proxy.org,https://edgeone.gh-proxy.org"

# 参与同步的仓库地址
#
# 这里直接书写 GitHub 规范地址，而非引用仓库里的 remote 别名：remote URL 由外部
# 环境决定，可被写成嵌套代理形态，而 insteadOf 依赖 URL 前缀精确匹配，一旦写成
# 嵌套形态就命中不到重写规则，请求会退化为直连该失效节点。
ORIGIN_BANGUMI_DATA="https://github.com/wan0ge/bangumi-data.git"
ORIGIN_HELPER="https://github.com/wan0ge/helper.git"
UPSTREAM_BANGUMI_DATA="https://github.com/bangumi-data/bangumi-data.git"
UPSTREAM_HELPER="https://github.com/bangumi-data/helper.git"

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

# 检测 git credential store 是否登记了公共代理的凭据。
# 未配置 GITHUB_TOKEN 时，这是向公共代理完成写操作的唯一凭据来源。
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
  # 使用 curl_github 带代理回退，避免路由器上直连 api.github.com 不通
  local api_out
  api_out=$(curl_github "https://api.github.com/repos/bangumi-data/bangumi-data/tags?per_page=1" 10 || echo "[]")

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
    # 同样使用代理回退获取 commit 详情
    local commit_out
    commit_out=$(curl_github "$commit_url" 10 || echo "{}")
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

  # API 失败时回退用 ls-remote 只拿版本号（带代理回退）
  if [ -z "$UPSTREAM_VER" ]; then
    UPSTREAM_VER=$(git_ls_remote_with_proxy --tags https://github.com/bangumi-data/bangumi-data.git \
      | grep -v '\^{}' | awk '{print $2}' \
      | sed 's|refs/tags/v||' | sort -V | tail -1)
  fi

  # 兜底
  [ -z "$UPSTREAM_VER" ] && UPSTREAM_VER="0.3.208"
  [ -z "$UPSTREAM_TAG_DT_CST" ] && UPSTREAM_TAG_DT_CST="未知时间"
}

# 计算下一个发布版本号
#
# 版本号乘数扩充法：发布的 Patch = 上游 Patch × 100 + 内部修订次数
#   主版本号和次版本号与上游保持一致，Patch 末尾两位用于内部发布。
#
#   上游 patch 升级（up > curUpstreamPatch）→ 对齐上游 × 100，内部重置：
#     示例：cur=0.3.21702, up=0.3.218 → 0.3.21800
#   上游未变（up == curUpstreamPatch）→ 内部修订 +1：
#     示例：cur=0.3.21700, up=0.3.217 → 0.3.21701
#   上游 major/minor 升级 → 跟随上游，内部重置：
#     示例：cur=0.3.21705, up=0.4.0 → 0.4.000
#
# 参数：$1=CUR_VER（当前版本字符串），$2=UP_VER（上游版本字符串）
# 用环境变量传参，避免 bash 变量嵌进 JS 导致语法错误
calc_next_version() {
  CUR_VER="$1"
  UP_VER="$2"
  node -e "
    const cur_raw = process.env.CUR_VER;
    const up_str  = process.env.UP_VER;

    function parseVer(s) {
      const m = String(s || '').match(/^(\d+)\.(\d+)\.(\d+)/);
      if (!m) return [0, 3, 200];
      return [Number(m[1]), Number(m[2]), Number(m[3])];
    }

    const cur = parseVer(cur_raw);
    const up  = parseVer(up_str);

    // 从当前版本号提取上游追踪版本和内部修订次数
    const curUpstreamPatch = Math.floor(cur[2] / 100);
    const curInternal = cur[2] % 100;

    let next;
    if (up[0] > cur[0] || (up[0] === cur[0] && up[1] > cur[1])) {
      // 上游 major 或 minor 升级：跟随上游，内部重置
      next = [up[0], up[1], up[2] * 100];
    } else if (up[2] > curUpstreamPatch) {
      // 上游 patch 升级：对齐上游 × 100，内部重置
      next = [cur[0], cur[1], up[2] * 100];
    } else {
      // 上游未变：内部修订 +1
      next = [cur[0], cur[1], curUpstreamPatch * 100 + (curInternal + 1)];
    }

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

# ── Git 反代链路 ─────────────────────────────────────────────────────────────
#
# 主机到 GitHub 的通路按以下顺序递进，任一步成功即结束：
#
#   1. Netlify 边缘反代：三个专用路径按「URL 前缀整体替换」改写目标地址，
#      由 git 的 url.<base>/.insteadOf 完成。写操作需要凭据随链路抵达
#      GitHub，因此凭据放在反代 URL 的 userinfo 段，git 据此向反代主机发出
#      Basic Authorization，边缘函数以原请求头转发给 GitHub 完成鉴权。
#   2. 局域网 HTTP 隧道：HTTP CONNECT 转发，凭据对隧道透明，
#      仅在 HTTP_PROXY_LIST 非空且隧道可达时启用。
#   3. 直连：最后兜底。
#
# insteadOf 依赖 URL 前缀的精确匹配，因此 git 操作一律使用脚本内写明的
# GitHub 规范地址，不引用仓库里的 remote 别名。

# 把 GitHub 规范地址改写成对应的 Netlify 反代地址
# 未匹配到已知前缀时原样返回，交由调用方继续尝试隧道或直连
to_proxy_url() {
  case "$1" in
    "${WRITE_PROXY_PREFIX}"*) printf '%s\n' "${WRITE_PROXY}/${1#${WRITE_PROXY_PREFIX}}" ;;
    "${READ_PROXY_PREFIX}"*)  printf '%s\n' "${READ_PROXY}/${1#${READ_PROXY_PREFIX}}" ;;
    # API 前缀不带尾斜杠，剩余部分自带前导斜杠，直接相接以免多出一个斜杠
    "${API_PROXY_PREFIX}"*)   printf '%s\n' "${API_PROXY}${1#${API_PROXY_PREFIX}}" ;;
    *)                        printf '%s\n' "$1" ;;
  esac
}

# 装配 git 的 url.<base>/.insteadOf 重写参数
#
# $1 传 auth 时，把凭据放进自有仓库那条规则的 URL userinfo 段
# 结果写入 PROXY_ARG_* 三个变量，调用处不加引号展开即得 "-c" 与
# "url.<base>/.insteadOf=<prefix>" 两个词
set_proxy_args() {
  local write_base="$WRITE_PROXY"
  if [ "$1" = "auth" ] && [ -n "$GITHUB_TOKEN" ]; then
    write_base="https://${GITHUB_USER}:${GITHUB_TOKEN}@${WRITE_PROXY#https://}"
  fi
  PROXY_ARG_WRITE="-c url.${write_base}/.insteadOf=${WRITE_PROXY_PREFIX}"
  PROXY_ARG_READ="-c url.${READ_PROXY}/.insteadOf=${READ_PROXY_PREFIX}"
  PROXY_ARG_API="-c url.${API_PROXY}/.insteadOf=${API_PROXY_PREFIX}"
}

# 逐个尝试公共 GitHub 代理
#
# 这类代理把完整目标 URL 拼接在自己之后，形态与 Netlify 边缘反代不同，
# 因而每个节点都要独立构造一套重写规则：
#   https://github.com/<owner>/<repo>.git
#     → https://<代理>/https://github.com/<owner>/<repo>.git
#
# auth 模式把凭据放入代理 URL 的 userinfo 段；plain 模式下 git 自行向
# credential store 索取该代理主机的凭据，无凭据时以匿名身份请求。
#
# $1=操作  $2=仓库地址  $3=分支或 refspec  $4=仓库标签  $5=附加参数
# $6=auth|plain
try_public_proxies() {
  local action="$1"
  local repo="$2"
  local ref="$3"
  local repo_path="$4"
  local extra_args="$5"
  local mode="$6"

  [ -z "$GITHUB_PROXIES" ] && return 1

  local old_ifs="$IFS"
  local proxy target
  IFS=','
  for proxy in $GITHUB_PROXIES; do
    IFS="$old_ifs"
    [ -z "$proxy" ] && continue

    target="url.${proxy}/https://github.com/"
    if [ "$mode" = "auth" ] && [ -n "$GITHUB_TOKEN" ]; then
      target="url.https://${GITHUB_USER}:${GITHUB_TOKEN}@${proxy#https://}/https://github.com/"
    fi

    if git -c "${target}.insteadOf=https://github.com/" \
          $action "$repo" "$ref" $extra_args --quiet 2>/dev/null; then
      log "$action ($repo_path) 经公共代理 $proxy 完成"
      return 0
    fi
    log "$action ($repo_path) 公共代理 $proxy 失败"
    IFS=','
  done
  IFS="$old_ifs"
  return 1
}

# 经 Netlify 边缘反代执行 git 操作，逐层回退：
# 边缘反代 → 公共代理 → 局域网 HTTP 隧道 → 直连
#
# $1=操作(push/fetch/pull)  $2=仓库的 GitHub 规范地址  $3=分支或 refspec
# $4=日志中标识仓库的名称  $5=附加给 git 的参数
git_with_proxy() {
  local action="$1"
  local repo="$2"
  local ref="$3"
  local repo_path="$4"
  local extra_args="${5:-}"

  export GIT_TERMINAL_PROMPT=0

  # push 需要凭据随链路抵达 GitHub，其余操作走不带凭据的只读链路
  if [ "$action" = "push" ]; then
    set_proxy_args auth
  else
    set_proxy_args plain
  fi

  # 1. Netlify 边缘反代
  if git $PROXY_ARG_WRITE $PROXY_ARG_READ $PROXY_ARG_API \
        $action "$repo" "$ref" $extra_args --quiet 2>/dev/null; then
    log "$action ($repo_path) 经 Netlify 边缘反代完成"
    return 0
  fi
  log "$action ($repo_path) 边缘反代不可用，尝试公共代理..."

  # 2. 公共 GitHub 代理
  # 写操作把凭据嵌入代理 URL；没有 GITHUB_TOKEN 时交给 credential store 供给，
  # 两者皆无则该层完成不了写操作，跳过以免空跑一轮。
  if [ "$action" != "push" ] || [ -n "$GITHUB_TOKEN" ] || [ "$CREDENTIAL_STORE_OK" = "1" ]; then
    if [ "$action" = "push" ] && [ -n "$GITHUB_TOKEN" ]; then
      public_mode="auth"
    else
      public_mode="plain"
    fi
    if try_public_proxies "$action" "$repo" "$ref" "$repo_path" "$extra_args" "$public_mode"; then
      return 0
    fi
  else
    log "$action ($repo_path) 缺少公共代理凭据（无 GITHUB_TOKEN，credential store 未登记），跳过该层"
  fi

  # 3. 局域网 HTTP 隧道（HTTP CONNECT 转发，凭据对隧道透明）
  if [ -n "$HTTP_PROXY_LIST" ]; then
    local old_ifs="$IFS"
    IFS=','
    for hp in $HTTP_PROXY_LIST; do
      IFS="$old_ifs"
      if git -c "http.proxy=$hp" $action "$repo" "$ref" $extra_args --quiet 2>/dev/null; then
        log "$action ($repo_path) 经 HTTP 隧道 $hp 完成"
        return 0
      fi
      log "$action ($repo_path) HTTP 隧道 $hp 失败"
      IFS=','
    done
    IFS="$old_ifs"
  fi

  # 4. 直连
  log "$action ($repo_path) 隧道不可用，尝试直连..."
  if git $action "$repo" "$ref" $extra_args --quiet 2>/dev/null; then
    log "$action ($repo_path) 直连完成"
    return 0
  fi

  log "$action ($repo_path) 所有路径均失败，错误详情："
  local final_out
  final_out=$(git $action "$repo" "$ref" $extra_args 2>&1) || true
  echo "$final_out" | sed 's/^/  | /' >&2

  # 远端已含所推内容时 git 判定无需推送，网络层的断开不改变该结论
  if echo "$final_out" | grep -q "Everything up-to-date" \
    && ! echo "$final_out" | grep -qE "(send-pack: unexpected disconnect|the remote end hung up unexpectedly)"; then
    log "$action ($repo_path) 远端已是最新（Everything up-to-date）"
    return 0
  fi

  echo "$LOG_PREFIX ERROR: $action ($repo_path) 边缘反代、公共代理、HTTP 隧道与直连均失败（详情见上方）" >&2
  return 1
}

# GitHub HTTP API 请求（带反代回退）
# 用法：curl_github <url> [timeout]
# 尝试顺序与 git_with_proxy 一致：Netlify 边缘反代 → 局域网 HTTP 隧道 → 直连
# 成功时输出响应到 stdout 并返回 0，失败返回 1
# 逐个尝试公共代理、再回退到局域网隧道与直连
curl_github() {
  local url="$1"
  local timeout="${2:-10}"
  local out
  local proxied
  local old_ifs="$IFS"
  local hp
  local proxy

  proxied=$(to_proxy_url "$url")

  if out=$(curl -s -m "$timeout" "$proxied" 2>/dev/null) && [ -n "$out" ]; then
    log "curl ($url) 经 Netlify 边缘反代完成"
    echo "$out"
    return 0
  fi
  log "curl ($url) 边缘反代不可用，尝试公共代理..."

  local proxy
  IFS=','
  for proxy in $GITHUB_PROXIES; do
    IFS="$old_ifs"
    [ -z "$proxy" ] && continue
    if out=$(curl -s -m "$timeout" "${proxy}/${url}" 2>/dev/null) && [ -n "$out" ]; then
      log "curl ($url) 经公共代理 $proxy 完成"
      echo "$out"
      return 0
    fi
    IFS=','
  done
  IFS="$old_ifs"

  log "curl ($url) 公共代理不可用，尝试局域网 HTTP 隧道..."

  if [ -n "$HTTP_PROXY_LIST" ]; then
    IFS=','
    for hp in $HTTP_PROXY_LIST; do
      IFS="$old_ifs"
      if out=$(curl -s -m "$timeout" --proxy "$hp" "$url" 2>/dev/null) && [ -n "$out" ]; then
        log "curl ($url) 经 HTTP 隧道 $hp 完成"
        echo "$out"
        return 0
      fi
      IFS=','
    done
    IFS="$old_ifs"
  fi

  log "curl ($url) 隧道不可用，尝试直连..."
  if out=$(curl -s -m "$timeout" "$url" 2>/dev/null) && [ -n "$out" ]; then
    log "curl ($url) 直连完成"
    echo "$out"
    return 0
  fi

  log "curl ($url) 所有路径均失败"
  return 1
}

# git ls-remote（带反代回退）
# 用法：git_ls_remote_with_proxy <args...>（参数直接传递给 git ls-remote）
# 尝试顺序与 git_with_proxy 一致：
# Netlify 边缘反代 → 公共代理 → 局域网 HTTP 隧道 → 直连
# 成功时输出结果到 stdout 并返回 0，失败返回 1
git_ls_remote_with_proxy() {
  local out
  local old_ifs="$IFS"
  local hp
  local proxy

  set_proxy_args plain

  if out=$(GIT_TERMINAL_PROMPT=0 git $PROXY_ARG_WRITE $PROXY_ARG_READ $PROXY_ARG_API \
        ls-remote "$@" 2>/dev/null) && [ -n "$out" ]; then
    log "ls-remote 经 Netlify 边缘反代完成"
    echo "$out"
    return 0
  fi
  log "ls-remote 边缘反代不可用，尝试公共代理..."

  IFS=','
  for proxy in $GITHUB_PROXIES; do
    IFS="$old_ifs"
    [ -z "$proxy" ] && continue
    if out=$(GIT_TERMINAL_PROMPT=0 \
          git -c "url.${proxy}/https://github.com/.insteadOf=https://github.com/" \
          ls-remote "$@" 2>/dev/null) && [ -n "$out" ]; then
      log "ls-remote 经公共代理 $proxy 完成"
      echo "$out"
      return 0
    fi
    IFS=','
  done
  IFS="$old_ifs"

  log "ls-remote 公共代理不可用，尝试局域网 HTTP 隧道..."

  if [ -n "$HTTP_PROXY_LIST" ]; then
    IFS=','
    for hp in $HTTP_PROXY_LIST; do
      IFS="$old_ifs"
      if out=$(GIT_TERMINAL_PROMPT=0 git -c "http.proxy=$hp" -c "http.sslVerify=false" \
            ls-remote "$@" 2>/dev/null) && [ -n "$out" ]; then
        log "ls-remote 经 HTTP 隧道 $hp 完成"
        echo "$out"
        return 0
      fi
      IFS=','
    done
    IFS="$old_ifs"
  fi

  log "ls-remote 隧道不可用，尝试直连..."
  if out=$(GIT_TERMINAL_PROMPT=0 git ls-remote "$@" 2>/dev/null) && [ -n "$out" ]; then
    log "ls-remote 直连完成"
    echo "$out"
    return 0
  fi

  log "ls-remote 所有路径均失败"
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
  log "cred store:   ~/.git-credentials 已登记公共代理凭据"
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

  cleanup_merge "$BANGUMI_DATA_DIR"
  git_with_proxy fetch "$UPSTREAM_BANGUMI_DATA" master "bangumi-data/bangumi-data"
  git checkout master --quiet 2>/dev/null || true

  # 记录 fetch 前的 HEAD，用于判断上游是否有新内容
  _before=$(git rev-parse HEAD 2>/dev/null || echo "")
  # 合并说明显式给出：git 的默认标题会把 insteadOf 改写后的反代地址写进去
  git merge FETCH_HEAD -X ours -m "merge: 同步上游 bangumi-data" 2>/dev/null || true

  # merge 失败后，检测并自动解决冲突
  #   git ls-files --unmerged 无法检测 DU/UD（modify/delete）冲突，
  #   必须用 git status --porcelain 补检。
  #   冲突状态前缀：UU=内容冲突，DU=我们删了上游改了，UD=我们改了上游删了
  if git ls-files --unmerged 2>/dev/null | grep -q . \
      || git status --porcelain 2>/dev/null | grep -qE '^(UU|DU|UD)'; then
    log "检测到合并冲突，正在自动解决..."
    # DU：我们删了、上游改了 → 保持删除
    for f in $(git status --porcelain 2>/dev/null | grep '^DU ' | cut -c4-); do
      log "  冲突(DU) $f：我们已删除，上游有修改，保持删除"
      git rm -f -- "$f" 2>/dev/null || true
    done
    # UD：我们改了、上游删了 → 保持我们的版本
    for f in $(git status --porcelain 2>/dev/null | grep '^UD ' | cut -c4-); do
      log "  冲突(UD) $f：上游已删除，我们仍有修改，保持我们的版本"
      git checkout --ours -- "$f" 2>/dev/null || true
      git add -- "$f" 2>/dev/null || true
    done
    # 创建 merge commit 完成合并
    git -c user.name="auto-sync" -c user.email="auto-sync@localhost" \
      commit --no-edit 2>/dev/null || true
    log "冲突已自动解决，合并完成。"
  elif git status --porcelain 2>/dev/null | grep -qE '^(DU|UD|UU|AA)'; then
    # 其他未自动解决的冲突（理论上不会到这里，上面的 if 已经捕获）
    log "无法自动解决的冲突，重置到 HEAD..."
    git merge --abort 2>/dev/null || true
    git reset --hard HEAD 2>/dev/null || true
  fi

  _after=$(git rev-parse HEAD 2>/dev/null || echo "")
  if [ "$_before" != "$_after" ]; then
    UPSTREAM_UPDATED=1
    log "上游有新提交，将创建触发提交。"
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

  cleanup_merge "$HELPER_DIR"
  git_with_proxy fetch "$UPSTREAM_HELPER" master "bangumi-data/helper"
  # 合并说明显式给出：git 的默认标题会把 insteadOf 改写后的反代地址写进去
  git merge FETCH_HEAD -X ours -m "merge: 同步上游 helper" 2>/dev/null || true

  # 冲突自动解决（与 bangumi-data 同步逻辑一致）
  if git ls-files --unmerged 2>/dev/null | grep -q . \
      || git status --porcelain 2>/dev/null | grep -qE '^(UU|DU|UD)'; then
    log "helper 同步检测到合并冲突，正在自动解决..."
    for f in $(git status --porcelain 2>/dev/null | grep '^DU ' | cut -c4-); do
      log "  冲突(DU) $f：我们已删除，上游有修改，保持删除"
      git rm -f -- "$f" 2>/dev/null || true
    done
    for f in $(git status --porcelain 2>/dev/null | grep '^UD ' | cut -c4-); do
      log "  冲突(UD) $f：上游已删除，我们仍有修改，保持我们的版本"
      git checkout --ours -- "$f" 2>/dev/null || true
      git add -- "$f" 2>/dev/null || true
    done
    git -c user.name="auto-sync" -c user.email="auto-sync@localhost" \
      commit --no-edit 2>/dev/null || true
    log "helper 冲突已自动解决，合并完成。"
  fi

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
  # 上游有更新时，即使补全失败也要继续发布（上游数据已有变化）
  if [ "$UPSTREAM_UPDATED" = "1" ]; then
    log "WARN: fill-missing-ids.js 失败，但上游有更新，继续创建触发提交..."
    send_dingtalk_notification "补全任务失败（仍将继续发布）" "⚠️ fill-missing-ids.js 执行失败，但上游有更新，将继续发布新版本\n\n时间: $(get_cst_time)\n来自：bangumi data"
  else
    send_dingtalk_notification "补全任务失败" "❌ fill-missing-ids.js 执行失败\n\n时间: $(get_cst_time)\n来自：bangumi data"
    die "fill-missing-ids.js 执行失败"
  fi
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
# 版本号策略（乘数扩充法）：
#   测试模式 (--test-commit / --test-full)：
#     使用 0.3.200-test.1, 0.3.200-test.2 ... 格式
#     -test 后缀保证和正式版完全隔离，npm 不会冲突
#   正式模式：
#     发布 Patch = 上游 Patch × 100 + 内部修订次数（详见 calc_next_version 函数注释）
#     上游 patch 升级 → 对齐上游 × 100（如 0.3.21702 → 0.3.21800）
#     上游未变 → 内部修订 +1（如 0.3.21700 → 0.3.21701）
#
# 触发条件：上游有更新（UPSTREAM_UPDATED=1）或数据文件有补全提交（DATA_COMMITTED=1）
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
      # 正式模式：根据当前版本与上游版本的关系计算下一版本号
      # 详见 calc_next_version 函数注释
      NEXT_VER=$(calc_next_version "$CURRENT_VER" "$UPSTREAM_VER")
      log "版本计算：当前版=$CURRENT_VER, 上游版=$UPSTREAM_VER, 下一个版=$NEXT_VER"
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
    if npm publish --access public --tag latest 2>&1; then
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
    # 先取回落后再合并。合并说明显式给出，避免默认标题写入反代地址
    git_with_proxy fetch "$ORIGIN_BANGUMI_DATA" master "bangumi-data/bangumi-data" \
      || log "fetch 失败，跳过同步远程..."
    git merge FETCH_HEAD -X ours --allow-unrelated-histories \
      -m "merge: 同步远端 bangumi-data" 2>/dev/null \
      || log "远端无新内容或与本地无关联，按当前内容推送..."
    # 先推 master 分支（不含 tags）
    if git_with_proxy push "$ORIGIN_BANGUMI_DATA" master "bangumi-data/bangumi-data"; then
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
    remote_ref="$(git_ls_remote_with_proxy --tags "$ORIGIN_BANGUMI_DATA" "refs/tags/$NEXT_VER_TAG" | awk '{print $1}')"
    local_ref="$(git rev-parse "$NEXT_VER_TAG" 2>/dev/null)"
    if [ -z "$remote_ref" ]; then
      log "tag $NEXT_VER_TAG 远端不存在，创建..."
      git tag -f "$NEXT_VER_TAG" >/dev/null 2>&1
      git_with_proxy push "$ORIGIN_BANGUMI_DATA" "refs/tags/$NEXT_VER_TAG" "bangumi-data/bangumi-data (tag $NEXT_VER_TAG)"
    elif [ "$local_ref" != "$remote_ref" ]; then
      log "tag $NEXT_VER_TAG 远端指向不同 commit ($remote_ref)，强制更新..."
      git tag -f "$NEXT_VER_TAG" >/dev/null 2>&1
      git_with_proxy push "$ORIGIN_BANGUMI_DATA" "refs/tags/$NEXT_VER_TAG" "bangumi-data/bangumi-data (tag $NEXT_VER_TAG)" "--force"
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
    git_with_proxy fetch "$ORIGIN_HELPER" master "bangumi-data/helper" \
      || log "fetch 失败，跳过同步远程..."
    git merge FETCH_HEAD -m "merge: 同步远端 helper" 2>/dev/null \
      || log "远端无新内容，按当前内容推送..."
    if git_with_proxy push "$ORIGIN_HELPER" master "bangumi-data/helper"; then
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
