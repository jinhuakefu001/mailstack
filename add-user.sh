#!/usr/bin/env bash
#
# 添加邮箱账号
#   sudo ./add-user.sh alice@example.com 'StrongPass123'
#
set -euo pipefail

ADDR="${1:-}"
PASS="${2:-}"

if [[ -z "$ADDR" || -z "$PASS" ]]; then
  echo "用法: sudo $0 <user@domain> <密码>" >&2
  exit 2
fi

if [[ "$ADDR" != *@* ]]; then
  echo "地址格式错误：$ADDR" >&2
  exit 2
fi

DOMAIN="${ADDR#*@}"
LOCAL="${ADDR%@*}"
VMAIL_BASE="${VMAIL_BASE:-/var/vmail}"
VMAIL_UID="${VMAIL_UID:-5000}"
VMAIL_GID="${VMAIL_GID:-5000}"

# SHA512-CRYPT（Dovecot 未启动时 doveadm pw 不可用，所以用 openssl）
HASH=$(openssl passwd -6 "$PASS")

# 1. Dovecot 认证文件
if grep -q "^${ADDR}:" /etc/dovecot/users 2>/dev/null; then
  echo "账号已存在，更新密码"
  sed -i "s|^${ADDR}:.*|${ADDR}:${HASH}:${VMAIL_UID}:${VMAIL_GID}::${VMAIL_BASE}/${DOMAIN}/${LOCAL}::|" /etc/dovecot/users
else
  echo "${ADDR}:${HASH}:${VMAIL_UID}:${VMAIL_GID}::${VMAIL_BASE}/${DOMAIN}/${LOCAL}::" >> /etc/dovecot/users
fi

# 2. Postfix 虚拟邮箱表
if ! grep -q "^${ADDR} " /etc/postfix/vmailbox 2>/dev/null; then
  echo "${ADDR} ${DOMAIN}/${LOCAL}/" >> /etc/postfix/vmailbox
  postmap /etc/postfix/vmailbox
fi

# 3. Maildir 骨架
mkdir -p "${VMAIL_BASE}/${DOMAIN}/${LOCAL}/Maildir"/{cur,new,tmp}
mkdir -p "${VMAIL_BASE}/${DOMAIN}/${LOCAL}/Maildir"/{.Sent,.Drafts,.Trash,.Junk}/{cur,new,tmp}
chown -R "${VMAIL_UID}:${VMAIL_GID}" "${VMAIL_BASE}/${DOMAIN}/${LOCAL}"

systemctl reload dovecot 2>/dev/null || systemctl restart dovecot
systemctl reload postfix 2>/dev/null || systemctl restart postfix

echo "✅ ${ADDR} 已创建"
echo "   IMAP : ${ADDR%%@*}@<mail-host> 993 (SSL)"
echo "   SMTP : <mail-host> 465 (SSL) / 587 (STARTTLS)"
