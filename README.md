# mailstack

**一套能收到信的邮件系统：Postfix + Dovecot + OpenDKIM + 事务邮件中继 + 打开/点击追踪。**

从零搭到「外部主机发信进来能落地、自己发出去能进收件箱」，附带每个环节踩过的坑。

```
收信   外部 MTA ──25──▶ Postfix ──LMTP──▶ Dovecot ──▶ Maildir
                                                  │
                                            IMAP 993 / POP3S 995

发信   客户端 ──465/587──▶ Postfix(AUTH) ──▶ [中继:465] ──▶ 收件方
                                              ↑ 出站 25 被云厂商封时走这里
```

---

## 为什么自己做

用第三方 SMTP 服务发信很容易，难的是**收信**和**信誉**：

- 事务邮件服务（SES / SendGrid / Mailgun）只负责「发」，不负责「收」。你需要一个真实邮箱来接收退信、投诉、回复。
- `no-reply@` 发出去的邮件被退信时，退信会回到你的域。没有 MX 就没有退信数据，你根本不知道 5% 的地址是死的。
- 想给邮件加打开追踪，就得自己控制投递链路和 HTML 模板。

这套东西搭完，你有一个**能收能发、有 DKIM 签名、带追踪**的完整链路，成本只有一台 VPS。

---

## 需要什么

| 项 | 要求 |
|---|---|
| 服务器 | 1 核 1G 起，公网 IP，最好能设 PTR（多数云厂商中国站不支持，见下文） |
| 系统 | 任意 systemd 发行版（本文以 TencentOS / CentOS 系验证，Debian 系差异在包名） |
| 域名 | 能改 DNS 解析 |
| 端口 | **入站 25**（收信必须）、465/587/993/995 |

### 两个「25 端口被封」不是一回事

这是最容易误判的地方，我在这上面浪费了两天：

| 方向 | 现象 | 真实原因 | 解法 |
|---|---|---|---|
| **入站 25** | 外部 ping 不通、telnet 超时 | **安全组没放行**，不是平台封禁 | 云控制台安全组加规则，**且要把 `DROP ALL` 移到规则列表最后**（顺序匹配） |
| **出站 25** | 邮件卡队列，日志 `connect to gmail-smtp-in...:25: Connection timed out` | 云厂商封禁，防垃圾邮件 | 走中继（SES / SendGrid 的 465 提交端口） |

**入站 25 必须保留** —— 全世界所有 MTA 投递你的域名时只连 MX 记录的 25 端口，没有替代协议。

安全组顺序错误是最隐蔽的坑：很多云平台的默认规则最后有一条 `DROP ALL`，如果你把 `ACCEPT tcp 25` 追加到它后面，永远不生效。必须用「修改整组规则」接口传完整有序列表。

---

## 部署

```bash
git clone <this-repo> mailstack
cd mailstack
sudo ./install.sh mail.example.com example.com
```

脚本是幂等的，可以重复跑。完成后：

```bash
# 1. 建账号
sudo ./add-user.sh alice@example.com 'YourStrongPass'

# 2. 配置 DNS（见 docs/DNS.md）

# 3. 自测
swaks --to alice@example.com --server 127.0.0.1
```

### 手工部署要点

如果不想跑脚本，`conf/` 下有完整配置片段。关键的四条：

```conf
# Postfix — 虚拟域 + 投递给 Dovecot
virtual_mailbox_domains = example.com
virtual_mailbox_base    = /var/vmail
virtual_transport       = lmtp:unix:private/dovecot-lmtp

# Postfix — 出站 25 被封时走中继
relayhost = [smtp.example-provider.com]:465
smtp_sasl_auth_enable = yes
smtp_sasl_password_maps = hash:/etc/postfix/sasl_passwd
smtp_tls_wrappermode = yes
smtp_tls_security_level = encrypt

# Postfix — DKIM 签名
milter_protocol = 6
smtpd_milters = inet:127.0.0.1:8891
non_smtpd_milters = inet:127.0.0.1:8891

# Dovecot — SASL 交给 Postfix 认证
smtpd_sasl_type = dovecot
smtpd_sasl_path = private/auth
```

---

## 踩过的坑

按踩到时候的疼的程度排：

### 1. Dovecot 不支持单行 `mailbox {}` 块

```conf
# ❌ 报错 "Garbage after '{'"
mailbox INBOX { auto = create }

# ✅ 必须展开成多行
mailbox INBOX {
  auto = create
}
```

### 2. `doveadm pw` 在 Dovecot 没启动时不可用

第一次建密码哈希时 Dovecot 还没跑，会失败。直接用：

```bash
openssl passwd -6 'YourPassword'     # SHA512-CRYPT
```

写进 `/etc/dovecot/users`：
```
alice@example.com:{SHA512-CRYPT}$6$...:5000:5000::/var/vmail/example.com/alice::
```

### 3. acme.sh 装不上（GitHub 被墙）

