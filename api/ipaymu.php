<?php
// iPaymu relay for camilanika.store
//
// iPaymu Production only accepts API calls from the IP addresses registered in the iPaymu dashboard.
// Supabase Edge Functions have no fixed IP, so create-payment and ipaymu-webhook send their
// (already signed) iPaymu requests here, and this Hostinger server, which has a fixed IP, passes
// them on unchanged.
//
// It holds no keys and changes nothing: the request is signed with the iPaymu API Key inside Supabase,
// so the relay can't be used to call iPaymu without that key. It only talks to iPaymu, and only to
// the two API paths the shop uses.
//
//   POST /api/ipaymu.php?env=prod&path=/api/v2/payment       (env=sandbox for testing)
//   GET  /api/ipaymu.php?ip=1   shows this server's outgoing IP (the one to register in iPaymu)
//
// Only the shop's own iPaymu accounts (QA fix OBS-42): otherwise anyone could send their own signed iPaymu
// requests through this server's registered IP. The allowed VA numbers are kept out of the public repo, in
//   ~/ipaymu-relay.php   (one level above public_html):   <?php return ['va' => ['<live VA>', '<sandbox VA>']];
// or in the environment variable IPAYMU_RELAY_VA ("<live VA>,<sandbox VA>"). Until one of them is set, every VA
// is still forwarded (so a deploy can't break checkout) and each response says so in X-Relay-Warning.

header('Content-Type: application/json');
header('Cache-Control: no-store');

function fail($code, $msg) { http_response_code($code); echo json_encode(['Status' => $code, 'Success' => false, 'Message' => $msg]); exit; }

if (isset($_GET['ip'])) {
  // asked at most once an hour, so this page can't be used to make the server call out over and over
  $cache = sys_get_temp_dir() . '/cn-relay-ip.json';
  if (is_file($cache) && time() - filemtime($cache) < 3600 && ($out = file_get_contents($cache))) { echo $out; exit; }
  $ch = curl_init('https://api.ipify.org?format=json');
  curl_setopt_array($ch, [CURLOPT_RETURNTRANSFER => true, CURLOPT_TIMEOUT => 10]);
  $out = curl_exec($ch); curl_close($ch);
  if ($out && json_decode($out)) @file_put_contents($cache, $out);
  echo $out ?: json_encode(['ip' => null]);
  exit;
}

if ($_SERVER['REQUEST_METHOD'] !== 'POST') fail(405, 'POST only');

$hosts = ['prod' => 'https://my.ipaymu.com', 'sandbox' => 'https://sandbox.ipaymu.com'];
$paths = ['/api/v2/payment', '/api/v2/transaction'];
$env = $_GET['env'] ?? '';
$path = $_GET['path'] ?? '';
if (!isset($hosts[$env]) || !in_array($path, $paths, true)) fail(400, 'Unknown env or path');

$va = $_SERVER['HTTP_VA'] ?? '';
$sig = $_SERVER['HTTP_SIGNATURE'] ?? '';
$ts = $_SERVER['HTTP_TIMESTAMP'] ?? '';
if (!preg_match('/^\d{6,20}$/', $va) || !preg_match('/^[a-f0-9]{64}$/', $sig) || !preg_match('/^\d{14}$/', $ts)) fail(400, 'Missing iPaymu headers');

$allowed = [];
$conf = dirname(__DIR__, 2) . '/ipaymu-relay.php';
if (is_file($conf)) { $c = include $conf; if (is_array($c) && isset($c['va'])) $allowed = array_map('strval', (array) $c['va']); }
if (!$allowed && getenv('IPAYMU_RELAY_VA')) $allowed = array_map('trim', explode(',', getenv('IPAYMU_RELAY_VA')));
$allowed = array_values(array_filter($allowed, 'strlen'));
if ($allowed && !in_array($va, $allowed, true)) fail(403, 'This relay only serves the shop\'s own iPaymu account');
if (!$allowed) header('X-Relay-Warning: no VA allow-list configured (see the top of api/ipaymu.php)');

$body = file_get_contents('php://input');
if ($body === false || strlen($body) > 65536) fail(413, 'Body too large');

$ch = curl_init($hosts[$env] . $path);
curl_setopt_array($ch, [
  CURLOPT_POST => true,
  CURLOPT_POSTFIELDS => $body,
  CURLOPT_RETURNTRANSFER => true,
  CURLOPT_TIMEOUT => 25,
  CURLOPT_HTTPHEADER => ['Content-Type: application/json', 'Accept: application/json', "va: $va", "signature: $sig", "timestamp: $ts"],
  CURLOPT_REFERER => 'https://camilanika.store/',
]);
$out = curl_exec($ch);
$status = curl_getinfo($ch, CURLINFO_HTTP_CODE);
$err = curl_error($ch);
curl_close($ch);
if ($out === false) fail(502, 'Relay could not reach iPaymu: ' . $err);
http_response_code($status ?: 502);
echo $out;
