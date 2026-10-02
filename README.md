# 密语 miyu-chat —— 自己搭的端到端加密网页聊天

装在你自己的服务器上的“加密微信网页版”：打开网页就能和朋友聊天，消息在浏览器里加密，服务器只存看不懂的密文。

- 一个程序文件就能跑（Go 静态编译，网页已经打包在里面），内存占用十几 MB，256MB 的小鸡也够用。
- 没有账号密码：**你的私钥就是你的身份**，登录时浏览器用私钥签名证明“我是我”。
- 支持 Debian / Ubuntu（systemd）和 Alpine（OpenRC），独立服务器、VPS、NAT 小鸡都能装。
- 两种接入方式，安装时自己选：**直连模式**（公网 IP / 端口映射）或 **Cloudflare Tunnel 模式**（不用公网 IP、不用开端口，NAT 小鸡推荐）。
- 装好后有一个管理命令 **`miyu`**：在服务器任何目录输入 `miyu` 就能改设置、更新、看状态、卸载。

> **v1.1.1 新增 `miyu` 管理命令**：以前装完要用 `sh install.sh config` 之类的命令，但安装脚本放在 `/tmp` 里，换个目录或重启后就找不到了。现在安装、更新、改设置时都会自动装好 `/usr/local/bin/miyu`。**已经装了 v1.1.0 的机器**，运行一次下面的一键命令（末尾加 `update`，见“[老版本怎么装上 miyu 命令](#老版本v110怎么装上-miyu-命令)”）就有了，设置和聊天数据都不动。
>
> **v1.1.0 升级须知（不兼容旧网页）**：登录和每条操作的签名格式都改了，旧版网页登录不上（会提示刷新）。服务器更新后，请让所有人**刷新一下聊天网页**。建议更新后运行 `miyu config` 填上你的聊天域名（`MIYU_HOST`，见下文）。

## 能做什么

- **加好友**：把自己的 ID（64 位十六进制）发给朋友，对方输入后发起申请，你点“通过”就成为好友。
- **加密聊天**：消息在浏览器里加密后才发出去，只有你和好友的浏览器能解开。
- **双删单条消息**：任意一方点消息旁边的“双删”，服务器彻底删除这条密文，双方页面同时消失。
- **双删整个会话**：点“双删全部记录”，你们之间的所有聊天记录在服务器和双方页面上一起清空。
- **删除好友**：同时双删全部聊天记录。
- **在线状态**：好友在线时头像上有绿点。

## 小白安装教程

整个过程大约 10 分钟：准备东西 → 选模式 → 粘贴一条命令、回答几个问题 →（Tunnel 模式）去 Cloudflare 后台点几下 → 打开网页登录。

### 第 0 步：准备什么

| 要准备的 | 说明 |
| --- | --- |
| 一台服务器 | 独立服务器（母鸡）、普通 VPS（小鸡）、NAT 小鸡都行。系统要是 **Debian / Ubuntu / Alpine**，内存 256MB 以上。 |
| root 权限 | 能用 SSH 登录，并且是 root 用户（不是的话先运行 `sudo -i` 切到 root）。 |
| 一个域名（推荐） | 例如 `example.com`，并且**已经接入 Cloudflare**（Cloudflare 后台能看到它，状态是“有效 / Active”）。Tunnel 模式必须有；直连模式可以先不用，直接拿 IP 试。 |
| SSH 工具 | Windows 用 PowerShell、Xshell、FinalShell 都行；Mac 用“终端”。 |

> 下文里的 `chat.example.com`、`<公网IP>`、`<端口>` 都是**占位符**，请换成你自己的。

### 第 1 步：我该选哪种模式

先看你的机器是哪一种（商家后台写着“NAT”、或者只给你几个端口的，就是 NAT 小鸡）：

| 你的机器 | 选哪种 | 为什么 |
| --- | --- | --- |
| **NAT 小鸡**（多人共用一个公网 IP，商家只给几个端口） | **Cloudflare Tunnel 模式** | 不用端口映射、不用 80/443 端口，最省事 |
| **有公网 IP 的 VPS / 独立服务器**，域名在 Cloudflare | 两种都行，**推荐 Tunnel 模式** | 不用开防火墙端口，还能藏起服务器真实 IP，HTTPS 自动有 |
| 有公网 IP，但**暂时没有域名**，只想先试试 | 直连模式 | 装完用 `http://<公网IP>:<端口>` 就能打开，以后随时用 `miyu config` 换成 Tunnel |

两种模式的区别：

| | 直连模式 | Cloudflare Tunnel 模式 |
| --- | --- | --- |
| 程序监听 | `0.0.0.0:<端口>`（外面能直接访问） | `127.0.0.1:<端口>`（只有本机能访问） |
| 需要公网 IP / 端口映射 | 需要 | **不需要** |
| 防火墙 | 脚本放行这个端口 | 不开任何入站端口 |
| HTTPS | 要自己接 Cloudflare 小黄云 + 回源端口规则 | Cloudflare 自动提供 |
| 需要域名 | 不一定（可以先用 IP） | 需要一个托管在 Cloudflare 的域名 |

拿不准就选 Tunnel；选错了也没关系，装好后运行 `miyu config` 就能换，聊天数据不丢。

### 第 2 步（只有 Tunnel 模式）：在 Cloudflare 建 Tunnel，复制令牌

直连模式跳过这一步，直接看第 3 步。

1. **想好聊天网址**，例如 `chat.example.com`。
   - ⚠️ 只能用**一级子域名**：`chat.example.com` 可以；`chat.abc.example.com` 这种两级的会报**证书错误**（Cloudflare 免费套餐的证书不包两级子域名）。
2. 打开 Cloudflare 后台：<https://dash.cloudflare.com/?to=/:account/tunnels>（左侧菜单 **Networking（网络）→ Tunnels**）。
   （老界面在 Zero Trust → Networks → Connectors → Cloudflare Tunnels，操作一样。Cloudflare 后台经常改版，菜单名字可能略有不同。）
3. 点 **Create a tunnel（创建隧道）**，名字随便起，比如 `miyu-chat`，再点 **Create Tunnel**。
4. 页面会显示一条安装命令，里面 `--token` 或 `service install` 后面那一长串 **`eyJ` 开头的字符就是令牌**。
   - 只复制这串令牌就行（整条命令一起复制也可以，脚本会自动挑出令牌），**那条安装命令不用运行**，一键脚本会帮你装好 cloudflared。
   - **令牌等于这条隧道的密码**，别发给别人、别截图外传。
5. 先别关这个页面，第 4 步还要回来。

服务器要能访问外网的 `7844` 端口（cloudflared 用它连 Cloudflare，绝大多数 VPS 默认可以；连不上时脚本会提示 Tunnel 没连上）。

### 第 3 步：SSH 登录服务器，粘贴一键命令

1. 用 SSH 连上你的服务器（root 用户）。
2. 复制下面这一整段，粘贴进去，回车（缺 curl 会自动装；GitHub 连不上会自动换 jsDelivr 镜像）：
   ```sh
   sh -c 'command -v curl >/dev/null 2>&1 || { if command -v apk >/dev/null 2>&1; then apk add --no-cache curl ca-certificates; elif command -v apt-get >/dev/null 2>&1; then apt-get update && apt-get install -y curl ca-certificates; fi; }; ok=; for u in "https://raw.githubusercontent.com/imthnio/miyu-chat/main/install.sh?cb=$(date +%s)" "https://cdn.jsdelivr.net/gh/imthnio/miyu-chat@main/install.sh"; do curl -fSL --connect-timeout 20 --max-time 180 --retry 2 -o /tmp/miyu-install.sh "$u" 2>/dev/null; if [ -f /tmp/miyu-install.sh ] && head -c 9 /tmp/miyu-install.sh 2>/dev/null | grep -q "^#!/bin/sh"; then ok=1; break; fi; done; if [ -n "$ok" ]; then sh /tmp/miyu-install.sh "$@"; else echo "下载失败：连不上 GitHub 和镜像站，请检查服务器网络后重试。"; exit 1; fi' miyu-install
   ```
3. 脚本会自动识别系统和机器类型（独立服务器 / VPS / NAT 小鸡），然后**一个一个问你问题**。每个问题屏幕上都有说明，照着下表填就行：

| 脚本问的 | 是什么意思 | 填什么（例子） |
| --- | --- | --- |
| **接入方式** `1` 或 `2` | 别人怎么访问你的聊天服务（见第 1 步） | Tunnel 模式填 `2`，直连模式填 `1`。检测到 NAT 小鸡时直接回车就是推荐的 `2` |
| **端口** | 聊天程序在这台机器上占用的“门牌号”，没有默认值，必须自己输 | Tunnel 模式：随便一个没被占用的数字，例如 `8080`（记住它，第 4 步要填）。直连 + 普通 VPS：例如 `8080`。直连 + NAT 小鸡：填商家后台端口映射里的**内部端口** |
| **外部端口**（只有直连 + NAT 小鸡问） | 别人在浏览器里输入的那个端口，商家把它转到你的内部端口 | 商家后台端口映射里和内部端口同一行的另一个数字，例如 `20123`；一样就直接回车 |
| **Tunnel 令牌**（只有 Tunnel 模式问） | 第 2 步复制的 `eyJ...` 一长串 | 粘贴后直接回车。**输入时屏幕上不显示任何字，这是正常的**（防止被人看到） |
| **聊天域名** | 你打算用来打开聊天网页的网址，登录时会核对，**填错了会登录失败** | `chat.example.com`（只填域名，不要 `https://`）。直连模式没有域名就直接回车，脚本会自动加上 `<公网IP>:<外部端口>` |
| **邀请码** | “进门口令”：设置后，新用户第一次登录要先填它，陌生人没法注册 | 建议选 `1` 让脚本随机生成（装完只显示一次，记下来发给朋友）；也可以选 `2` 自己输入；选 `3` 不要 |
| **最多用户数** | 最多能注册多少个身份 | 自己和朋友用填 `20`、`50` 就够；直接回车 = 不限制 |
| **数据库上限（MB）** | 聊天记录最多占多少硬盘 | 直接回车 = `2000`，小鸡硬盘小很有用；`0` = 不限制 |

4. 脚本会从 GitHub Release 下载程序（失败自动换 jsDelivr），**先核对 SHA256 校验值再安装**，然后注册成系统服务（开机自启、崩溃自动重启）。Tunnel 模式还会从 Cloudflare 官方的 GitHub 发布页下载 cloudflared，**同样核对 Cloudflare 公布的 SHA256 校验值**，再注册一个 `miyu-cloudflared` 服务。
5. **装好的样子**：最后会显示绿色的 `[信息] 安装完成！`，下面一个方框里写着怎么访问、邀请码（如果是随机生成的）、以及 `miyu` 管理命令的用法。
   - Tunnel 模式会显示：**`Tunnel 转发目标请设为 http://127.0.0.1:<端口>`**，第 4 步要用。
   - 直连模式会显示：**在浏览器地址栏里输入 `http://<公网IP>:<外部端口>`**。
   - 看到红色 `[错误]`：照着它下面的提示做；装了一半的话运行 `miyu uninstall` 清理后重装。

### 第 4 步 A（Tunnel 模式）：回 Cloudflare 后台，把域名指到 Tunnel

1. 回到 Tunnels 页面，点进你刚建的 Tunnel，状态应该是 **Healthy（健康）**。
2. 打开 **Routes（路由）** 标签 → **Add route（添加路由）** → **Published application（发布应用）**。
3. **Subdomain（子域名）** 填 `chat`，**Domain（域名）** 在下拉框里选 `example.com`，路径留空。
4. **Service URL（服务地址）** 填脚本打印的那个：`http://127.0.0.1:<端口>`（是 `http` 不是 `https`，端口要和安装时填的一样）。
5. 点 **Save（保存）**。Cloudflare 会自动建好 DNS 记录，不用自己去 DNS 页面加，也不用设置回源端口规则和 SSL 模式。
   （如果提示 DNS 里已经有同名记录：先去 DNS 页面把旧的 `chat` 记录删掉再保存。）
6. 浏览器打开 `https://chat.example.com`，能看到“密语 · 加密聊天”登录页就成功了。WebSocket 默认就能用。接着看下面“[第一次怎么登录 / 怎么用](#第一次怎么登录--怎么用)”。

> 第 4 步填的域名要和安装时填的“聊天域名”一样，不一样登录会提示“密钥校验失败”，运行 `miyu config` 改成一样即可。
>
> 令牌泄露了怎么办：在 Cloudflare 后台删掉这个 Tunnel、重新建一个，再运行 `miyu config`，选 Tunnel 模式后粘贴新令牌。

### 第 4 步 B（直连模式）：打开网页，再按需接上 Cloudflare

**有公网 IP 的 VPS / 独立服务器：**

1. 在电脑或手机浏览器的地址栏里输入安装结束时显示的地址，例如 `http://<公网IP>:8080`（是 `http` 不是 `https`，冒号和端口不能少），能看到登录页就装好了。
2. 打不开：去商家后台的**安全组 / 防火墙**放行这个端口（TCP）。
3. 想用域名 + HTTPS（推荐，复制按钮、记住密钥都需要 HTTPS）：按下面“[直连模式接 Cloudflare](#直连模式接-cloudflare小黄云--回源端口)”做。如果安装时用的是 Cloudflare 支持的 HTTP 端口（80、8080、8880、2052、2082、2086、2095），可以跳过其中的回源端口规则。

**NAT 小鸡：**

1. 先确认商家后台已经有一条端口映射 `<外部端口>` → `<内部端口>`（TCP）。
2. 浏览器打开 `http://<公网IP>:<外部端口>`（注意是**外部端口**，不是内部端口），能看到登录页就装好了。
3. 想用域名 + HTTPS：按下面“[直连模式接 Cloudflare](#直连模式接-cloudflare小黄云--回源端口)”做（NAT 小鸡一般没有 80 端口，需要回源端口规则）。其实更推荐运行 `miyu config` 换成 Tunnel 模式，步骤更少。

### 直连模式接 Cloudflare（小黄云 + 回源端口）

> 更推荐 Tunnel 模式（步骤少、不用端口映射）。下面是直连模式的做法，以 NAT 小鸡为例，普通 VPS 步骤一样。

| 占位符 | 意思 | 在哪看 |
| --- | --- | --- |
| `chat.example.com` | 你想用的聊天域名 | 你自己的域名（已托管在 Cloudflare） |
| `<公网IP>` | 服务器的公网 IP | 商家后台，或安装结束时脚本显示的 IP |
| `<内部端口>` | 安装时填的端口，程序在机器里监听它 | 安装时你自己填的 |
| `<外部端口>` | 商家映射到内部端口的公网端口（普通 VPS 和内部端口一样） | 商家后台“端口映射/端口转发” |

1. **商家后台**：确认已有一条映射 `<外部端口>` → `<内部端口>`（TCP），安全组放行 `<外部端口>`。
2. **先直连测试**：浏览器打开 `http://<公网IP>:<外部端口>`，能看到登录页再继续。
3. **添加 DNS 记录**：Cloudflare → 你的域名 → DNS → 添加 `A` 记录，名称 `chat`，内容 `<公网IP>`，**代理状态点成橙色云朵（已代理）**。
4. **回源端口规则**：Cloudflare 默认用 80 端口连你的服务器，NAT 小鸡一般没有 80，所以要改端口：
   Rules（规则）→ Origin Rules（源站规则）→ 创建规则 → 条件选“主机名 等于 `chat.example.com`” → “目标端口（Destination Port）”改写为 `<外部端口>` → 部署。
5. **SSL 模式选“灵活（Flexible）”**：因为程序本身是 HTTP，没有证书。
   - 整个域名都改：SSL/TLS → 概述 → 选“灵活”。
   - 只改这个子域名（推荐，不影响你的其他网站）：Rules → Configuration Rules（配置规则）→ 条件“主机名 等于 `chat.example.com`” → SSL 选“灵活”。
   - 建议打开 SSL/TLS → 边缘证书 → “始终使用 HTTPS”。
6. **WebSocket**：Cloudflare 默认已开启（网络 → WebSockets），不用改。聊天连接走的路径是 `/ws`。
7. 安装时（或用 `miyu config`）把聊天域名填成 `chat.example.com`（脚本会自动再加上 `<公网IP>:<外部端口>`），然后打开 `https://chat.example.com` 登录。

## 第一次怎么登录 / 怎么用

### 1. 注册（生成你的身份）

1. 浏览器打开你的聊天网址（例如 `https://chat.example.com`，直连模式先用 `http://<公网IP>:<外部端口>` 也行）。
2. 点 **生成新密钥**，输入框里会出现一串 64 位的字符，这就是你的**私钥**。
3. 点 **复制私钥**，存到安全的地方（密码管理器、自己的备忘录）。
   - 私钥 = 你的账号 + 密码。**丢了就永远找不回这个身份和好友**，没有“找回密码”，服务器也帮不了你。
   - 私钥**不要发给任何人**，包括好友和管理员。
4. 如果服务器设置了邀请码，在 **邀请码（服务器要求时填写）** 那一栏填上（问搭服务器的人要；搭服务器的就是你自己的话，邀请码在安装结束时显示过，忘了可以用 root 运行 `grep INVITE /etc/miyu-chat/miyu.env` 查看）。已经注册过的人以后登录不用再填。
5. 点 **登录**。

### 2. 记住密钥（可选）

- 勾选 **在这个浏览器上记住密钥**，再设一个至少 6 位的**本地密码**。私钥会用它加密后才存进这个浏览器。
- 以后打开网页只要输入本地密码点 **解锁** 就能进；本地密码只在这个浏览器里有效，服务器不知道它。忘了就点 **换一个密钥登录**，重新粘贴私钥。
- 公共电脑、别人的电脑**别勾**。用完点 **退出**，浏览器里保存的密钥会一起删掉。
- 只有用 `https://` 打开时才能勾选（用 `http://IP:端口` 打开时会自动禁用）。

### 3. 加好友

1. 左上角 **我的 ID（发给朋友加好友）**，点 **复制**，把 ID 发给朋友。ID 是公开的，可以随便给。
2. 朋友在 **输入好友 ID 添加** 那一栏粘贴你的 ID，点 **添加**。
3. 你这边会出现“好友申请”，点 **通过**（不认识就点 **拒绝**）。
4. 可以在 **设置昵称** 那里给自己起个名字，好友能看到（昵称是明文的，服务器也能看到）。
5. 好友 ID 最好通过别的可靠渠道（当面、电话、其他聊天软件）核对一遍。

### 4. 聊天和双删

- 点好友名字，在下面输入消息，Enter 发送，Shift+Enter 换行。
- 消息在你的浏览器里加密后才发出，服务器只能存一堆看不懂的密文。
- 点某条消息旁边的 **双删**：这条消息在双方那里都会被彻底删除。你和对方都能删任意一条。
- **双删全部记录**：清空你们两人的整段聊天，双方都清空，不能恢复。
- **删除好友**：删好友，同时双删全部聊天记录。
- 双删能让服务器删掉密文、双方页面清掉，但没法阻止对方提前截图或复制。

### 5. 换手机 / 电脑

打开同一个网址，粘贴你保存的私钥登录，好友都还在；之前的聊天记录也在服务器上（加密的），会照常显示。

## 日常管理：`miyu` 命令

装好后，用 root 在服务器**任何目录**输入下面的命令就行，不用再找安装脚本，重启也不会丢：

| 想做什么 | 输入 | 说明 |
| --- | --- | --- |
| 打开菜单 | `miyu` | 显示菜单：1) 修改设置 2) 更新 3) 状态 4) 卸载 5) 退出，输入数字选择 |
| 查看状态 | `miyu status` | 显示模式、端口、聊天网址、聊天程序和 cloudflared 两个服务的状态，并实际访问一次确认能用 |
| 改设置 | `miyu config` | 切换直连/Tunnel 模式、换 Tunnel 令牌、改聊天网址、邀请码和上限（端口和聊天数据不变） |
| 更新 | `miyu update` | 换成最新版程序，**`miyu` 命令自己也会更新到最新**；端口、模式、令牌、邀请码、上限、聊天数据都保留。Tunnel 模式会问要不要顺便把 cloudflared 更新到最新官方版本 |
| 卸载 | `miyu uninstall` | 删除程序、服务、运行用户、设置文件、**全部聊天数据**、安装时脚本自己加的防火墙规则、`miyu` 命令；Tunnel 模式还会删 `miyu-cloudflared` 服务、令牌文件，以及**脚本自己装的** cloudflared（你原来就有的 cloudflared 不会删） |

