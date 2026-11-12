#!/usr/bin/env bash
set -euo pipefail
umask 077

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$DIR/connection.env"
LOGS="$DIR/logs"

require() {
  command -v "$1" >/dev/null || {
    echo "缺少依赖：$1" >&2
    exit 1
  }
}

# shellcheck source=devtunnel-auth.sh
source "$DIR/devtunnel-auth.sh"

case "${1:-}" in
  devtunnel)
    shift
    if [[ "${1:-}" == login ]]; then
      shift
      if [[ $# -gt 1 ]]; then
        echo "用法：$0 devtunnel login [microsoft|github]" >&2
        exit 1
      fi
      provider="$(select_provider "${1:-}")" || exit 1
      if [[ "$(uname -s)" == Darwin ]]; then
        devtunnel_login "$provider" 0
      else
        devtunnel_login "$provider" 1
      fi
      exit 0
    fi
    if [[ $# -eq 0 ]]; then
      echo "用法：$0 devtunnel login [microsoft|github]" >&2
      echo "      $0 devtunnel <devtunnel 的其他参数>" >&2
      exit 1
    fi
    prepare_devtunnel
    exec devtunnel "$@"
    ;;
  "")
    ;;
  *)
    echo "用法：$0" >&2
    echo "      $0 devtunnel login [microsoft|github]" >&2
    exit 1
    ;;
esac

for cmd in gost devtunnel python3; do
  require "$cmd"
done

prepare_devtunnel
ensure_devtunnel_login

mkdir -p "$LOGS"
chmod 700 "$LOGS"

LOCK="$DIR/.local.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
  echo "已有本地服务，或异常退出留下了锁：$LOCK" >&2
  echo "确认旧进程已停止后，再删除此锁目录。" >&2
  exit 1
fi

GOST_PID=""
HOST_PID=""

cleanup() {
  trap - EXIT INT TERM

  for pid in "$HOST_PID" "$GOST_PID"; do
    if [[ -n "$pid" ]]; then
      kill "$pid" 2>/dev/null || true
    fi
  done

  for pid in "$HOST_PID" "$GOST_PID"; do
    if [[ -n "$pid" ]]; then
      wait "$pid" 2>/dev/null || true
    fi
  done

  rmdir "$LOCK" 2>/dev/null || true
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

config_valid() {
  [[ "${PROXY_PORT:-}" =~ ^[0-9]+$ ]] || return 1
  [[ "${PROXY_AUTH:-}" =~ ^[a-z0-9]+:[0-9a-f]+$ ]] || return 1
  [[ "${TUNNEL_ID:-}" =~ ^[A-Za-z0-9][A-Za-z0-9.-]{0,80}$ ]] || return 1
}

write_config() {
  {
    printf "PROXY_PORT='%s'\n" "$PROXY_PORT"
    printf "PROXY_AUTH='%s'\n" "$PROXY_AUTH"
    printf "TUNNEL_ID='%s'\n" "$TUNNEL_ID"
  } > "$CONFIG"
  chmod 600 "$CONFIG"
}

port_is_free() {
  python3 - "$1" <<'PY'
import socket
import sys

port = int(sys.argv[1])
with socket.socket() as s:
    try:
        s.bind(("127.0.0.1", port))
    except OSError as exc:
        sys.stderr.write(f"本地端口已被占用：127.0.0.1:{port} ({exc})\n")
        sys.exit(1)
PY
}

generate_endpoint() {
  local line
  line="$(
    python3 - <<'PY'
import secrets
import socket

with socket.socket() as s:
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
print(f"{port} codexproxy:{secrets.token_hex(24)}")
PY
  )"
  PROXY_PORT="${line%% *}"
  PROXY_AUTH="${line#* }"
  [[ "$PROXY_PORT" =~ ^[0-9]+$ ]] || {
    echo "未能选择本地端口。" >&2
    exit 1
  }
  [[ "$PROXY_AUTH" =~ ^[a-z0-9]+:[0-9a-f]+$ ]] || {
    echo "未能生成代理密码。" >&2
    exit 1
  }
}

create_tunnel() {
  local out status
  set +e
  out="$(devtunnel create -d 'codex-local-egress' -l codex-local-egress -j 2>&1)"
  status=$?
  set -e
  if [[ "$status" -ne 0 ]]; then
    echo "创建持久隧道失败：" >&2
    printf '%s\n' "$out" >&2
    exit 1
  fi
  TUNNEL_ID="$(
    printf '%s\n' "$out" | python3 -c '
import json
import sys

raw = sys.stdin.read()
start = raw.find("{")
if start < 0:
    sys.exit(1)
print(json.loads(raw[start:])["tunnel"]["tunnelId"])
'
  )" || {
    echo "未能从 devtunnel create 得到 tunnel id。" >&2
    printf '%s\n' "$out" >&2
    exit 1
  }
  [[ "$TUNNEL_ID" =~ ^[A-Za-z0-9][A-Za-z0-9.-]{0,80}$ ]] || {
    echo "tunnel id 无效：$TUNNEL_ID" >&2
    exit 1
  }
}