```bash
# ❌ curl https://get.acme.sh | sh  超时
# ✅ 走镜像
git clone https://gitee.com/neilpang/acme.sh.git
cd acme.sh && ./acme.sh --install
```

### 4. HTTP-01 验证失败 → 改用 DNS-01

如果邮件域名没有独立的 nginx vhost，HTTP-01 请求会落到 default_server，验证必然失败。用 DNS-01 彻底绕开 Web 服务器：

```bash
acme.sh --issue --dns dns_tencent -d mail.example.com
```

### 5. 通配符 A 记录导致 MX 解析出两个 IP

如果 DNS 里同时有 `*  A  1.2.3.4` 和 `mail  A  5.6.7.8`，某些解析器会返回两个地址，邮件一半投递失败。加精确的 `mail` 记录，精确匹配优先于通配符。

### 6. 中文显示名导致退信

```log
SMTPUTF8 is required, but was not offered by host
```

Postfix → 中继这条链路不支持裸 UTF-8 邮件头。显示名必须 MIME 编码：

```bash
FROM_NAME=$(printf '云泽信达邮局' | base64 -w0)
# From: =?UTF-8?B?${FROM_NAME}?= <postmaster@example.com>
```

纯 ASCII 显示名没这个问题。

### 7. 中继服务的域名配额限制

某些服务按地域限制每账号可添加的域名数量，报 `ExceedDomainLimit`。换一个地域通常就好了（同一账号不同地域配额独立）。

### 8. 中继验证长时间停在 pending

DNS 生效后 `VerifiedForSendingStatus` 不会自己刷新。手动调一次 `UpdateEmailIdentity`（或控制台点「重新验证」）触发检查。

另外实测：中继服务文档要求的 MX 记录**不必真的改**，只要 DKIM 的 TXT 记录正确就能通过验证。改了 MX 反而会破坏你自己的收信。

### 9. `opendkim-genkey` 找不到

```bash
yum install -y opendkim-tools      # 不是 opendkim
```

---

## 打开与点击追踪

`tracking/` 是一个单文件 PHP 示例，实现三件事：

| 事件 | 实现 | 记录 |
|---|---|---|
| 发送 | 写入 `msg` 表，生成唯一 `mid` | 收件人、主题、发送时间 |
| 打开 | `<img src="/t/o.php?m={mid}">` 1×1 透明图 | 时间、IP、UA |
| 点击 | 链接重写为 `/t/c.php?m={mid}&u={base64(url)}` | 时间、IP、UA、目标地址 |

```sql
CREATE TABLE msg (
  mid       CHAR(32) PRIMARY KEY,
  email     TEXT NOT NULL,
  subject   TEXT,
  sent_at   INTEGER,
  opened_at INTEGER,
  clicked_at INTEGER
);
CREATE TABLE evt (
  id     INTEGER PRIMARY KEY AUTOINCREMENT,
  mid    CHAR(32),
  kind   TEXT,     -- open / click
  ts     INTEGER,
  ip     TEXT,
  ua     TEXT,
  target TEXT
);
```

### 追踪数据怎么读才不会被骗

**打开率会被严重高估**，因为：

- Gmail / Apple Mail 的**图片代理**会预加载追踪像素，用户没看也算打开
- 企业邮件网关（Mimecast、Barracuda）会扫描所有链接和图片
- 安全沙箱（Defender for Office 365）会点开每个链接

判断方法：

```sql
-- 发送后 15 秒内发生的打开/点击，几乎都是网关扫描，不是真人
SELECT * FROM evt WHERE (ts - (SELECT sent_at FROM msg WHERE msg.mid = evt.mid)) < 15;
```

真正可信的指标是**点击后是否到达落地页并产生动作**（注册、提交表单），而不是打开率。

---

## DMARC 建议

起步用监控模式，先收集数据再收紧：

```
_dmarc.example.com  TXT  "v=DMARC1; p=none; rua=mailto:postmaster@example.com; adkim=s; aspf=s"
```

跑两周，看 `rua` 报表里有没有自己的合法发信源被判失败。确认干净后再改 `p=quarantine`，最后 `p=reject`。

**不要一上来就 `p=reject`** —— 如果漏了某个发信源（比如某台服务器还在用旧 IP 发信），那批邮件会全部进垃圾箱。

---

## 目录

```
mailstack/
├── install.sh              # 幂等部署脚本
├── add-user.sh             # 添加邮箱账号
├── conf/
│   ├── postfix-main.append.cf
│   ├── dovecot.conf
│   ├── opendkim.conf
│   └── auth-passwdfile.conf.ext
├── tracking/
│   ├── track.php           # HTTP 入口：像素 + 点击重定向 + 统计接口
│   ├── track-lib.php       # 共用函数（db / 事件记录 / 跳转白名单）
│   └── send-example.php    # 发信侧：生成 mid、重写链接、插入像素
└── docs/
    ├── DNS.md              # SPF / DKIM / DMARC / MX 配置
    └── TROUBLESHOOTING.md  # 排错速查
```

---

## License

MIT
