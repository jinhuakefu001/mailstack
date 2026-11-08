# DNS 配置

四条记录配好，邮件才能正常收发并且不被判垃圾。假设：

```
邮件域名    example.com
邮件服务器  mail.example.com  (A → 1.2.3.4)
DKIM 选择器 mail
```

---

## 1. MX — 收信指向

```
example.com.    MX    10  mail.example.com.
mail.example.com.  A      1.2.3.4
```

**必须同时有精确的 `mail` A 记录**。如果只靠 `*.example.com` 通配符，某些解析器会同时返回通配符指向的 IP，导致一半投递失败。

`MX` 优先级数字只在有多个 MX 时有意义；单 MX 用 `10` 或 `1` 都行。

**不要**同时保留旧服务商的 MX（比如 iCloud 的 `mx01.mail.icloud.com`）。多个 MX 会导致邮件被分流到你不控制的地方。

---

## 2. SPF — 授权发信 IP

```
example.com.    TXT    "v=spf1 ip4:1.2.3.4 include:_spf.example-provider.com -all"
```

- `ip4:1.2.3.4` —— 你自己的服务器
- `include:` —— 如果你用中继服务，把它的 SPF 包含进来
- `~all` = 软失败（标记但不拒收），`-all` = 硬失败

**SPF 记录必须只有一条。** 两条 SPF（比如 `v=spf1 ...` 和另一个 `v=spf1 ...`）会互相抵消，等同于没有。

DNS TXT 单条上限 255 字符，超了要拆成多段字符串，解析器会自动拼接。

---

## 3. DKIM — 签名验证

安装脚本会生成密钥并打印公钥。查看：

```bash
cat /etc/opendkim/keys/example.com/mail.txt
```

输出类似：

```
mail._domainkey	IN	TXT	( "v=DKIM1; k=rsa; "
	  "p=MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA..." )
```

把 `p=` 后面的整串拿出来，配上：

```
mail._domainkey.example.com.    TXT    "v=DKIM1; k=rsa; p=MIIBIjANBgkq..."
```

注意事项：

- **一条 TXT 就是完整的一行**，把 `mail.txt` 里被引号拆开的几段直接拼起来，中间不要加空格。
- 选择器名（`mail`）必须和 `/etc/opendkim.conf` 里的 `Selector` 一致。
- 2048 位密钥的 `p=` 约 400 字符，超过 255，某些 DNS 面板会报错。可以用 1024 位（安全性够用），或者用支持长 TXT 的面板。
- 改完 DKIM 记录后，**旧的签名缓存可能还在**，等 10 分钟再测。

验证签名是否生效：

```bash
# 本地自测：发一封信到 gmail，查看原文里的 DKIM-Signature
swaks --to you@gmail.com --server 127.0.0.1 --body "dkim test"

# 用在线工具检查
# https://www.mail-tester.com/      综合评分
# https://dmarcian.com/dkim-inspector/  DKIM 解析
```

---

## 4. DMARC — 告诉对方如何处理失败

```
_dmarc.example.com.    TXT    "v=DMARC1; p=none; rua=mailto:postmaster@example.com; adkim=s; aspf=s; pct=100"
```

| 参数 | 含义 |
|---|---|
| `p=none` | 只监控，不处置（**起步必须用这个**） |
| `p=quarantine` | 失败进垃圾箱 |
| `p=reject` | 失败直接拒收 |
| `rua=` | 聚合报告收件地址 |

**不要一上来就 `p=reject`。** 如果漏配了某个发信源（备用服务器、第三方服务、旧 IP），那批邮件会全部消失且没有任何提示。

正确做法：

1. `p=none` 跑两周
2. 看 `rua` 收到的 XML 报告，确认所有发信源都通过了 SPF/DKIM
3. 加到 `p=quarantine`，再观察一周
4. 最后 `p=reject`

报告是 XML 压缩包，人眼难读。用 [dmarcian](https://dmarcian.com/) 或 `parsedmarc` 解析。

---

## 5. PTR / 反向解析（可选但影响大）

PTR 记录是「IP → 域名」，很多收件方会检查它是否和 HELO 名一致。

**多数云厂商中国站不提供 PTR 设置**（腾讯云中国站明确不售卖）。没有 PTR 时会损失部分到达率，尤其是发给 Gmail / Outlook 的邮件。

缓解手段：

- 通过中继服务发信（中继方的 IP 有正确 PTR）
- 申请解封 25 端口时通常要求填 PTR，但中国站走不通这条路
- 保持低投诉率，用内容质量弥补

如果你的服务商支持设置 PTR，务必设成 `mail.example.com`，和 `myhostname` 一致。

---

## 6. 完整记录清单

```dns
example.com.              MX     10  mail.example.com.
mail.example.com.         A          1.2.3.4
example.com.              TXT        "v=spf1 ip4:1.2.3.4 ~all"
mail._domainkey.example.com.  TXT    "v=DKIM1; k=rsa; p=MIIBIjAN..."
_dmarc.example.com.       TXT        "v=DMARC1; p=none; rua=mailto:postmaster@example.com"
```

---

## 7. 验证

```bash
# MX
dig +short MX example.com

# SPF
dig +short TXT example.com | grep spf1

# DKIM（把选择器换成你的）
dig +short TXT mail._domainkey.example.com

# DMARC
dig +short TXT _dmarc.example.com

# PTR
dig +short -x 1.2.3.4

# 端到端：从外部主机发信进来
swaks --to alice@example.com --server mail.example.com

# 检查邮件落地
tail -f /var/log/maillog
ls /var/vmail/example.com/alice/Maildir/new/
```

---

## 常见失败

| 现象 | 原因 |
|---|---|
| 外部发信进来超时 | 云安全组没放行入站 25，或 `DROP ALL` 规则排在 `ACCEPT 25` 前面 |
| 能收不能发，队列堆积 | 出站 25 被封，需要配 `relayhost` 走中继 |
| 发出去进垃圾箱 | DKIM 签名失败、SPF 不匹配、或缺 PTR |
| `dig` 能看到记录但服务不认 | DNS 缓存未过期，或记录类型写成了 CNAME（TXT 不能走 CNAME） |
| DKIM 验证失败 | 公钥拼接时多了空格或换行；选择器名不匹配 |