- `miyu` 其实是 `/usr/local/bin/miyu` 这个几行的小文件，它去运行保存好的脚本 `/usr/local/lib/miyu-chat/install.sh`。`miyu update` 时会从 GitHub 下载最新脚本（连不上换 jsDelivr），检查第一行是 `#!/bin/sh`、没有语法错误后才整体替换。
- 如果你的机器上 `/usr/local/bin/miyu` 已经被别的软件占用了，脚本**不会覆盖它**，会改用 **`miyu-chat-ctl`** 这个名字（装完会提示），下文的 `miyu` 换成 `miyu-chat-ctl` 即可。
- 直接运行脚本文件也可以，效果一样：`sh install.sh config`、`sh install.sh update`、`sh install.sh status`、`sh install.sh uninstall`（要在脚本所在的目录里运行）。
- 再次运行一键命令（不加任何东西）也会显示上面的菜单。

### 老版本（v1.1.0）怎么装上 miyu 命令

v1.1.0 及更早装的机器还没有 `miyu`。用 root 运行一次上面的一键命令，并在**最末尾的 `miyu-install` 后面加一个空格和 `update`**（也就是 `... miyu-install update`）。它会更新程序、装好 `miyu` 命令，端口、模式、令牌、邀请码、上限和聊天数据都不动。装完以后就可以直接用 `miyu` 了。

