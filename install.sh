#!/usr/bin/env bash
#
# mailstack — 一键部署 Postfix + Dovecot + OpenDKIM 邮件系统
#
#   sudo ./install.sh mail.example.com example.com
#
# 幂等：可重复执行，已存在的配置会被覆盖，账号和邮件不会被删除。
#
set -euo pipefail

MAILHOST="${1:-}"
MAILDOMAIN="${2:-}"

if [[ -z "$MAILHOST" || -z "$MAILDOMAIN" ]]; then
  echo "用法: sudo $0 <mail主机名> <邮件域名>" >&2
  echo "示例: sudo $0 mail.example.com example.com" >&2
  exit 2
fi

if [[ $EUID -ne 0 ]]; then
  echo "需要 root 权限" >&2
  exit 1
fi

VMAIL_UID=5000
VMAIL_GID=5000
VMAIL_BASE=/var/vmail
DKIM_SELECTOR=mail

log() { printf '\033[36m[mailstack]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[warn]\033[0m %s\n' "$*"; }

# ---------------------------------------------------------------------------
# 1. 软件包
# ---------------------------------------------------------------------------
log "安装软件包"
if command -v dnf >/dev/null 2>&1; then
  PKG=dnf
elif command -v yum >/dev/null 2>&1; then
  PKG=yum
elif command -v apt-get >/dev/null 2>&1; then
  PKG=apt
else
  echo "无法识别包管理器" >&2; exit 1
fi

case "$PKG" in
  dnf|yum)
    $PKG install -y postfix dovecot dovecot-pigeonhole opendkim opendkim-tools \
                   openssl swaks 2>/dev/null || \
    $PKG install -y postfix dovecot opendkim opendkim-tools openssl swaks
    ;;
  apt)
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y postfix dovecot-core dovecot-imapd dovecot-pop3d \
                       dovecot-lmtpd opendkim opendkim-tools openssl swaks
    ;;
esac

# ---------------------------------------------------------------------------
# 2. 虚拟用户
# ---------------------------------------------------------------------------
log "创建虚拟邮件用户 vmail (${VMAIL_UID}:${VMAIL_GID})"
getent group vmail >/dev/null || groupadd -g "$VMAIL_GID" vmail
id -u vmail >/dev/null 2>&1 || useradd -u "$VMAIL_UID" -g vmail -d "$VMAIL_BASE" -s /sbin/nologin vmail
mkdir -p "$VMAIL_BASE/$MAILDOMAIN"
chown -R "$VMAIL_UID:$VMAIL_GID" "$VMAIL_BASE"
chmod 770 "$VMAIL_BASE"

# ---------------------------------------------------------------------------
# 3. Dovecot
# ---------------------------------------------------------------------------
log "配置 Dovecot"
install -d /etc/dovecot/ssl

