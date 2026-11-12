#!/usr/bin/env bash
set -euo pipefail
umask 077

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$DIR/connection.env"
STATE="$DIR/.state"
mkdir -p "$STATE"
chmod 700 "$STATE"

require() {
  command -v "$1" >/dev/null || {
    echo "缺少依赖：$1" >&2
    exit 1
  }
}

load_config() {
  [[ -s "$CONFIG" ]] || {
    echo "缺少连接配置：$CONFIG" >&2
    echo "请把本地的 connection.env 复制到这个路径。" >&2
    exit 1
  }
  # 仅加载从自己的本地脚本复制来的可信配置。
  # shellcheck disable=SC1090
  source "$CONFIG"
  [[ "${PROXY_PORT:-}" =~ ^[0-9]+$ ]] || {
    echo "PROXY_PORT 无效：$CONFIG" >&2
    exit 1
  }
  [[ "${PROXY_AUTH:-}" =~ ^[a-z0-9]+:[0-9a-f]+$ ]] || {
    echo "PROXY_AUTH 无效：$CONFIG" >&2
    exit 1
  }
  [[ "${TUNNEL_ID:-}" =~ ^[A-Za-z0-9][A-Za-z0-9.-]{0,80}$ ]] || {
    echo "TUNNEL_ID 无效：$CONFIG" >&2
    exit 1
  }
}

case "${1:-}" in
  connect)
    if [[ $# -ne 1 ]]; then
      echo "用法：$0 connect" >&2
      exit 1
    fi

    require devtunnel
    require python3
    load_config

    LOCK="$STATE/connect.lock"
    if ! mkdir "$LOCK" 2>/dev/null; then
      echo "已有 connect，或异常退出留下了锁：$LOCK" >&2
      echo "确认旧进程已停止后，再删除此锁目录。" >&2
      exit 1
    fi

    CONN_PID=""

    cleanup() {
      trap - EXIT INT TERM
      if [[ -n "$CONN_PID" ]]; then
        kill "$CONN_PID" 2>/dev/null || true
        wait "$CONN_PID" 2>/dev/null || true
      fi
      rmdir "$LOCK" 2>/dev/null || true
    }

    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    python3 - "$PROXY_PORT" <<'PY'
import socket
import sys

port = int(sys.argv[1])
with socket.socket() as s:
    try:
        s.bind(("127.0.0.1", port))
    except OSError as exc:
        sys.stderr.write(
            f"远程端口已被占用：127.0.0.1:{port} ({exc})\n"
            "停掉本地 local.sh 后重新运行，再把新的 connection.env 复制到远程。\n"
        )
        sys.exit(1)
PY

    echo
    echo "正在连接 tunnel：$TUNNEL_ID"
    echo "成功时，下面的输出中应有："
    echo "  Forwarding from 127.0.0.1:$PROXY_PORT to host port $PROXY_PORT."
    echo "保持当前终端运行，按 Ctrl+C 停止。"
    echo "另一个远程终端可运行："
    echo "  $DIR/remote.sh test"
    echo "  $DIR/remote.sh codex"
    echo

    devtunnel connect "$TUNNEL_ID" &
    CONN_PID=$!
    wait "$CONN_PID" || true
    echo "devtunnel connect 已退出。" >&2
    exit 1
    ;;

  test|codex)
    require curl
    require python3
    load_config

    MODE="$1"
    shift

    python3 - "$PROXY_PORT" <<'PY'
import socket
import sys

port = int(sys.argv[1])
with socket.socket() as s:
    s.settimeout(2)
    try:
        s.connect(("127.0.0.1", port))
    except OSError:
        sys.stderr.write(
            f"远程 127.0.0.1:{port} 没有在监听。\n"
            "请先保持 remote.sh connect 运行。\n"
        )
        sys.exit(1)
PY

    PROXY_URL="http://${PROXY_AUTH}@127.0.0.1:${PROXY_PORT}"

    export HTTP_PROXY="$PROXY_URL"
    export HTTPS_PROXY="$PROXY_URL"
    export http_proxy="$PROXY_URL"
    export https_proxy="$PROXY_URL"
    export NO_PROXY='localhost,127.0.0.1,::1'
    export no_proxy="$NO_PROXY"
    unset ALL_PROXY all_proxy

    # curl 从上面的环境变量读取代理，不把代理密码放到命令行参数中。
    echo "验证代理链路，出口 IP："
    curl --fail --show-error --silent \
      --connect-timeout 10 \
      --max-time 30 \
      https://api.ipify.org
    echo

    if [[ "$MODE" == codex ]]; then
      require codex
      exec codex "$@"
    fi
    ;;

  *)
    echo "用法：$0 {connect|test|codex [Codex 参数...]}" >&2
    exit 1
    ;;
esac
