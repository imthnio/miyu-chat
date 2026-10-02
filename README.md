# 密语 miyu-chat —— 自己搭的端到端加密网页聊天

装在你自己的服务器上的“加密微信网页版”：打开网页就能和朋友聊天，消息在浏览器里加密，服务器只存看不懂的密文。

- 一个程序文件就能跑（Go 静态编译，网页已经打包在里面），内存占用十几 MB，256MB 的小鸡也够用。
- 没有账号密码：**你的私钥就是你的身份**，登录时浏览器用私钥签名证明“我是我”。
- 支持 Debian / Ubuntu（systemd）和 Alpine（OpenRC），独立服务器、VPS、NAT 小鸡都能装。

## 能做什么

- **加好友**：把自己的 ID（64 位十六进制）发给朋友，对方输入后发起申请，你点“通过”就成为好友。
- **加密聊天**：消息在浏览器里加密后才发出去，只有你和好友的浏览器能解开。
- **双删单条消息**：任意一方点消息旁边的“双删”，服务器彻底删除这条密文，双方页面同时消失。
- **双删整个会话**：点“双删全部记录”，你们之间的所有聊天记录在服务器和双方页面上一起清空。
- **删除好友**：同时双删全部聊天记录。
- **在线状态**：好友在线时头像上有绿点。

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

**关于 Cloudflare 的“灵活（Flexible）”SSL 模式，一定要知道：**

- 浏览器 → Cloudflare 这一段是 HTTPS 加密的；**Cloudflare → 你的服务器这一段是明文 HTTP**。
- 因为消息本身是端到端加密的，所以就算这一段被人偷看，**看到的也只是密文，聊天内容依然安全**。
- 但是这一段上能看到上面说的元数据（谁和谁聊、什么时候聊、昵称等），理论上中间人还可能在你登录之后干扰连接（比如丢消息、断线）。不过他**伪造不了你的操作**（双删、清空、删好友等每条指令都有签名）。
- 有条件的话，更安全的做法是给源站也配上证书，用 Cloudflare 的“完全（严格）/ Full (strict)”模式。

**其他要知道的：**

- **私钥丢了就找不回来**：没有“找回密码”，服务器也帮不了你。请抄下来或存进密码管理器。
- **私钥泄露 = 身份和历史消息都泄露**：拿到私钥的人可以登录你的身份，也能解开服务器上还保存着的你的历史消息（没有“前向保密”）。重要的聊天记得及时双删。
- 双删是让服务器删掉密文，并通知双方页面清掉；但没法阻止对方提前截图或复制。

## 一键安装 / 更新（SSH 粘贴就行）

1. SSH 连上你的服务器（用 root 用户）。
2. 粘贴下面这段，回车（缺 curl 会自动装；GitHub 连不上会自动换 jsDelivr 镜像）：
   ```sh
   sh -c 'command -v curl >/dev/null 2>&1 || { if command -v apk >/dev/null 2>&1; then apk add --no-cache curl ca-certificates; elif command -v apt-get >/dev/null 2>&1; then apt-get update && apt-get install -y curl ca-certificates; fi; }; ok=; for u in "https://raw.githubusercontent.com/imthnio/miyu-chat/main/install.sh?cb=$(date +%s)" "https://cdn.jsdelivr.net/gh/imthnio/miyu-chat@main/install.sh"; do curl -fSL --connect-timeout 20 --max-time 180 --retry 2 -o /tmp/miyu-install.sh "$u" 2>/dev/null; if [ -f /tmp/miyu-install.sh ] && head -c 9 /tmp/miyu-install.sh 2>/dev/null | grep -q "^#!/bin/sh"; then ok=1; break; fi; done; if [ -n "$ok" ]; then sh /tmp/miyu-install.sh "$@"; else echo "下载失败：连不上 GitHub 和镜像站，请检查服务器网络后重试。"; exit 1; fi' miyu-install
   ```
3. 脚本会自动识别你的系统（Debian/Ubuntu 还是 Alpine）和机器类型（独立服务器、VPS 还是 NAT 小鸡），然后问你：
   - **端口**：没有默认值，必须自己输一个数字。被占用会提示你换一个，最多问 3 次。NAT 小鸡填商家分给你的**内部端口**。
   - **外部端口**（只有 NAT 小鸡会问）：商家后台里这个内部端口对应的外部端口，一样就直接回车。
4. 程序会从 GitHub Release 下载（失败自动换 jsDelivr），**先核对 SHA256 校验值再安装**，然后注册成系统服务（开机自启、崩溃自动重启）。
5. 装完会显示 `http://<公网IP>:<外部端口>`，浏览器能打开就说明装好了。建议再按下面的步骤接上 Cloudflare，用 HTTPS 域名给朋友用。

> 想换端口：先备份数据（见下面“常见问题”），卸载后重新安装。

## 管理命令（状态 / 更新 / 卸载）

把上面一键命令最后的 `miyu-install` 后面加上动作即可，例如：

| 想做什么 | 在一键命令末尾加 | 说明 |
| --- | --- | --- |
| 查看状态 | `miyu-install status` | 显示端口、服务状态，并实际访问一次确认能用 |
| 更新程序 | `miyu-install update` | 只换程序，端口、配置、聊天数据都保留 |
| 卸载 | `miyu-install uninstall` | 删除程序、服务、运行用户、**全部聊天数据**，以及安装时脚本自己加的防火墙规则 |

如果刚装完、`/tmp/miyu-install.sh` 还在，也可以直接运行：

```sh
sh /tmp/miyu-install.sh status
sh /tmp/miyu-install.sh update
sh /tmp/miyu-install.sh uninstall
```

查看日志：