完整命令如下（直接复制）：

```sh
sh -c 'command -v curl >/dev/null 2>&1 || { if command -v apk >/dev/null 2>&1; then apk add --no-cache curl ca-certificates; elif command -v apt-get >/dev/null 2>&1; then apt-get update && apt-get install -y curl ca-certificates; fi; }; ok=; for u in "https://raw.githubusercontent.com/imthnio/miyu-chat/main/install.sh?cb=$(date +%s)" "https://cdn.jsdelivr.net/gh/imthnio/miyu-chat@main/install.sh"; do curl -fSL --connect-timeout 20 --max-time 180 --retry 2 -o /tmp/miyu-install.sh "$u" 2>/dev/null; if [ -f /tmp/miyu-install.sh ] && head -c 9 /tmp/miyu-install.sh 2>/dev/null | grep -q "^#!/bin/sh"; then ok=1; break; fi; done; if [ -n "$ok" ]; then sh /tmp/miyu-install.sh "$@"; else echo "下载失败：连不上 GitHub 和镜像站，请检查服务器网络后重试。"; exit 1; fi' miyu-install update
```

（不加 `update` 直接运行一键命令也会装上 `miyu`，然后显示菜单，选 `5` 退出即可。）

### 日志和文件

查看日志：

- Debian / Ubuntu：`journalctl -u miyu-chat -n 50 --no-pager`（cloudflared：`journalctl -u miyu-cloudflared -n 50 --no-pager`）
- Alpine：`tail -n 50 /var/log/miyu-chat.log`（cloudflared：`tail -n 50 /var/log/miyu-cloudflared.log`）

