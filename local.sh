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

for cmd in gost devtunnel python3; do
  require "$cmd"
done

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

# 新的 tunnel id 出来之前，先去掉上一份配置，避免把旧文件复制到远程。
rm -f "$CONFIG"

LINE="$(
  python3 - <<'PY'
import secrets
import socket

with socket.socket() as s:
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
print(f"{port} codexproxy:{secrets.token_hex(24)}")
PY
)"
PROXY_PORT="${LINE%% *}"
PROXY_AUTH="${LINE#* }"

[[ "$PROXY_PORT" =~ ^[0-9]+$ ]] || {
  echo "未能选择本地端口。" >&2
  exit 1
}
[[ "$PROXY_AUTH" =~ ^[a-z0-9]+:[0-9a-f]+$ ]] || {
  echo "未能生成代理密码。" >&2
  exit 1
}

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
echo "下面启动 devtunnel host。tunnel id 写入配置后即可复制到远程。"
echo "按 Ctrl+C 会同时停止 host 和 GOST。"
echo

# 用伪终端运行 host，输出既显示在当前终端，也立即写入日志。
python3 - "$HOST_LOG" devtunnel host -p "$PROXY_PORT" <<'PY' &
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

TUNNEL_ID=""
for ((i=0; i<300; i++)); do
  if ! kill -0 "$HOST_PID" 2>/dev/null; then
    echo "devtunnel host 启动失败。" >&2
    exit 1
  fi

  TUNNEL_ID="$(
    sed -nE \
      's/.*Ready to accept connections for tunnel:[[:space:]]*([A-Za-z0-9.-]+).*/\1/p' \
      "$HOST_LOG"
  )" || true
  TUNNEL_ID="${TUNNEL_ID%%$'\n'*}"
  TUNNEL_ID="${TUNNEL_ID//$'\r'/}"
  [[ -n "$TUNNEL_ID" ]] && break
  sleep 0.2
done

if [[ ! "$TUNNEL_ID" =~ ^[A-Za-z0-9][A-Za-z0-9.-]{0,80}$ ]]; then
  echo "未能从 host 输出得到 tunnel id。配置文件没有写入。" >&2
  echo "host 仍在运行，输出见终端和：$HOST_LOG" >&2
else
  {
    printf "PROXY_PORT='%s'\n" "$PROXY_PORT"
    printf "PROXY_AUTH='%s'\n" "$PROXY_AUTH"
    printf "TUNNEL_ID='%s'\n" "$TUNNEL_ID"
  } > "$CONFIG"
  chmod 600 "$CONFIG"

  echo
  echo "连接配置已写好：$CONFIG"
  echo "把这一个文件复制到远程："
  echo "  ~/codex-local-egress/connection.env"
  echo "然后在远程执行：~/codex-local-egress/remote.sh connect"
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
