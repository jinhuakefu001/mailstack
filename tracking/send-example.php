<?php
/**
 * 发送一封带追踪的事务邮件（注册确认 / 密码重置 / 订单通知这类场景）
 *
 * 演示三件事：
 *   1. 生成唯一 mid 并入库
 *   2. 把 <a href> 全部改写成追踪链接
 *   3. 在 </body> 前插入 1x1 像素
 *
 * 注意：这里只发单封、发给已和你建立关系的收件人（注册用户、下单用户）。
 *       未经同意的批量投递不应使用本代码。
 */

declare(strict_types=1);

require __DIR__ . '/track-lib.php';   // 复用 track.php 里的 db() / ensure_schema()

// ---------------- 配置 ----------------
const BASE_URL   = 'https://mail.example.com/t.php';
const FROM_EMAIL = 'noreply@example.com';
const FROM_NAME  = 'Example Service';   // 纯 ASCII；中文要 MIME 编码，见 README 踩坑 6

// ---------------- 发送 ----------------
function send_tracked(string $to, string $subject, string $html): string
{
    $db = db();
    ensure_schema($db);

    $mid = bin2hex(random_bytes(16));

    $db->prepare('INSERT INTO msg (mid, email, subject, sent_at) VALUES (?,?,?,?)')
       ->execute([$mid, $to, $subject, time()]);

    $body = inject_tracking($html, $mid);

    $headers = [
        'MIME-Version: 1.0',
        'Content-Type: text/html; charset=UTF-8',
        'From: ' . sprintf('%s <%s>', FROM_NAME, FROM_EMAIL),
        'Reply-To: ' . FROM_EMAIL,
        'X-Mail-ID: ' . $mid,
    ];

    mail($to, '=?UTF-8?B?' . base64_encode($subject) . '?=', $body, implode("\r\n", $headers));

    return $mid;
}

/** 重写外链 + 插入像素 */
function inject_tracking(string $html, string $mid): string
{
    // 1. 链接改写：只处理 <a href="http...">
    $html = preg_replace_callback(
        '#(<a\s[^>]*href=")(https?://[^"]+)(")#i',
        function (array $m) use ($mid): string {
            $wrapped = BASE_URL . '?m=' . $mid . '&u=' . b64url_encode($m[2]);
            return $m[1] . htmlspecialchars($wrapped, ENT_QUOTES) . $m[3];
        },
        $html
    );

    // 2. 像素：插到 </body> 前；没有 body 就追加
    $pixel = '<img src="' . BASE_URL . '?m=' . $mid
           . '" width="1" height="1" alt="" style="display:block;border:0" />';

    if (stripos($html, '</body>') !== false) {
        return preg_replace('#</body>#i', $pixel . '</body>', $html, 1);
    }
    return $html . $pixel;
}

// ---------------- 示例 ----------------
if (PHP_SAPI === 'cli' && ($argv[1] ?? '') === 'demo') {
    $mid = send_tracked(
        'user@example.com',
        '请确认你的邮箱',
        '<html><body><h2>欢迎</h2>'
        . '<p>点击下面的链接完成验证：</p>'
        . '<p><a href="https://example.com/verify?token=abc123">确认邮箱</a></p>'
        . '</body></html>'
    );
    echo "已发送，mid={$mid}\n";
}
