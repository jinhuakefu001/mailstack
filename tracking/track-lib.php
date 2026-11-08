<?php
/**
 * mailstack tracking library
 *
 * track.php（HTTP 入口）和 send-example.php（发信侧）共用这里的函数。
 */

declare(strict_types=1);

const TRACK_DB_PATH = __DIR__ . '/data/track.db';

/** 允许跳转的域名（防开放重定向）。支持 *.example.com 通配 */
const TRACK_ALLOW_HOSTS = ['example.com', '*.example.com'];

/** 1x1 透明 GIF */
const TRACK_PIXEL = "GIF89a\x01\x00\x01\x00\x80\x00\x00\x00\x00\x00\xff\xff\xff!\xf9\x04\x01\x00\x00\x00\x00,\x00\x00\x00\x00\x01\x00\x01\x00\x00\x02\x02D\x01\x00;";

function db(): PDO
{
    $dir = dirname(TRACK_DB_PATH);
    if (!is_dir($dir)) {
        mkdir($dir, 0775, true);
    }
    $pdo = new PDO('sqlite:' . TRACK_DB_PATH, null, null, [
        PDO::ATTR_ERRMODE            => PDO::ERRMODE_EXCEPTION,
        PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
    ]);
    $pdo->exec('PRAGMA journal_mode=WAL');
    $pdo->exec('PRAGMA busy_timeout=3000');
    return $pdo;
}

function ensure_schema(PDO $db): void
{
    $db->exec('CREATE TABLE IF NOT EXISTS msg (
        mid        TEXT PRIMARY KEY,
        email      TEXT NOT NULL,
        subject    TEXT,
        campaign   TEXT,
        sent_at    INTEGER NOT NULL,
        opened_at  INTEGER,
        clicked_at INTEGER
    )');
    $db->exec('CREATE TABLE IF NOT EXISTS evt (
        id     INTEGER PRIMARY KEY AUTOINCREMENT,
        mid    TEXT NOT NULL,
        kind   TEXT NOT NULL,
        ts     INTEGER NOT NULL,
        ip     TEXT,
        ua     TEXT,
        target TEXT
    )');
    $db->exec('CREATE INDEX IF NOT EXISTS idx_evt_mid ON evt(mid)');
    $db->exec('CREATE INDEX IF NOT EXISTS idx_evt_ts  ON evt(ts)');
}

function client_ip(): string
{
    foreach (['HTTP_CF_CONNECTING_IP', 'HTTP_X_FORWARDED_FOR', 'REMOTE_ADDR'] as $k) {
        if (!empty($_SERVER[$k])) {
            $ip = trim(explode(',', (string)$_SERVER[$k])[0]);
            if (filter_var($ip, FILTER_VALIDATE_IP)) {
                return $ip;
            }
        }
    }
    return '';
}

function b64url_encode(string $s): string
{
    return rtrim(strtr(base64_encode($s), '+/', '-_'), '=');
}

function b64url_decode(string $s): ?string
{
    $s = strtr($s, '-_', '+/');
    $pad = strlen($s) % 4;
    if ($pad) {
        $s .= str_repeat('=', 4 - $pad);
    }
    $out = base64_decode($s, true);
    return $out === false ? null : $out;
}

/** 只允许跳转到白名单域名，防开放重定向 */
function host_allowed(string $url): bool
{
    $host = parse_url($url, PHP_URL_HOST);
    if (!is_string($host) || $host === '') {
        return false;
    }
    $host = strtolower($host);
    foreach (TRACK_ALLOW_HOSTS as $pattern) {
        $pattern = strtolower($pattern);
        if ($pattern === $host) {
            return true;
        }
        if (strpos($pattern, '*.') === 0) {
            $base = substr($pattern, 2);
            if ($host === $base || substr($host, -strlen('.' . $base)) === '.' . $base) {
                return true;
            }
        }
    }
    return false;
}

function record_event(PDO $db, string $mid, string $kind, ?string $target = null): void
{
    $ts = time();
    $db->prepare('INSERT INTO evt (mid, kind, ts, ip, ua, target) VALUES (?,?,?,?,?,?)')
       ->execute([
           $mid, $kind, $ts, client_ip(),
           substr((string)($_SERVER['HTTP_USER_AGENT'] ?? ''), 0, 512),
           $target,
       ]);

    $col = $kind === 'open' ? 'opened_at' : 'clicked_at';
    $db->prepare("UPDATE msg SET $col = COALESCE($col, ?) WHERE mid = ?")->execute([$ts, $mid]);
}