# 已有隧道不能在 host 时用 -p 改端口，服务会拒绝批量更新。
# 端口事先登记；已经登记过同一端口时，冲突视为成功。
ensure_port() {
  local out status
  set +e
  out="$(devtunnel port create "$TUNNEL_ID" -p "$PROXY_PORT" 2>&1)"
  status=$?
  set -e
  if [[ "$status" -eq 0 ]]; then
    return 0
  fi
  if grep -q "conflicts with an existing port" <<<"$out"; then
    return 0
  fi
  echo "登记隧道端口失败：" >&2
  printf '%s\n' "$out" >&2
  exit 1
}

MODE="create"
PROXY_PORT=""
PROXY_AUTH=""
TUNNEL_ID=""

if [[ -s "$CONFIG" ]]; then
  # 仅加载本脚本写出的连接配置。
  # shellcheck disable=SC1090
  source "$CONFIG"
  if ! config_valid; then
    echo "connection.env 内容无效，没有启动：$CONFIG" >&2
    echo "要重新生成，先删除这个文件。" >&2
    exit 1
  fi

  set +e
  SHOW_OUT="$(devtunnel show "$TUNNEL_ID" 2>&1)"
  SHOW_STATUS=$?
  set -e
  if [[ "$SHOW_STATUS" -eq 0 ]]; then
    MODE="reuse"
  elif grep -q "Tunnel not found" <<<"$SHOW_OUT"; then
    MODE="replace"
  else
    echo "无法确认隧道是否还在：$TUNNEL_ID" >&2
    printf '%s\n' "$SHOW_OUT" >&2
    exit 1
  fi
fi

if [[ "$MODE" == "reuse" ]]; then
  chmod 600 "$CONFIG"
  if ! port_is_free "$PROXY_PORT"; then
    echo "这份 connection.env 固定使用该端口。请先释放端口，再重新运行。" >&2
    echo "不要改端口，否则远程的 connection.env 会对不上。" >&2
    exit 1
  fi
else
  generate_endpoint
  if ! port_is_free "$PROXY_PORT"; then
    exit 1
  fi
  create_tunnel
  write_config
fi

ensure_port

# 仅清除当前脚本进程的代理变量，不修改父 Shell。
unset HTTP_PROXY HTTPS_PROXY http_proxy https_proxy ALL_PROXY all_proxy AUTH

GOST_LOG="$LOGS/gost.log"
HOST_LOG="$LOGS/devtunnel-host.log"
: > "$GOST_LOG"
: > "$HOST_LOG"

# GOST HTTP 代理：回环监听 + 用户名密码认证。
gost \
  -L "http://${PROXY_AUTH}@127.0.0.1:${PROXY_PORT}" \
  >"$GOST_LOG" 2>&1 &
GOST_PID=$!

sleep 1

if ! kill -0 "$GOST_PID" 2>/dev/null; then
  echo "GOST 启动失败：" >&2
  cat "$GOST_LOG" >&2
  exit 1
fi

