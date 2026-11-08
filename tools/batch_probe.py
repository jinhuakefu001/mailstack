#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
批量 RCPT 探测（只输出统计，不输出具体地址）

用法: python tools/batch_probe.py /tmp/sample.txt

设计要点：
  - 按 MX 分组，同一 MX 复用连接（减少握手开销、降低被封风险）
  - 限速：每秒最多 RATE 条
  - 遇 4xx 立即降速并重试一次
  - 结果只汇总统计，地址一律不打印
"""
import smtplib
import socket
import sys
import time
from collections import defaultdict

try:
    import dns.resolver
except ImportError:
    print('need dnspython', file=sys.stderr)
    raise SystemExit(1)

FROM_ADDR   = 'verify@example.com'
TIMEOUT     = 12
RATE        = 2          # 每秒最多探测 2 条
MX_CACHE    = {}
BREAKER_4XX = 20         # 连续 20 次 4xx 就停（被限速了）


def get_mx(domain):
    if domain in MX_CACHE:
        return MX_CACHE[domain]
    try:
        ans = dns.resolver.resolve(domain, 'MX', lifetime=10)
        mxs = sorted((r.preference, str(r.exchange).rstrip('.')) for r in ans)
    except Exception:
        mxs = []
    MX_CACHE[domain] = mxs
    return mxs


def probe_batch(emails, host):
    """对同一 MX 的一批地址连续探测，返回 {email: verdict}"""
    out = {}
    try:
        smtp = smtplib.SMTP(timeout=TIMEOUT)
        smtp.connect(host, 25)
        smtp.helo('verify.local')
        smtp.mail(FROM_ADDR)
    except Exception as e:
        for e_ in emails:
            out[e_] = ('connect_fail', str(e)[:50])
        return out

    consec_4xx = 0
    for em in emails:
        try:
            code, msg = smtp.rcpt(em)
            text = msg.decode('utf-8', 'replace') if isinstance(msg, bytes) else str(msg)
            if code == 250:
                out[em] = ('exists', '')
                consec_4xx = 0
            elif code in (550, 551):
                out[em] = ('not_exist', '')
                consec_4xx = 0
            elif 400 <= code < 500:
                out[em] = ('throttled', '%d' % code)
                consec_4xx += 1
                if consec_4xx >= BREAKER_4XX:
                    for rest in emails[emails.index(em) + 1:]:
                        out[rest] = ('skipped', 'breaker')
                    break
                time.sleep(3)
            else:
                out[em] = ('rejected', '%d' % code)
                consec_4xx = 0
        except Exception as e:
            out[em] = ('conn_lost', str(e)[:40])
            try:
                smtp.quit()
            except Exception:
                pass
            return out
        time.sleep(1.0 / RATE)

    try:
        smtp.quit()
    except Exception:
        pass
    return out


def main():
    if len(sys.argv) < 2:
        print('usage: batch_probe.py <addr-file>', file=sys.stderr)
        raise SystemExit(2)

    emails = [l.strip() for l in open(sys.argv[1], encoding='utf-8') if l.strip()]
    print('loaded %d addresses' % len(emails))

    # 按域名分组
    by_domain = defaultdict(list)
    for em in emails:
        if '@' in em:
            by_domain[em.rsplit('@', 1)[1]].append(em)

    stats = defaultdict(int)
    t0 = time.time()
    total = len(emails)
    done = 0

    for domain, batch in by_domain.items():
        mxs = get_mx(domain)
        if not mxs:
            for em in batch:
                stats['no_mx'] += 1
            done += len(batch)
            print('  %-20s no MX (%d addr)' % (domain, len(batch)))
            continue

        host = mxs[0][1]
        # 每 100 条一批，批间歇 2 秒
        for i in range(0, len(batch), 100):
            chunk = batch[i:i + 100]
            res = probe_batch(chunk, host)
            for em, (verdict, _) in res.items():
                stats[verdict] += 1
            done += len(chunk)
            print('  %-20s via %-32s %4d/%d  (%.0fs)' %
                  (domain, host[:32], done, total, time.time() - t0))
            time.sleep(2)

    elapsed = time.time() - t0
    print()
    print('=' * 60)
    print('RESULTS  (total=%d, elapsed=%.0fs)' % (total, elapsed))
    print('=' * 60)
    for k in ('exists', 'not_exist', 'throttled', 'rejected', 'conn_lost',
              'connect_fail', 'skipped', 'no_mx'):
        if stats.get(k):
            pct = stats[k] * 100.0 / total
            print('  %-14s %6d  %5.1f%%' % (k, stats[k], pct))
    print()
    if stats.get('exists'):
        print('  抽样推断：假地址比例约 %.1f%%' %
              (stats.get('not_exist', 0) * 100.0 / max(1, stats['exists'] + stats.get('not_exist', 0))))


if __name__ == '__main__':
    main()