装好后的文件：

| 文件 | 内容 | 权限 |
| --- | --- | --- |
| `/usr/local/bin/miyu` | `miyu` 管理命令（几行的小文件） | 0755，root |
| `/usr/local/lib/miyu-chat/install.sh` | 保存的安装脚本，`miyu` 实际运行的就是它 | 0755，root |
| `/etc/miyu-chat.conf` | 模式、端口、脚本加的防火墙规则（没有密码类内容） | 0644 |
| `/etc/miyu-chat/miyu.env` | 聊天网址、邀请码、上限（服务启动时交给程序，不会出现在命令行参数里） | 0600，只有 root 能读 |
| `/etc/miyu-chat/tunnel.token` | Tunnel 令牌（只有 Tunnel 模式有） | 0600，只有 root 和 `miyu-cf` 用户能读 |
| `/var/lib/miyu-chat/miyu.db` | 聊天数据（全是密文） | 目录 0700，只有 `miyu` 用户能进 |

### 防火墙会怎么处理

- **Tunnel 模式**：cloudflared 是主动往外连 Cloudflare，**不需要开任何入站端口**，脚本也不碰防火墙。从直连切到 Tunnel 时，会删掉以前为直连加的那条规则。
- 直连模式，有 **ufw** 或 **firewalld** 并且已开启：脚本只**添加放行你这个端口的一条规则**（本来就放行了就不重复加）。卸载时只删这一条，不会卸载防火墙，也不碰你原有的规则。
- **nftables / iptables** 默认拦截入站：脚本不会自动改你的规则，只打印一条放行命令让你自己复制执行。
- **NAT 小鸡 / 云服务器**：除了系统防火墙，还要去商家后台确认端口映射已建好、**安全组**已放行对应端口。