echo
echo "本地 GOST 已监听：127.0.0.1:$PROXY_PORT"
echo "GOST 已开启密码认证。日志：$GOST_LOG"
if [[ "$MODE" == "reuse" ]]; then
  echo "下面 host 已有隧道：$TUNNEL_ID"
else
  echo "下面 host 新建的持久隧道：$TUNNEL_ID"
fi
echo "按 Ctrl+C 会停止 host 和 GOST。这条隧道会保留，下次还能用。"
echo

# 用伪终端运行 host，输出既显示在当前终端，也立即写入日志。
# 不带 -p：端口已登记在持久隧道上。
python3 - "$HOST_LOG" devtunnel host "$TUNNEL_ID" <<'PY' &
import errno
import os
import pty
import select
import signal
import sys

log_path = sys.argv[1]
cmd = sys.argv[2:]

pid, fd = pty.fork()
if pid == 0:
    try:
        os.execvp(cmd[0], cmd)
    except OSError as exc:
        os.write(2, f"无法启动 {cmd[0]}：{exc}\n".encode())
        os._exit(127)

def stop(_signum, _frame):
    try:
        os.kill(pid, signal.SIGTERM)
    except OSError:
        pass
    raise SystemExit(0)

signal.signal(signal.SIGTERM, stop)
signal.signal(signal.SIGHUP, stop)

with open(log_path, "ab", buffering=0) as log:
    while True:
        try:
            ready, _, _ = select.select([fd], [], [], 0.5)
        except InterruptedError:
            continue
        if not ready:
            wpid, _status = os.waitpid(pid, os.WNOHANG)
            if wpid:
                break
            continue
        try:
            data = os.read(fd, 4096)
        except OSError as exc:
            if exc.errno == errno.EIO:
                break
            raise
        if not data:
            break
        os.write(1, data)
        log.write(data)
os.waitpid(pid, 0)
PY
HOST_PID=$!

TUNNEL_SEEN=""
for ((i=0; i<300; i++)); do
  if ! kill -0 "$HOST_PID" 2>/dev/null; then
    echo "devtunnel host 启动失败。" >&2
    exit 1
  fi

  TUNNEL_SEEN="$(
    sed -nE \
      's/.*Ready to accept connections for tunnel:[[:space:]]*([A-Za-z0-9.-]+).*/\1/p' \
      "$HOST_LOG"
  )" || true
  TUNNEL_SEEN="${TUNNEL_SEEN%%$'\n'*}"
  TUNNEL_SEEN="${TUNNEL_SEEN//$'\r'/}"
  if [[ -n "$TUNNEL_SEEN" ]]; then
    break
  fi
  sleep 0.2
done

if [[ "$TUNNEL_SEEN" != "$TUNNEL_ID" ]]; then
  echo "未能从 host 输出确认 tunnel id。配置文件已写好，但先不要复制。" >&2
  echo "host 仍在运行，输出见终端和：$HOST_LOG" >&2
else
  echo
  case "$MODE" in
    reuse)
      echo "已沿用连接配置：$CONFIG"
      echo "端口、密码和 tunnel id 都没变。远程不用再复制 connection.env。"
      ;;
    create)
      echo "连接配置已写好：$CONFIG"
      echo "把这一个文件复制到远程仓库目录一次，文件名仍是 connection.env。"
      echo "之后重新运行 local.sh 会沿用同一份，不用再复制。"
      ;;
    replace)
      echo "原来的隧道已经不存在，这份 connection.env 不能继续用。"
      echo "持久隧道连续 30 天没有活动会被删除。"
      echo "已新建持久隧道，并覆盖：$CONFIG"
      echo "请把这个新文件再复制到远程仓库目录一次，文件名仍是 connection.env。"
      echo "之后就不用每次复制了。"
      ;;
  esac
  echo "然后在远程仓库目录执行：./remote.sh connect"
  echo
fi

while true; do
  if ! kill -0 "$HOST_PID" 2>/dev/null; then
    echo "devtunnel host 已退出。" >&2
    exit 1
  fi
  if ! kill -0 "$GOST_PID" 2>/dev/null; then
    echo "GOST 已退出，日志：$GOST_LOG" >&2
    exit 1
  fi
  sleep 1
done