- Debian / Ubuntu：`journalctl -u miyu-chat -n 50 --no-pager`
- Alpine：`tail -n 50 /var/log/miyu-chat.log`

### 防火墙会怎么处理

- 有 **ufw** 或 **firewalld** 并且已开启：脚本只**添加放行你这个端口的一条规则**（本来就放行了就不重复加）。卸载时只删这一条，不会卸载防火墙，也不碰你原有的规则。
- **nftables / iptables** 默认拦截入站：脚本不会自动改你的规则，只打印一条放行命令让你自己复制执行。
- **NAT 小鸡 / 云服务器**：除了系统防火墙，还要去商家后台确认端口映射已建好、**安全组**已放行对应端口。

## 接 Cloudflare（以 NAT 小鸡为例）

下面用这些占位符，换成你自己的：

| 占位符 | 意思 | 在哪看 |
| --- | --- | --- |
| `chat.example.com` | 你想用的聊天域名 | 你自己的域名（已托管在 Cloudflare） |
| `<公网IP>` | NAT 小鸡的公网 IP | 商家后台，或安装结束时脚本显示的 IP |
| `<内部端口>` | 安装时填的端口，程序在机器里监听它 | 安装时你自己填的 |
| `<外部端口>` | 商家映射到内部端口的公网端口 | 商家后台“端口映射/端口转发” |

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
7. 打开 `https://chat.example.com`，生成密钥、登录，把你的 ID 发给朋友即可。

> 独立服务器 / 普通 VPS：步骤一样。如果安装时直接用了 Cloudflare 支持的 HTTP 端口（80、8080、8880、2052、2082、2086、2095），可以不用第 4 步的回源端口规则。

## 免交互安装（会写脚本的人用，可选）

```sh
MIYU_PORT=<内部端口> MIYU_EXT_PORT=<外部端口> sh /tmp/miyu-install.sh   # 直接指定端口，不再提问
MIYU_YES=1 sh /tmp/miyu-install.sh uninstall                         # 卸载时不再二次确认
MIYU_BIN=/root/miyu-chat-linux-amd64 MIYU_SHA256=<校验值> sh /tmp/miyu-install.sh   # 用自己下载好的程序文件
MIYU_DOWNLOAD_BASE=http://<你的镜像>/v1.0.0 sh /tmp/miyu-install.sh      # 从自建镜像下载（目录里要有程序和 SHA256SUMS）
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

手动运行时的例子：

```sh
MIYU_HOST=chat.example.com MIYU_INVITE_CODE=<你的邀请码> MIYU_MAX_USERS=50 MIYU_MAX_DB_MB=500 \
  ./miyu-chat -listen 127.0.0.1:<内部端口> -db ./miyu.db
```

## 常见问题

**登录时提示“密钥校验失败”？**
先刷新网页（旧版网页的登录签名格式和新版服务器不兼容）。还不行的话，检查服务器的 `MIYU_HOST` 是否包含你浏览器地址栏里的网址（用 `http://IP:端口` 直接访问时，要把 `IP:端口` 也加进去）。

**提示需要邀请码？**
服务器开启了邀请码，找管理员要邀请码，填进登录页的“邀请码（服务器要求时填写）”再登录。只有第一次登录需要。

**忘了“记住密钥”的本地密码？**
在解锁页点“换一个密钥登录”，用你抄下来的私钥重新登录即可（本地密码只用来在这个浏览器上解锁，服务器不知道它）。

**网页打不开？**
先在服务器上运行 `miyu-install status`（见“管理命令”）看服务是否正常；正常的话，多半是端口映射、安全组或防火墙没放行。NAT 小鸡请确认用的是**外部端口**访问。

**接了 Cloudflare 后打不开 / 报 52x 错误？**
检查回源端口规则里的端口是不是 `<外部端口>`，SSL 模式是不是“灵活”。如果是“完全/严格”，Cloudflare 会用 HTTPS 连你的服务器，而程序只会 HTTP，就会失败。

**页面一直显示“已断开，正在重连”？**
WebSocket 没连上。确认 Cloudflare 的 WebSockets 开关是开的，中间如果还有别的反向代理，要放行 `/ws` 的 WebSocket 升级。

**“复制”按钮没反应？**
浏览器只允许 HTTPS 网页使用剪贴板。用 `http://IP:端口` 访问时请手动选中复制，或者接上 Cloudflare 用 HTTPS。

**好友名字旁边有 ⚠️？**
说明他的加密公钥签名校验失败，可能是服务器出了问题或被人篡改。为了安全，这时不能给他发消息。请和对方核对 ID。

**私钥忘了怎么办？**
找不回来，只能生成新的密钥当新身份，重新加好友。

**怎么备份聊天数据？想换端口怎么办？**
数据都在 `/var/lib/miyu-chat/miyu.db` 一个文件里（里面全是密文）。备份：先停服务（`systemctl stop miyu-chat` 或 `rc-service miyu-chat stop`），把 `/var/lib/miyu-chat/` 整个目录复制出来，再启动服务。
换端口：备份 → 卸载 → 重新安装（填新端口）→ 停服务 → 把备份的 `miyu.db` 放回 `/var/lib/miyu-chat/` 并 `chown -R miyu:miyu /var/lib/miyu-chat` → 启动服务。

**国内机器连不上 GitHub？**
脚本会自动改用 jsDelivr 镜像下载，同样会核对 SHA256 校验值。

**能装在 CentOS / Arch 上吗？**
目前脚本只支持 Debian、Ubuntu、Alpine。其他系统可以从 Release 下载程序手动运行：`./miyu-chat-linux-amd64 -listen 0.0.0.0:<端口> -db ./miyu.db`。

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
