# email-probe result

run: 2026-11-08T02:43:22Z
```
=== outbound port 25 reachability ===
  mx3.qq.com:25  OK
  163mx01.mxmail.netease.com:25  OK
  gmail-smtp-in.l.google.com:25  OK

address                                        verdict       detail
------------------------------------------------------------------------------------------------------------
postmaster@163.com                             exists?       250 Mail OK (via 163mx01.mxmail.netease.com)
                                                             -> 163 管理员，必然存在
postmaster@qq.com                              exists?       250 OK (via mx3.qq.com)
                                                             -> QQ 管理员，必然存在
postmaster@yunzexinda.com                      exists?       250 2.1.5 Ok (via _dc-mx.56444c4e5282.yunzexinda.com)
                                                             -> 自建邮局管理员，存在
zzzzzzz999999888888@163.com                    NOT_EXIST     550 User not found: zzzzzzz999999888888@163.com (via 163mx01.mxmail.netease.com)
                                                             -> 163 上几乎不存在
qwertyuiop1234567890@gmail.com                 exists?       250 2.1.5 OK 46e09a7af769-85f4fbf95dbsi825364a34.134 - (via gmail-smtp-in.l.google.com)
                                                             -> Gmail 上几乎不存在
test@this-domain-should-not-exist-xyz123.com   dns_error     NXDOMAIN: The DNS query name does not exist: this-domain-should-not-ex
                                                             -> 域名不存在

summary: NOT_EXIST=1, dns_error=1, exists?=4
```