## 安全说明（大白话版）

**服务器看不到的：**

- 消息内容。加密用的是成熟的 NaCl（TweetNaCl）算法库，密钥只在你的浏览器里。
- 你的私钥。它从不离开浏览器。勾选“记住密钥”时要设置一个**本地密码**，私钥用它加密后才存进这个浏览器（PBKDF2 + AES-GCM），下次打开网页输入本地密码解锁即可。这个功能需要 HTTPS（用 `http://IP:端口` 打开时会自动禁用）；公共电脑别勾。

**服务器能看到的（所谓“元数据”）：**

- 谁和谁是好友、谁在什么时间给谁发了消息、每条消息大概多长；
- 你设置的昵称（昵称是明文的）、你什么时候在线。

**怎么保证服务器没有冒充你的好友：**

- 每个人的“加密公钥”都用他自己的 ID 签过名，你的浏览器会检查这个签名。检查不通过的好友名字旁边会显示 ⚠️，并且**禁止给他发消息**。
- 你的好友 ID 一定要通过别的可靠渠道（当面、电话、其他聊天软件）核对一遍，确认和对方真正的 ID 一致。

**登录方式：**

- 每次连接时服务器发一串新的随机数，浏览器用私钥签名，服务器验证签名就算登录成功。没有密码、没有 Cookie、没有令牌，旧的签名拿去重放也没用。
- 签名里带着你访问的网址（域名[:端口]）。别的网站就算把我们的随机数转给你签名，签出来的也是它自己的网址，拿到真正的服务器上验证不通过。建议设置 `MIYU_HOST`（见下面“服务器设置”）。
- 登录之后，发消息、双删、删好友等**每一条操作也都有签名**，并且带着只增不减的序号，别人没法伪造或重放你的操作。

