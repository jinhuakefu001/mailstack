<?php
/**
 * mailstack tracking endpoint
 *
 *   /track.php?m=<mid>              → 1x1 透明 GIF，记录「打开」
 *   /track.php?m=<mid>&u=<b64url>   → 302 重定向，记录「点击」
 *   /track.php?stats=1&key=<KEY>    → JSON 统计
 *
 * 部署：把本目录放到任意 PHP 站点下，改 track-lib.php 里的 TRACK_ALLOW_HOSTS
 *       和下面的 API_KEY，确保 data/ 目录可写。
 */

declare(strict_types=1);

require __DIR__ . '/track-lib.php';

const API_KEY = 'CHANGE_ME_TO_A_RANDOM_STRING';

$mid      = isset($_GET['m']) ? (string)$_GET['m'] : '';
$midValid = (bool)preg_match('/^[a-f0-9]{16,64}$/i', $mid);

// ---------------- 统计接口 ----------------
if (isset($_GET['stats'])) {
    header('Content-Type: application/json; charset=utf-8');
    if (!hash_equals(API_KEY, (string)($_GET['key'] ?? ''))) {
        http_response_code(403);
        echo json_encode(['error' => 'forbidden']);
        exit;
    }
    $db = db();
    ensure_schema($db);

    $tot  = (int)$db->query('SELECT COUNT(*) FROM msg')->fetchColumn();
    $open = (int)$db->query('SELECT COUNT(*) FROM msg WHERE opened_at IS NOT NULL')->fetchColumn();
    $clk  = (int)$db->query('SELECT COUNT(*) FROM msg WHERE clicked_at IS NOT NULL')->fetchColumn();

    // 发送后 15 秒内的事件几乎都是邮件网关扫描，不是真人
    $susp = (int)$db->query(
        'SELECT COUNT(*) FROM evt e JOIN msg m ON m.mid = e.mid WHERE e.ts - m.sent_at < 15'
    )->fetchColumn();

    echo json_encode([
        'sent'                  => $tot,
        'opened'                => $open,
        'clicked'               => $clk,
        'open_rate'             => $tot ? round($open / $tot * 100, 2) : 0,
        'click_rate'            => $tot ? round($clk / $tot * 100, 2) : 0,
        'likely_scanner_events' => $susp,
    ], JSON_UNESCAPED_UNICODE | JSON_PRETTY_PRINT);
    exit;
}

// ---------------- 非法 mid：返回图片，不记录 ----------------
if (!$midValid) {
    header('Content-Type: image/gif');
    header('Cache-Control: no-store, no-cache, must-revalidate');
    echo TRACK_PIXEL;
    exit;
}

$db = db();
ensure_schema($db);

// ---------------- 点击：302 重定向 ----------------
if (isset($_GET['u'])) {
    $target = b64url_decode((string)$_GET['u']);
    if ($target === null || !host_allowed($target)) {
        header('Content-Type: image/gif');
        echo TRACK_PIXEL;
        exit;
    }
    record_event($db, $mid, 'click', $target);
    header('Location: ' . $target, true, 302);
    exit;
}

// ---------------- 打开：记录后返回 1x1 ----------------
record_event($db, $mid, 'open');
header('Content-Type: image/gif');
header('Cache-Control: no-store, no-cache, must-revalidate, max-age=0');
header('Pragma: no-cache');
header('Content-Length: ' . strlen(TRACK_PIXEL));
echo TRACK_PIXEL;
