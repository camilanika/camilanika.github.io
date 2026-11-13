<?php
// API reference for docs.html, for admins only (QA fix OBS-9).
//
// docs.html used to carry the whole API reference in its page source and only hid it in the browser, so anyone
// could read it with curl. Now the reference lives in api/private/docs-content.json, which the web server never
// serves directly (see .htaccess and api/private/.htaccess), and this script hands it out only after Supabase
// confirms that the caller is an admin.
//
//   GET /api/docs.php   with header  X-User-Token: <the admin's Supabase access token>
//
// The check calls the public RPC is_admin() with the caller's own token: Supabase verifies the token's signature
// and expiry, and is_admin() reads the role from profiles, so a made-up or expired token gets "no".
// (X-User-Token rather than Authorization, because shared PHP hosting often drops the Authorization header.)

header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store, private');
header('Vary: X-User-Token');
header('X-Robots-Tag: noindex');

function out($code, $body) { http_response_code($code); echo $body; exit; }

if ($_SERVER['REQUEST_METHOD'] !== 'GET') out(405, '{"error":"GET only"}');

$token = $_SERVER['HTTP_X_USER_TOKEN'] ?? '';
if (!preg_match('/^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/', $token) || strlen($token) > 4096) out(401, '{"error":"LOGIN_REQUIRED"}');

// Supabase project URL and public anon key: the same values the website uses (js/config.js)
$cfg = @file_get_contents(dirname(__DIR__) . '/js/config.js');
if (!$cfg || !preg_match('/SUPABASE_URL:\s*"(https:\/\/[a-z0-9]+\.supabase\.co)"/', $cfg, $u) || !preg_match('/SUPABASE_ANON_KEY:\s*"([A-Za-z0-9._-]+)"/', $cfg, $k)) {
  out(500, '{"error":"CONFIG"}');
}

$ch = curl_init($u[1] . '/rest/v1/rpc/is_admin');
curl_setopt_array($ch, [
  CURLOPT_POST => true,
  CURLOPT_POSTFIELDS => '{}',
  CURLOPT_RETURNTRANSFER => true,
  CURLOPT_TIMEOUT => 10,
  CURLOPT_HTTPHEADER => ['Content-Type: application/json', 'apikey: ' . $k[1], 'Authorization: Bearer ' . $token],
]);
$res = curl_exec($ch);
$status = curl_getinfo($ch, CURLINFO_HTTP_CODE);
curl_close($ch);

if ($res === false || $status >= 500) out(502, '{"error":"CHECK_FAILED"}');
if ($status === 401) out(401, '{"error":"LOGIN_REQUIRED"}');          // bad or expired token
if ($status !== 200 || trim($res) !== 'true') out(403, '{"error":"NOT_ADMIN"}');

$doc = @file_get_contents(__DIR__ . '/private/docs-content.json');
if ($doc === false) out(500, '{"error":"NO_CONTENT"}');
out(200, $doc);