**用 Cloudflare Tunnel 模式时：**

- 浏览器 → Cloudflare 是 HTTPS；Cloudflare → 你的机器走 cloudflared 建立的**加密隧道**；cloudflared → 聊天程序只在本机 `127.0.0.1` 里转，不经过网络。所以下面说的“明文那一段”不存在。
- 聊天程序只听 `127.0.0.1`，外面没法绕过 Cloudflare 直接连它。
- **Tunnel 令牌等于这条隧道的密码**：谁拿到它谁就能冒充你的机器。脚本输入时不显示，只存在 `/etc/miyu-chat/tunnel.token`（权限 0600，只有 root 和 cloudflared 的运行用户能读），cloudflared 用 `--token-file` 读它，所以不会出现在进程列表（`ps`）和日志里。千万别发给别人、别截图。

**直连模式 + Cloudflare 的“灵活（Flexible）”SSL 模式，一定要知道：**

- 浏览器 → Cloudflare 这一段是 HTTPS 加密的；**Cloudflare → 你的服务器这一段是明文 HTTP**。
- 因为消息本身是端到端加密的，所以就算这一段被人偷看，**看到的也只是密文，聊天内容依然安全**。
- 但是这一段上能看到上面说的元数据（谁和谁聊、什么时候聊、昵称等），理论上中间人还可能在你登录之后干扰连接（比如丢消息、断线）。不过他**伪造不了你的操作**（双删、清空、删好友等每条指令都有签名）。
- 有条件的话，更安全的做法是给源站也配上证书，用 Cloudflare 的“完全（严格）/ Full (strict)”模式。

**其他要知道的：**

- **私钥丢了就找不回来**：没有“找回密码”，服务器也帮不了你。请抄下来或存进密码管理器。
- **私钥泄露 = 身份和历史消息都泄露**：拿到私钥的人可以登录你的身份，也能解开服务器上还保存着的你的历史消息（没有“前向保密”）。重要的聊天记得及时双删。
- 双删是让服务器删掉密文，并通知双方页面清掉；但没法阻止对方提前截图或复制。

## 免交互安装（会写脚本的人用，可选）

先用一键命令或手动把脚本下载到 `/tmp/miyu-install.sh`，再这样运行：

