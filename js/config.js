// CamilaNika shop settings. These values are public (safe to be in the website).
// Never put the Supabase service_role key or the iPaymu API Key / VA here (they live in Edge Function secrets).
window.CN_CONFIG = {
  SUPABASE_URL: "https://qynznqapyfxvjjeaoman.supabase.co",
  SUPABASE_ANON_KEY: "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InF5bnpucWFweWZ4dmpqZWFvbWFuIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTI5OTU5NTgsImV4cCI6MjEwODU3MTk1OH0.Ev1_3WA6eW6cGTYI8C79oQTfLu-UpvNzCEXnBf__qRY",
  ONLINE_PAYMENT: true,            // false = off · "test" = only with ?test=1 in the address · true = on for everyone
  WHATSAPP: "6281368976966",
  SITE_URL: "https://camilanika.store/"
};
