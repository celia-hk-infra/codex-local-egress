#!/usr/bin/env bash
# 由 local.sh 和 remote.sh 加载。登录令牌放在仓库目录的 .devtunnel/。
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  echo "这个文件由 local.sh 和 remote.sh 加载，不要直接执行。" >&2
  exit 1
fi

: "${DIR:?}"
DEVTUNNEL_STATE="$DIR/.devtunnel"

chmod_devtunnel_state() {
  find "$DEVTUNNEL_STATE" -type d -exec chmod 700 {} +
  find "$DEVTUNNEL_STATE" -type f -exec chmod 600 {} +
}

prepare_devtunnel() {
  require devtunnel
  mkdir -p "$DEVTUNNEL_STATE"
  chmod_devtunnel_state
  export DEVTUNNELS_USER_STATE_DIR="$DEVTUNNEL_STATE"
}

select_provider() {
  local choice="${1:-}"
  if [[ -z "$choice" ]]; then
    if [[ ! -t 0 ]]; then
      echo "请指定登录方式：microsoft 或 github。" >&2
      echo "例如：$0 devtunnel login microsoft" >&2
      return 1
    fi
    echo "选择登录账号：" >&2
    echo "  1) Microsoft" >&2
    echo "  2) GitHub" >&2
    printf '请输入 1 或 2：' >&2
    read -r choice
  fi
  choice="$(printf '%s' "$choice" | tr '[:upper:]' '[:lower:]')"
  case "$choice" in
    1|microsoft) printf '%s\n' microsoft ;;
    2|github) printf '%s\n' github ;;
    *)
      echo "无法识别的登录方式：${choice:-（空）}" >&2
      echo "请使用 1、2、microsoft 或 github。" >&2
      return 1
      ;;
  esac
}

# 第二个参数为 1 时使用设备码，为 0 时使用浏览器。
devtunnel_login() {
  local provider="$1"
  local device_code="$2"
  local label
  local -a args=(user login)
  local status show_rc

  prepare_devtunnel
  case "$provider" in
    microsoft)
      label="Microsoft"
      args+=(-e)
      ;;
    github)
      label="GitHub"
      args+=(-g)
      ;;
    *)
      echo "无法识别的登录方式：$provider" >&2
      exit 1
      ;;
  esac
  if [[ "$device_code" == 1 ]]; then
    args+=(-d)
  fi

  echo "登录缓存目录：$DEVTUNNEL_STATE"
  echo "登录账号：$label"
  if [[ "$device_code" == 1 ]]; then
    echo "使用设备码登录。终端接下来会给出网址和代码，在有浏览器的电脑上打开并完成登录。"
  fi

  devtunnel "${args[@]}"
  chmod_devtunnel_state

  set +e
  status="$(devtunnel user show 2>&1)"
  show_rc=$?
  set -e
  printf '%s\n' "$status"
  if [[ "$show_rc" -ne 0 ]] || grep -q "Not logged in" <<<"$status"; then
    echo "登录未完成。" >&2
    exit 1
  fi
}

ensure_devtunnel_login() {
  local status show_rc
  set +e
  status="$(devtunnel user show 2>&1)"
  show_rc=$?
  set -e
  if [[ "$show_rc" -ne 0 ]]; then
    echo "无法确认 devtunnel 登录状态：" >&2
    printf '%s\n' "$status" >&2
    exit 1
  fi
  if grep -q "Not logged in" <<<"$status"; then
    echo "还没有登录。请先在这个仓库目录执行：$0 devtunnel login" >&2
    exit 1
  fi
}