```sh
MIYU_PORT=<内部端口> MIYU_EXT_PORT=<外部端口> sh /tmp/miyu-install.sh   # 直接指定端口，不再提问
MIYU_MODE=tunnel MIYU_TUNNEL_TOKEN_FILE=/root/token.txt sh /tmp/miyu-install.sh   # Tunnel 模式，令牌从文件读（用完记得删掉这个文件）
MIYU_MODE=direct sh /tmp/miyu-install.sh                             # 直连模式
MIYU_HOST=chat.example.com MIYU_INVITE_CODE=random MIYU_MAX_USERS=50 MIYU_MAX_DB_MB=2000 sh /tmp/miyu-install.sh
                                                  # 聊天网址、邀请码（random=随机生成，none=不要）、上限（0=不限制）
MIYU_BIN=/root/miyu-chat-linux-amd64 MIYU_SHA256=<校验值> sh /tmp/miyu-install.sh   # 用自己下载好的程序文件
MIYU_DOWNLOAD_BASE=http://<你的镜像>/v1.1.1 sh /tmp/miyu-install.sh      # 从自建镜像下载（目录里要有程序和 SHA256SUMS）
```

装好以后的管理命令同样支持这些变量：

```sh
MIYU_CF_UPDATE=0 miyu update                      # 更新时不更新 cloudflared
MIYU_YES=1 miyu uninstall                         # 卸载时不再二次确认
MIYU_SCRIPT_URL=http://<你的镜像>/install.sh miyu update   # 从自建镜像取最新的管理脚本
```

## 服务器设置（环境变量 / 命令行参数，都是可选的）

| 环境变量 | 命令行参数 | 默认值 | 作用 |
| --- | --- | --- | --- |
| `MIYU_LISTEN` | `-listen` | `:8080` | 监听地址 |
| `MIYU_DB` | `-db` | `miyu.db` | 数据库文件 |
| `MIYU_HOST` | `-host` | 空（以浏览器访问的网址为准） | 允许登录的网址（域名[:端口]），多个用逗号分隔，例如 `chat.example.com,<公网IP>:<外部端口>`。**建议设置成你的聊天域名** |
| `MIYU_INVITE_CODE` | `-invite` | 空（不需要邀请码） | 设置后，新身份第一次登录必须在登录页填对邀请码；已注册的身份不受影响。建议用环境变量，命令行参数别人用 `ps` 能看到 |
| `MIYU_MAX_USERS` | `-max-users` | `0`（不限制） | 最多允许多少个身份，满了不再接受新注册 |
| `MIYU_MAX_DB_MB` | `-max-db-mb` | `0`（不限制） | 数据库最多占多少 MB，满了不再收新消息和新注册（双删照常可用，删掉旧消息能腾出空间） |

另外，每个人最多同时有 50 个“等对方处理”的好友申请。

用一键脚本安装时不用手动设置：脚本会问你，并把 `MIYU_HOST`、`MIYU_INVITE_CODE`、`MIYU_MAX_USERS`、`MIYU_MAX_DB_MB` 写进 `/etc/miyu-chat/miyu.env`（权限 0600），服务启动时交给程序；更新时保留，改设置用 `miyu config`。上限只能是数字（写成别的程序会拒绝启动，脚本会帮你检查）。

关于 `MIYU_HOST` 留空：程序会以浏览器访问时带来的网址（Host）为准，也能正常登录。Tunnel 模式下外面只能经过 Cloudflare 进来，留空影响不大；**直连模式建议一定要设置**（脚本会自动带上 `<公网IP>:<外部端口>`），因为别人能绕过 Cloudflare 直接连你的端口、伪造这个网址。

手动运行时的例子：

```sh
MIYU_HOST=chat.example.com MIYU_INVITE_CODE=<你的邀请码> MIYU_MAX_USERS=50 MIYU_MAX_DB_MB=500 \
  ./miyu-chat -listen 127.0.0.1:<内部端口> -db ./miyu.db
```

## 常见问题 / 排错

### 安装和管理