cat > /etc/dovecot/dovecot.conf <<EOF
protocols = imap pop3 lmtp
listen = *, ::
!include conf.d/*.conf
!include auth-passwdfile.conf.ext

log_path = /var/log/dovecot.log
info_log_path = /var/log/dovecot-info.log
debug_log_path = /var/log/dovecot-debug.log

ssl = required
ssl_cert = </etc/dovecot/ssl/mail.pem
ssl_key  = </etc/dovecot/ssl/mail.key

mail_location = maildir:~/Maildir
mail_uid = $VMAIL_UID
mail_gid = $VMAIL_GID
first_valid_uid = $VMAIL_UID

namespace inbox {
  inbox = yes
  # 注意：必须多行展开，Dovecot 不支持单行 mailbox X { ... }
  mailbox Drafts {
    special_use = \Drafts
    auto = subscribe
  }
  mailbox Sent {
    special_use = \Sent
    auto = subscribe
  }
  mailbox Trash {
    special_use = \Trash
    auto = subscribe
  }
  mailbox Junk {
    special_use = \Junk
    auto = create
  }
}

service lmtp {
  unix_listener /var/spool/postfix/private/dovecot-lmtp {
    mode = 0600
    user = postfix
    group = postfix
  }
}

service auth {
  unix_listener /var/spool/postfix/private/auth {
    mode = 0660
    user = postfix
    group = postfix
  }
  unix_listener auth-userdb {
    mode = 0600
    user = vmail
  }
}

passdb {
  driver = passwd-file
  args = scheme=SHA512-CRYPT username_format=%u /etc/dovecot/users
}

userdb {
  driver = passwd-file
  args = username_format=%u /etc/dovecot/users
  default_fields = uid=$VMAIL_UID gid=$VMAIL_GID home=$VMAIL_BASE/%d/%n
}

protocol lmtp {
  postmaster_address = postmaster@$MAILDOMAIN
}
EOF

cat > /etc/dovecot/users <<'EOF'
# 格式: user@domain:HASH:uid:gid::home::
# 添加账号请用 ./add-user.sh，不要手改这里
EOF
chmod 640 /etc/dovecot/users
chown root:dovecot /etc/dovecot/users 2>/dev/null || chown root:root /etc/dovecot/users

# ---------------------------------------------------------------------------
# 4. Postfix
# ---------------------------------------------------------------------------
log "配置 Postfix"
postconf -e "myhostname = $MAILHOST"
postconf -e "mydomain = $MAILDOMAIN"
postconf -e "myorigin = \$mydomain"
postconf -e "inet_interfaces = all"
postconf -e "inet_protocols = ipv4"
postconf -e "mydestination = localhost.\$mydomain, localhost"
postconf -e "mynetworks = 127.0.0.0/8"

# 虚拟域
postconf -e "virtual_mailbox_domains = $MAILDOMAIN"
postconf -e "virtual_mailbox_base = $VMAIL_BASE"
postconf -e "virtual_mailbox_maps = hash:/etc/postfix/vmailbox"
postconf -e "virtual_transport = lmtp:unix:private/dovecot-lmtp"
postconf -e "virtual_uid_maps = static:$VMAIL_UID"
postconf -e "virtual_gid_maps = static:$VMAIL_GID"

# SASL（发信认证交给 Dovecot）
postconf -e "smtpd_sasl_type = dovecot"
postconf -e "smtpd_sasl_path = private/auth"
postconf -e "smtpd_sasl_auth_enable = yes"
postconf -e "smtpd_sasl_security_options = noanonymous"
postconf -e "smtpd_tls_auth_only = yes"

# TLS
postconf -e "smtpd_tls_cert_file = /etc/dovecot/ssl/mail.pem"
postconf -e "smtpd_tls_key_file = /etc/dovecot/ssl/mail.key"
postconf -e "smtpd_tls_security_level = may"
postconf -e "smtp_tls_security_level = may"

# DKIM
postconf -e "milter_protocol = 6"
postconf -e "milter_default_action = accept"
postconf -e "smtpd_milters = inet:127.0.0.1:8891"
postconf -e "non_smtpd_milters = inet:127.0.0.1:8891"

# 提交端口
if ! grep -q '^submission' /etc/postfix/master.cf; then
  cat >> /etc/postfix/master.cf <<'EOF'

submission inet n       -       n       -       -       smtpd
  -o syslog_name=postfix/submission
  -o smtpd_tls_security_level=encrypt
  -o smtpd_sasl_auth_enable=yes
  -o smtpd_client_restrictions=permit_sasl_authenticated,reject
EOF
fi

if ! grep -q '^smtps' /etc/postfix/master.cf; then
  cat >> /etc/postfix/master.cf <<'EOF'

smtps     inet  n       -       n       -       -       smtpd
  -o syslog_name=postfix/smtps
  -o smtpd_tls_wrappermode=yes
  -o smtpd_sasl_auth_enable=yes
  -o smtpd_client_restrictions=permit_sasl_authenticated,reject
EOF
fi

touch /etc/postfix/vmailbox
postmap /etc/postfix/vmailbox

# ---------------------------------------------------------------------------
# 5. OpenDKIM
# ---------------------------------------------------------------------------
log "配置 OpenDKIM (selector=$DKIM_SELECTOR)"
install -d /etc/opendkim/keys/$MAILDOMAIN
chown -R opendkim:opendkim /etc/opendkim 2>/dev/null || true

if [[ ! -f /etc/opendkim/keys/$MAILDOMAIN/$DKIM_SELECTOR.private ]]; then
  ( cd /etc/opendkim/keys/$MAILDOMAIN && \
    opendkim-genkey -b 2048 -d "$MAILDOMAIN" -s "$DKIM_SELECTOR" && \
    chown opendkim:opendkim "$DKIM_SELECTOR".private && chmod 600 "$DKIM_SELECTOR".private )
  log "DKIM 私钥已生成"
else
  log "DKIM 私钥已存在，跳过"
fi

cat > /etc/opendkim.conf <<EOF
Syslog                  yes
SyslogSuccess           yes
LogWhy                  yes
UMask                   002
Domain                  $MAILDOMAIN
Selector                $DKIM_SELECTOR
KeyFile                 /etc/opendkim/keys/$MAILDOMAIN/$DKIM_SELECTOR.private
Socket                  inet:8891@127.0.0.1
PidFile                 /run/opendkim/opendkim.pid
Canonicalization        relaxed/simple
Mode                    sv
SubDomains              no
OversignHeaders         From
UserID                  opendkim
EOF

# ---------------------------------------------------------------------------
# 6. 启动
# ---------------------------------------------------------------------------
log "启动服务"
systemctl enable --now opendkim dovecot postfix 2>/dev/null || true
systemctl restart opendkim dovecot postfix

# ---------------------------------------------------------------------------
# 7. 收尾
# ---------------------------------------------------------------------------
if [[ ! -f /etc/dovecot/ssl/mail.pem ]]; then
  warn "证书缺失，已生成自签名证书占位"
  warn "请用 acme.sh --issue --dns dns_<provider> -d $MAILHOST 申请正式证书，"
  warn "再把 fullchain.cer / key 复制到 /etc/dovecot/ssl/mail.pem 和 mail.key"
  openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout /etc/dovecot/ssl/mail.key -out /etc/dovecot/ssl/mail.pem \
    -subj "/CN=$MAILHOST" 2>/dev/null
  systemctl restart dovecot postfix
fi

echo
log "部署完成"
echo
echo "下一步："
echo "  1. 添加账号：  ./add-user.sh alice@$MAILDOMAIN 'StrongPass123'"
echo "  2. DNS 记录：  cat DKIM 公钥并配置 SPF / DKIM / DMARC"
cat /etc/opendkim/keys/$MAILDOMAIN/$DKIM_SELECTOR.txt 2>/dev/null | sed 's/^/     /'
echo
echo "  3. 自测：      swaks --to alice@$MAILDOMAIN --server 127.0.0.1"
echo
echo "⚠  检查云安全组是否放行入站 25（收信必须），且 DROP ALL 规则在列表最后"
