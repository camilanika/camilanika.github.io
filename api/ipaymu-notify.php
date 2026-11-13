<?php
// iPaymu payment notifications for camilanika.store
//
// iPaymu Production only sends to (and accepts as notifyUrl) domains registered in the iPaymu
// dashboard. The shop's domain is registered, the Supabase project domain isn't, so create-payment
// gives iPaymu this address, and this script passes each notification on to the Supabase
// Edge Function ipaymu-webhook unchanged.
//
// Nothing here is trusted: ipaymu-webhook never believes the notification body. It asks iPaymu's
// Check Transaction API (signed with the API Key) for the real status and amount.

header('Content-Type: application/json');
header('Cache-Control: no-store');

$target = 'https://qynznqapyfxvjjeaoman.supabase.co/functions/v1/ipaymu-webhook';

if ($_SERVER['REQUEST_METHOD'] !== 'POST') { http_response_code(405); echo '{"error":"POST only"}'; exit; }
$body = file_get_contents('php://input');
if ($body === false || strlen($body) > 65536) { http_response_code(413); echo '{"error":"too large"}'; exit; }

$ch = curl_init($target);
curl_setopt_array($ch, [
  CURLOPT_POST => true,
  CURLOPT_POSTFIELDS => $body,
  CURLOPT_RETURNTRANSFER => true,
  CURLOPT_TIMEOUT => 25,
  CURLOPT_HTTPHEADER => ['Content-Type: ' . ($_SERVER['CONTENT_TYPE'] ?? 'application/x-www-form-urlencoded')],
]);
$out = curl_exec($ch);
$status = curl_getinfo($ch, CURLINFO_HTTP_CODE);
curl_close($ch);
http_response_code($out === false ? 502 : ($status ?: 502));
echo $out === false ? '{"error":"forward failed"}' : $out;
