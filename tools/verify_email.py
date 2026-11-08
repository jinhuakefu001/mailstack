#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
SMTP RCPT mailbox existence probe — tools/verify_email.py

连对方 MX 的 25 端口，用 RCPT TO 试探邮箱是否存在。
只用公开/自有地址作样本，不涉及任何真实用户数据。
"""
import socket
import smtplib
import sys

try:
    import dns.resolver
except ImportError:
    print('need dnspython: pip install dnspython', file=sys.stderr)
    raise SystemExit(1)

FROM_ADDR = 'verify@example.com'
TIMEOUT = 15

SAMPLES = [
    ('postmaster@163.com',              '163 管理员，必然存在'),
    ('postmaster@qq.com',               'QQ 管理员，必然存在'),
    ('postmaster@yunzexinda.com',       '自建邮局管理员，存在'),
    ('zzzzzzz999999888888@163.com',     '163 上几乎不存在'),
    ('qwertyuiop1234567890@gmail.com',  'Gmail 上几乎不存在'),
    ('test@this-domain-should-not-exist-xyz123.com', '域名不存在'),
]


def get_mx(domain):
    try:
        answers = dns.resolver.resolve(domain, 'MX', lifetime=TIMEOUT)
        return sorted((r.preference, str(r.exchange).rstrip('.')) for r in answers)
    except Exception as e:
        return [('ERR', '%s: %s' % (type(e).__name__, str(e)[:60]))]


def probe(email):
    if '@' not in email:
        return 'bad_format', ''
    domain = email.rsplit('@', 1)[1]

    mxs = get_mx(domain)
    if not mxs:
        return 'no_mx', 'no MX record'
    if mxs[0][0] == 'ERR':
        return 'dns_error', mxs[0][1]

    last_err = ''
    for pref, host in mxs[:3]:
        try:
            smtp = smtplib.SMTP(timeout=TIMEOUT)
            smtp.connect(host, 25)
            smtp.helo(socket.gethostname() or 'verify.local')
            smtp.mail(FROM_ADDR)
            code, msg = smtp.rcpt(email)
            try:
                smtp.quit()
            except Exception:
                pass
            text = msg.decode('utf-8', 'replace') if isinstance(msg, bytes) else str(msg)
            if code == 250:
                return 'exists?', '250 %s (via %s)' % (text[:50], host)
            if code in (550, 551):
                return 'NOT_EXIST', '%d %s (via %s)' % (code, text[:50], host)
            if 400 <= code < 500:
                return 'unknown(4xx)', '%d %s (via %s)' % (code, text[:50], host)
            return 'rejected', '%d %s (via %s)' % (code, text[:50], host)
        except Exception as e:
            last_err = '%s: %s' % (type(e).__name__, str(e)[:70])
    return 'connect_fail', last_err


def main():
    targets = [(a, '') for a in sys.argv[1:]] or SAMPLES
    print('%-46s %-13s %s' % ('address', 'verdict', 'detail'))
    print('-' * 108)
    counts = {}
    for addr, note in targets:
        verdict, detail = probe(addr)
        counts[verdict] = counts.get(verdict, 0) + 1
        print('%-46s %-13s %s' % (addr, verdict, detail))
        if note:
            print('%-46s %-13s -> %s' % ('', '', note))
    print()
    print('summary: ' + ', '.join('%s=%d' % (k, v) for k, v in sorted(counts.items())))


if __name__ == '__main__':
    main()