**输入 `miyu` 提示“command not found / 找不到命令”？**
- 还没装上：v1.1.0 及更早装的机器没有这个命令，按“[老版本怎么装上 miyu 命令](#老版本v110怎么装上-miyu-命令)”运行一次一键命令（末尾加 `update`）。
- 装成了别的名字：安装时提示过“管理命令装成了：miyu-chat-ctl”的，就用 `miyu-chat-ctl`。
- 不是 root：先 `sudo -i` 切到 root 再运行。

**提示 `sh: can't open install.sh` / `No such file or directory`？**
以前的说明让你运行 `sh install.sh ...`，但一键命令把脚本放在 `/tmp/miyu-install.sh`，换了目录或重启后就找不到了。现在请直接用 `miyu ...`。

**网页打不开？**
先在服务器上运行 `miyu status` 看服务是否正常；正常的话，多半是端口映射、安全组或防火墙没放行。NAT 小鸡请确认用的是**外部端口**访问。

**想从直连换成 Tunnel（或反过来）？**
运行 `miyu config`，选另一种模式即可，聊天数据和端口不变。换到 Tunnel 会装好 cloudflared、删掉以前加的防火墙规则；换回直连会删掉 cloudflared 服务和令牌。

**怎么备份聊天数据？想换端口怎么办？**
数据都在 `/var/lib/miyu-chat/miyu.db` 一个文件里（里面全是密文）。备份：先停服务（`systemctl stop miyu-chat` 或 `rc-service miyu-chat stop`），把 `/var/lib/miyu-chat/` 整个目录复制出来，再启动服务。
换端口：备份 → `miyu uninstall` → 重新运行一键命令安装（填新端口）→ 停服务 → 把备份的 `miyu.db` 放回 `/var/lib/miyu-chat/` 并 `chown -R miyu:miyu /var/lib/miyu-chat` → 启动服务。

**国内机器连不上 GitHub？**
脚本会自动改用 jsDelivr 镜像下载，同样会核对 SHA256 校验值。

**能装在 CentOS / Arch 上吗？**
目前脚本只支持 Debian、Ubuntu、Alpine。其他系统可以从 Release 下载程序手动运行：`./miyu-chat-linux-amd64 -listen 0.0.0.0:<端口> -db ./miyu.db`。

### Cloudflare Tunnel 模式

**打开显示 Error 1033？**
Tunnel 没连上 Cloudflare。在服务器上运行 `miyu status`，看 cloudflared 是否在运行、是否提示“Tunnel 没连上”；多半是令牌没复制完整，运行 `miyu config` 重新粘贴。也可以看 cloudflared 日志找原因（见“日志和文件”），并确认服务器能访问外网的 `7844` 端口。

**打开显示 502 / Bad Gateway？**
Tunnel 已经连上了，但 Cloudflare 后台 Published application 的 **Service URL** 填错了：要是 `http://127.0.0.1:<端口>`，端口和安装时填的一样，是 `http` 不是 `https`。忘了端口就运行 `miyu status`，最后一行会显示。

**显示“此网站无法提供安全连接” / 证书错误？**
用了两级子域名（例如 `chat.abc.example.com`），Cloudflare 免费套餐的证书不包。换成一级的，例如 `chat.example.com`：在 Cloudflare 后台改 Published application 的子域名，再运行 `miyu config` 把聊天域名改成一样。

**保存 Published application 时提示 DNS 记录已存在？**
先去 Cloudflare 的 DNS 页面把旧的 `chat` 记录删掉，再回来保存。

### 登录和使用

**登录时提示“密钥校验失败”？**
- 先刷新网页（旧版网页的登录签名格式和新版服务器不兼容）。
- 还不行：浏览器地址栏的网址和服务器设置的“聊天域名”（`MIYU_HOST`）不一致。普通用户请用搭服务器的人给你的那个网址打开；搭服务器的人运行 `miyu config` 把聊天域名改成和地址栏一样（用 `http://IP:端口` 直接访问时，要把 `IP:端口` 也加进去）。

**提示“请刷新网页换到最新版”？**
服务器升级了，按一下浏览器刷新就好。

**提示需要邀请码 / 邀请码不对？**
服务器开启了邀请码，找管理员要，填进登录页的“邀请码（服务器要求时填写）”再登录；注意大小写和横杠。只有第一次登录需要。

**提示人数已满 / 存储已满？**
请管理员运行 `miyu config` 调大上限；存储满了时删掉（双删）一些旧聊天也能腾出空间。

**忘了“记住密钥”的本地密码？**
在解锁页点“换一个密钥登录”，用你抄下来的私钥重新登录即可（本地密码只用来在这个浏览器上解锁，服务器不知道它）。

**私钥忘了怎么办？**
找不回来，只能生成新的密钥当新身份，重新加好友。

### 直连模式

**接了 Cloudflare 后打不开 / 报 52x 错误？**
检查回源端口规则里的端口是不是 `<外部端口>`，SSL 模式是不是“灵活”。如果是“完全/严格”，Cloudflare 会用 HTTPS 连你的服务器，而程序只会 HTTP，就会失败。

**页面一直显示“已断开，正在重连”？**
WebSocket 没连上。确认 Cloudflare 的 WebSockets 开关是开的，中间如果还有别的反向代理，要放行 `/ws` 的 WebSocket 升级。

**“复制”按钮没反应？**
浏览器只允许 HTTPS 网页使用剪贴板。用 `http://IP:端口` 访问时请手动选中复制，或者接上 Cloudflare 用 HTTPS。

**好友名字旁边有 ⚠️？**
说明他的加密公钥签名校验失败，可能是服务器出了问题或被人篡改。为了安全，这时不能给他发消息。请和对方核对 ID。

## 从源码编译

```sh
CGO_ENABLED=0 go build -trimpath -ldflags "-s -w -X main.version=dev" -o miyu-chat .
./miyu-chat -listen 127.0.0.1:8080 -db ./miyu.db
```

发布新版本：推送 `v` 开头的标签（例如 `v1.0.1`），GitHub Actions 会自动编译 amd64/arm64、生成 `SHA256SUMS`、上传到 Release，并更新给 jsDelivr 用的 `dist` 分支。

## 赞赏支持
如果这个脚本帮到了你，欢迎请我喝杯咖啡 ☕  
微信扫一扫下方赞赏码即可：

![赞赏码](./appreciate.png)
