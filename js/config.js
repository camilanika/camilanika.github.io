// CamilaNika shop settings. These values are public (safe to be in the website).
// Never put the Supabase service_role key or the Midtrans SERVER key here.
window.CN_CONFIG = {
  SUPABASE_URL: "https://qynznqapyfxvjjeaoman.supabase.co",
  SUPABASE_ANON_KEY: "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InF5bnpucWFweWZ4dmpqZWFvbWFuIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTI5OTU5NTgsImV4cCI6MjEwODU3MTk1OH0.Ev1_3WA6eW6cGTYI8C79oQTfLu-UpvNzCEXnBf__qRY",
  MIDTRANS_CLIENT_KEY: "Mid-client-qay1f3hZlcRK66JJ",   // Sandbox client key (Production one goes here when going live)
  MIDTRANS_IS_PRODUCTION: false,   // switch to true (and use production keys) when going live
  ONLINE_PAYMENT: "test",          // false = off · "test" = only with ?test=1 in the address · true = on for everyone
  WHATSAPP: "6281368976966",
  SITE_URL: "https://camilanika.github.io/"
};
