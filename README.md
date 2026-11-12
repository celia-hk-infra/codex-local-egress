# codex-local-egress：远程 Codex 经本地出口访问 OpenAI

## 1. 方案原理简介

### 解决的问题

**远程服务器的网络无法直接访问 OpenAI 服务，但本地个人电脑可以访问（比如挂着VPN）。**

本方案让远程服务器上的 Codex CLI，通过隧道使用本地个人电脑的网络出口访问 OpenAI 服务，不需要开放远程服务器的公网端口，也不需要修改全局代理设置。

端口转发使用 [Microsoft Dev Tunnels](https://learn.microsoft.com/en-us/azure/developer/dev-tunnels/get-started) 的 `devtunnel` CLI。

远程服务器和本地个人电脑都需要能出站访问 Dev Tunnels 中继。本地网络出口需要能访问 OpenAI。

### 连接关系

```text
远程服务器 Linux                           本地个人电脑 macOS / WSL

Codex CLI
  │
  │ HTTP 代理，使用 GOST 用户名和密码
  ▼
devtunnel connect 的回环入口
127.0.0.1:<端口>
  │
  │ Dev Tunnels 反向转发
  │ 两端登录同一个账号
  ▼
                                           devtunnel host
                                             │
                                             ▼
                                           GOST HTTP 代理
                                           127.0.0.1:<同一端口>
                                             │
                                             ▼
                                           本地个人电脑网络出口
                                             │
                                             ▼
                                           OpenAI 服务
```

`devtunnel host` 跑在有 GOST 的本地个人电脑上，把该端口交到中继。`devtunnel connect` 跑在远程服务器上，在远程的 `127.0.0.1` 上监听同一个端口号，并接到本地 GOST。Codex 把这个远程回环地址当作 HTTP 代理。

固定采用以下配置：

- **GOST 开启用户名和密码认证**。
- GOST 与远程 `devtunnel connect` 都只使用 `127.0.0.1`。
- 端口、代理密码和 tunnel id 由本地脚本写入同一个 `connection.env`。这份文件复制到远程一次后可以反复使用。
- macOS 和 Windows WSL 共用一套 Bash 本地脚本。
- 代理环境变量只设置给脚本启动的 `curl` 和 Codex，不修改全局环境。
- 隧道由本地脚本创建为持久隧道，使用登录账号的默认访问控制。`local.sh` 执行 `devtunnel host`，`remote.sh connect` 执行 `devtunnel connect`。两端登录同一个账号，令牌在各自仓库目录的 `.devtunnel/`。

仍需手动完成一次：把本地生成的 `connection.env` 复制到远程。两边终端不能直接传文件时，可以把文件内容贴到自己的 Google Doc，再到远程保存下来。同一条隧道还在时，不用再次复制。

---

## 2. 安装依赖

### 2.1 本地个人电脑：macOS

假设已经安装 Homebrew，并且可以执行 `python3`，不单独安装 Python。

通过 Homebrew 安装：

```bash
brew install gost
brew install --cask devtunnel
```

对应的软件包：[GOST](https://formulae.brew.sh/formula/gost)、[devtunnel](https://formulae.brew.sh/cask/devtunnel)。`devtunnel` 的安装命令来自[官方 macOS 说明](https://learn.microsoft.com/en-us/azure/developer/dev-tunnels/get-started?tabs=macos)。

检查命令：

```bash
gost -V
devtunnel --version
python3 --version
curl --version
```

GOST 使用 v3。Python 仅用于标准库功能，不需要安装额外的 Python 包。

macOS 上，Homebrew 安装的 `devtunnel` 与 `local.sh` 启动的 GOST 使用同一套 `127.0.0.1`。

### 2.2 本地个人电脑：Windows

推荐使用 **WSL**。GOST、`devtunnel host` 和 `local.sh` 都在 WSL 的 Bash 中运行，这样三者使用同一套 `127.0.0.1`。

按照 [GOST 官方仓库](https://github.com/go-gost/gost) 安装 Linux 版本，本文不提供安装脚本。

`devtunnel` 在 WSL 中按[官方 Linux 说明](https://learn.microsoft.com/en-us/azure/developer/dev-tunnels/get-started?tabs=linux)安装，安装后 `PATH` 能找到 `devtunnel`。网络出口是 WSL 的网络出口，相关限制见注意事项。WSL 中若出现第 2.4 节的 ICU 错误，按该节处理。

确保 WSL 中可以执行：

```bash
gost -V
devtunnel --version
python3 --version
curl --version
```

GOST 使用 v3。

### 2.3 远程服务器：Linux

远程服务器需要：

- devtunnel
- Python 3
- curl
- Codex CLI

`codex` 由用户自行安装。`devtunnel` 下载官方 Linux 二进制，直链来自[官方 Linux 说明](https://learn.microsoft.com/en-us/azure/developer/dev-tunnels/get-started?tabs=linux)。

文件名必须是 `devtunnel`，所在目录必须已经在当前 shell 的 `PATH` 里。当前 shell 要能直接运行命令名 `devtunnel`。`remote.sh` 不修改 `PATH`，直接调用这个命令。

下面放到 `~/.local/bin`。先看这个目录是否已在当前 `PATH` 中：

```bash
echo "$PATH" | tr ':' '\n' | grep -Fx "$HOME/.local/bin" || true
```

没有输出时，先把 `~/.local/bin` 加入用来启动 `remote.sh` 的 shell 的 `PATH`，或把下面的 `-o` 改成 `echo "$PATH"` 里已有、且本人可写的目录。文件名仍是 `devtunnel`。

`uname -m` 为 `x86_64` 时：

```bash
mkdir -p "$HOME/.local/bin"
curl -fL --retry 3 \
  'https://aka.ms/TunnelsCliDownload/linux-x64' \
  -o "$HOME/.local/bin/devtunnel"
chmod 755 "$HOME/.local/bin/devtunnel"
hash -r
```

`uname -m` 为 `aarch64` 或 `arm64` 时，URL 换成 `https://aka.ms/TunnelsCliDownload/linux-arm64`，保存路径和权限相同。

确认当前 `PATH` 找到的就是这份文件：

```bash
command -v devtunnel
devtunnel --version
python3 --version
curl --version
codex --version
```

`command -v devtunnel` 应输出刚才写入的绝对路径。没有输出，或输出的是其他路径时，先把文件放到当前 `PATH` 中的目录，再继续。

`devtunnel --version` 若报错 `Couldn't find a valid ICU package installed on the system`，先完成第 2.4 节，再重新检查。

### 2.4 远程服务器：devtunnel 缺少 ICU

`devtunnel` 是 .NET 程序。系统里没有它能加载的 ICU 时，`devtunnel --version` 会失败，错误为：

```text
Couldn't find a valid ICU package installed on the system
```

给 devtunnel 进程设置 `LD_LIBRARY_PATH`，指向同一个目录里的这三类库：

- `libicuuc.so*`
- `libicui18n.so*`
- `libicudata.so*`

conda / miniconda 自带的库，以及下载后解压到用户目录的库，都可以。先用已经存在的库；找不到再下载。路径以实际查找结果为准，不要写成某一台机器上的固定安装位置。

处理办法是让 devtunnel 进程加载到这些 ICU 动态库。WSL 里的 Linux 版 devtunnel 若出现同一错误，也按本节处理。

#### 使用已有的 conda / miniconda

当前 shell 能执行 `conda` 时，先看安装根目录和环境位置：

```bash
conda info --base
conda info --envs
```

在安装根目录下查找。装在该根目录里的环境会一起被找到：

```bash
find "$(conda info --base)" \
  \( -name 'libicuuc.so*' -o -name 'libicui18n.so*' -o -name 'libicudata.so*' \) \
  2>/dev/null
```

`conda info --envs` 若列出根目录以外的环境，对该环境目录再执行同样的 `find`。

当前 shell 没有 `conda` 命令，但系统里有 miniconda / conda 时，把起点换成实际安装根目录：

```bash
find /实际的安装根目录 \
  \( -name 'libicuuc.so*' -o -name 'libicui18n.so*' -o -name 'libicudata.so*' \) \
  2>/dev/null
```

三类文件要在同一目录，例如都在：

```text
<安装根目录>/envs/<环境名>/lib/
```

或都在：

```text
<安装根目录>/lib/
```

用该目录验证。多个目录都包含这三类文件时，任选一个能让 `--version` 成功的目录：

```bash
ICU_LIB_DIR="/实际包含这三类库的目录"

ls -l "$ICU_LIB_DIR"/libicuuc.so* \
      "$ICU_LIB_DIR"/libicui18n.so* \
      "$ICU_LIB_DIR"/libicudata.so*

LD_LIBRARY_PATH="${ICU_LIB_DIR}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
  devtunnel --version
```

能输出版本号就跳到下面的包装脚本。仍然报错时，换一个目录；没有可用目录时再下载。

#### 下载 ICU 并解压到用户目录

需要本机已有 `rpm2cpio` 和 `cpio`。下面的包是 Oracle Linux 8 的 x86_64 `libicu` 60.3，对应 glibc 2.28 这一代的 x86_64 系统。若能拿到与当前发行版、CPU 架构匹配的 `libicu` 包，优先使用那个包，仍然只解压、不安装到系统目录。

```bash
uname -m
command -v rpm2cpio
command -v cpio
```

`uname -m` 为 `x86_64`，且两个命令都存在时：

```bash
mkdir -p "$HOME/.local/icu"

curl -fL --retry 3 \
  'https://yum.oracle.com/repo/OracleLinux/OL8/baseos/latest/x86_64/getPackage/libicu-60.3-2.el8_1.x86_64.rpm' \
  -o "$HOME/.local/icu/libicu.rpm"
```

下载失败时停下来，先处理 `curl` 的报错，不要继续解压。

```bash
(
  set -o pipefail
  cd "$HOME/.local/icu" &&
    rpm2cpio libicu.rpm | cpio -idm --no-absolute-filenames
)
```

这里只解压文件，不执行 RPM 安装脚本，也不修改 `/usr/lib64`。

```bash
ls -l "$HOME/.local/icu/usr/lib64"/libicu*.so*

LD_LIBRARY_PATH="$HOME/.local/icu/usr/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
  ldd "$HOME/.local/icu/usr/lib64/libicui18n.so.60"
```

`ldd` 出现 `not found`、`GLIBC_* not found` 或 `GLIBCXX_* not found` 时，这个包与当前系统不匹配。换一份与系统匹配的 `libicu`，不要替换系统 glibc。

匹配时：

```bash
ICU_LIB_DIR="$HOME/.local/icu/usr/lib64"

LD_LIBRARY_PATH="${ICU_LIB_DIR}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
  devtunnel --version
```

#### 让后续的 devtunnel 带上 LD_LIBRARY_PATH

`--version` 成功后，把库路径写入包装脚本。之后这个用户执行 `devtunnel` 时会自行设置 `LD_LIBRARY_PATH`。该变量只作用于 devtunnel，不写入全局环境。

先用 `command -v devtunnel` 找到当前 `PATH` 上的二进制，再在同一目录写入包装脚本。该目录需要可写。当前 shell 的 `ICU_LIB_DIR` 是刚才成功的目录。包装脚本创建一次即可。以后更新二进制时，覆盖同目录的 `devtunnel.bin`，保留名为 `devtunnel` 的包装脚本。

```bash
DEVTUNNEL_BIN="$(command -v devtunnel)"
DEVTUNNEL_DIR="$(cd "$(dirname "$DEVTUNNEL_BIN")" && pwd)"

mv "$DEVTUNNEL_BIN" "$DEVTUNNEL_DIR/devtunnel.bin"
chmod 755 "$DEVTUNNEL_DIR/devtunnel.bin"

cat > "$DEVTUNNEL_DIR/devtunnel" << EOF
#!/usr/bin/env bash
export LD_LIBRARY_PATH="${ICU_LIB_DIR}\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
exec "$DEVTUNNEL_DIR/devtunnel.bin" "\$@"
EOF
chmod 755 "$DEVTUNNEL_DIR/devtunnel"
hash -r

devtunnel --version
```

这次不再手动加 `LD_LIBRARY_PATH`。能输出版本号后，按第 3.1 节登录。远程随后运行 `./remote.sh connect`。本地 WSL 若也使用这个包装脚本，随后由 `local.sh` 运行 host。

---

## 3. 工具启动

把本仓库 clone 到自己选择的目录，再在该目录里启动。本地个人电脑和远程服务器各自选路径，不必放在家目录，也不必使用同一个路径。脚本按自身所在目录读写下面这些路径。clone 出来的目录称为仓库目录。

```bash
git clone https://github.com/celia-hk-infra/codex-local-egress.git <你选择的路径>
cd <你选择的路径>
```

仓库里直接执行的是 [`local.sh`](local.sh) 和 [`remote.sh`](remote.sh)。两者加载同目录的 [`devtunnel-auth.sh`](devtunnel-auth.sh)，这个文件不要单独执行。

| 命令 | 作用 |
|---|---|
| `./local.sh devtunnel login` | 本地登录 |
| `./local.sh` | 沿用连接配置，启动 GOST 和 `devtunnel host` |
| `./remote.sh devtunnel login` | 远程登录 |
| `./remote.sh connect` | 连接隧道 |
| `./remote.sh test` | 检查出口 IP |
| `./remote.sh codex` | 检查出口 IP 后启动 Codex |

脚本在仓库目录里读写这些路径：

| 路径 | 哪一端 | 内容 |
|---|---|---|
| `connection.env` | 两端。本地写出，复制到远程一次 | 端口、代理密码、tunnel id |
| `.devtunnel/` | 两端各自一份 | 登录令牌。不复制到另一台机器，不提交 |
| `logs/` | 仅本地 | `gost.log`、`devtunnel-host.log` |
| `.local.lock/` | 仅本地 | `./local.sh` 运行期间的锁 |
| `.connect.lock/` | 仅远程 | `./remote.sh connect` 运行期间的锁 |

`.connect.lock/` 只在 connect 运行时出现。若目录里还有以前的 `.state/`，那是旧的连接锁位置；确认没有 connect 在跑之后可以删掉。

启动顺序：

```text
两端：./local.sh devtunnel login 与 ./remote.sh devtunnel login（同一账号，两边各只需一次）
  ↓
本地：local.sh
  ↓
第一次：把 connection.env 复制到远程
  ↓
远程：remote.sh connect
  ↓
远程：remote.sh test
  ↓
远程：remote.sh codex
```

### 3.1 两端登录

远程和本地登录**同一个** Microsoft 或 GitHub 账号。账号令牌写在各自仓库目录的 `.devtunnel/`。

在本地仓库目录：

```bash
./local.sh devtunnel login
```

在远程仓库目录：

```bash
./remote.sh devtunnel login
```

脚本会请你选择 Microsoft 或 GitHub。也可以直接写在命令里：

```bash
./local.sh devtunnel login microsoft
./remote.sh devtunnel login github
```

远程没有浏览器，`remote.sh` 使用设备码：终端给出网址和代码，在有浏览器的电脑上打开并完成登录。本地 macOS 会打开浏览器。本地 WSL 或 Linux 同样使用设备码。

### 3.2 本地：生成配置并启动

在本地个人电脑的 macOS 终端或 WSL 中，进入仓库目录后执行：

```bash
chmod 700 .
chmod 700 local.sh
./local.sh
```

**保持这个本地终端运行。** `Ctrl+C` 会同时停止 GOST 和 `devtunnel host`。持久隧道会留下来，下次运行 `local.sh` 会继续 host 同一条隧道。

已有可用的 `connection.env` 时，终端会写“已沿用连接配置”，远程不用再复制。还没有这个文件时，看到“把这一个文件复制到远程仓库目录一次”后再复制。在此之前，远程 `remote.sh connect` 还不能使用这份配置。`remote.sh test` 成功之前，代理链路还不可用。

**以前那份临时隧道写出的 `connection.env` 不能复用。** 那种隧道在 `local.sh` 退出后就被删除了。换用现在的脚本后，第一次运行会发现旧隧道不存在，新建持久隧道并覆盖本地文件。把这个新文件再复制到远程一次即可。

配置文件结构如下，实际值以脚本写出的文件为准：

```bash
PROXY_PORT='51842'
PROXY_AUTH='codexproxy:本地生成的十六进制密码'
TUNNEL_ID='host 输出中的 tunnel id'
```

### 3.3 远程：复制配置并连接

在远程服务器把本仓库 clone 到自己选择的目录。再把本地刚写好的 `connection.env` 复制到远程仓库目录，文件名仍是 `connection.env`。两边不能直接传文件时，用自己的 Google Doc 中转：在本地打开 `connection.env`，把三行贴进文档；在远程仓库目录新建 `connection.env`，把文档里的三行原样粘进去。

```bash
cd <远程仓库目录>
chmod 700 .
chmod 700 remote.sh
chmod 600 connection.env
./remote.sh connect
```

成功时终端里会出现 `Forwarding from 127.0.0.1:<端口> to host port <端口>`。这个端口与配置文件里的 `PROXY_PORT` 相同。

**保持这个远程终端运行。** Codex 使用这里的 `127.0.0.1` 地址作为 HTTP 代理。

若提示远程端口已被占用，先释放远程上的这个端口，再重新执行 `remote.sh connect`。只要两边的 `connection.env` 还是同一份，端口就不会变。

### 3.4 远程：验证并启动 Codex

在远程服务器另开一个终端，进入同一个仓库目录：

```bash
./remote.sh test
```

成功时会返回通过本地个人电脑网络出口访问得到的公网 IP。

随后启动 Codex：

```bash
./remote.sh codex
```

`codex` 会先做同一次出口 IP 检查，再启动 Codex。参数可以直接透传：

```bash
./remote.sh codex --help
```

若远程 `remote.sh test` 失败，先确认本地 `local.sh` 和远程 `remote.sh connect` 都还在运行。出口 IP 检查只能证明代理链路可用，还要再发起一次真实 Codex 请求，确认能够访问 OpenAI 服务。

### 3.5 日常启动与停止

每次使用：

1. 两端仍是第 3.1 节的同一个账号。登录失效时重新执行 `./local.sh devtunnel login` 或 `./remote.sh devtunnel login`。
2. 本地运行 `local.sh`。已有可用的 `connection.env` 时，它会直接 host 原来的隧道。
3. 远程运行 `remote.sh connect`。远程目录里已经有同一份 `connection.env` 时，不用再复制。
4. 远程运行 `remote.sh codex`。

只有两种情况才需要再把 `connection.env` 复制到远程：本地第一次写出这个文件，或者旧隧道已经不存在、脚本覆盖了新文件。终端会直接说明要不要复制。可以用自己的 Google Doc 中转这三行。

持久隧道在 `local.sh` 退出后仍然保留。连续 30 天没有任何活动时，Dev Tunnels 会删除它。下次运行会新建隧道并覆盖 `connection.env`，这时需要再复制一次。

结束使用时，在 `local.sh` 和 `remote.sh connect` 所在终端分别按 `Ctrl+C`。

---

## 4. 注意事项

### 4.1 Windows WSL 的连通性

Windows 下，本方案中的网络出口实际是 **WSL 的网络出口**。

GOST 和 `devtunnel host` 都在 WSL 中运行，并通过 WSL 的 `127.0.0.1` 互相连接。WSL 需要能访问 OpenAI，也能出站访问 Dev Tunnels 中继。

### 4.2 本地网络出口要求

GOST 使用它所在环境的直接网络出口。

- 如果本地通过 VPN/TUN 访问 OpenAI，需确认该网络接管覆盖 GOST 所在环境。
- GOST 不保证自动继承操作系统的 HTTP 代理设置。
- Windows 浏览器能够访问，也不代表 WSL 使用相同网络线路。

### 4.3 自动端口选择的限制

`local.sh` 第一次会选择当时可用的本地回环端口，写入 `connection.env`，随后由 GOST 绑定。之后一直用这个端口。远程 `devtunnel connect` 也绑定这个端口号。选择完成到远程绑定之间，端口可能被其他进程占用。远程若提示地址已占用，先释放远程上的这个端口，再重新 connect。

确实要换端口或密码时，先停掉两端，在本地仓库目录执行 `./local.sh devtunnel delete <tunnel-id>`，再删除本地和远程的 `connection.env`，然后重新运行 `local.sh`，把新文件复制到远程一次。也可以用 `./local.sh devtunnel list -l codex-local-egress` 找出这条隧道。这两条命令使用 `.devtunnel/` 里的登录。直接运行 `devtunnel delete` 或 `devtunnel list` 看不到这份登录。

最终以远程 `remote.sh test` 成功为准。

### 4.4 访问控制

本方案同时使用：

- GOST 用户名和密码。
- Dev Tunnel 的登录访问控制。本地 `devtunnel host` 与远程 `devtunnel connect` 使用同一个账号，登录缓存在各自仓库目录的 `.devtunnel/`。

**回环监听不等于隔离同一服务器上的其他用户。** `devtunnel connect` 在远程监听 `127.0.0.1` 期间，这台服务器上的其他用户也可能连到该端口。GOST 密码用于阻止他们直接借用代理。

Dev Tunnels 中继把两端的端口转发通道接在一起。GOST 的用户名、密码，以及 HTTP `CONNECT` 的目标主机名，会出现在这条转发里。Codex 与 OpenAI 之间的 HTTPS 内容仍由 TLS 保护。

连接配置含有密码和 tunnel id：

- 只复制到自己的远程服务器。两边不能直接传文件时，用自己的 Google Doc 中转文件内容。
- 不提交到 Git。
- 本地和远程的 `connection.env` 都保持仅本人可读。
- 本地脚本写出这个文件。远程脚本只读取复制过去的这一份，并核对端口、密码和 tunnel id 的字符形式。

**多数 Linux 服务器上，任何用户都能通过 `ps` 看到其他用户进程的命令行参数**（`/proc` 未启用 `hidepid` 时）。因此：

- 远程的 `curl` 和 Codex 只从环境变量读取代理地址和密码，进程环境变量只有本人和管理员可读。
- `devtunnel connect` 的命令行只有 tunnel id，没有代理密码。
- 本地 GOST 的命令行含有代理密码。这台电脑默认只有自己使用。

此方案不能防御已控制远程服务器、本地个人电脑或 Dev Tunnels 中继的管理员。

### 4.5 Codex CLI 的代理范围

本指南针对 **Codex CLI**：

- 代理变量仅传给脚本启动的 Codex 及其子进程，不修改全局 Shell 环境。
- `HTTPS_PROXY` 的值使用 `http://`。HTTPS 请求通过 HTTP CONNECT 转发。
- 代理变量只作用于遵守这些环境变量的进程。

首次使用时，应在链路测试成功后，再发起真实 Codex 请求确认兼容性。

### 4.6 日志与异常退出

排查时查看：

```text
本地仓库目录：
logs/gost.log
logs/devtunnel-host.log
```

`devtunnel host` 的输出同时出现在本地终端和上面的日志里。`devtunnel connect` 的输出留在远程终端。

正常停止请使用 `Ctrl+C`。`local.sh` 退出时会停止 `devtunnel host`，持久隧道仍保留。换端口、密码或删除隧道见第 4.3 节。只删除 `connection.env` 不会删除云上的隧道；只删除隧道后，下次 `local.sh` 会新建一条并覆盖配置文件。

如果直接关闭终端、强制杀死进程或机器崩溃，可能留下后台进程及锁目录。本地锁是 `.local.lock/`，远程连接锁是 `.connect.lock/`。确认并停止残留进程后，再删除对应锁目录，不要直接删除锁后反复启动。

使用期间，本地个人电脑必须在线且不能休眠。

工具参数及认证行为可参考：[GOST HTTP 代理说明](https://gost.run/en/tutorials/http-tunnel/)和 [Dev Tunnels CLI 参考](https://learn.microsoft.com/en-us/azure/developer/dev-tunnels/cli-commands)。CLI 仍在预览，参数可能变化，以该参考为准。
