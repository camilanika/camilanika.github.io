// Test stand-in for js/vendor/supabase.js, served only by tests/ui/harness.js.
// Same API shape as the parts of supabase-js the admin page uses, but every call goes to the
// test server, which runs it against a real local PostgreSQL as the logged-in test user
// (role "authenticated", RLS and function permissions apply exactly as in Supabase).
(function () {
  const post = (path, body) => fetch(path, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ ...body, uid: window.__TEST_UID }) }).then((r) => r.json());
  class Query {
    constructor(table) { this.q = { table, select: "*", filters: [], order: [], limit: null, single: false }; }
    select(cols) { this.q.select = cols || "*"; return this; }
    eq(col, val) { this.q.filters.push({ op: "eq", col, val }); return this; }
    in(col, val) { this.q.filters.push({ op: "in", col, val }); return this; }
    order(col, o = {}) { this.q.order.push({ col, asc: o.ascending !== false }); return this; }
    limit(n) { this.q.limit = n; return this; }
    maybeSingle() { this.q.single = true; return this; }
    single() { this.q.single = true; return this; }
    insert() { return Promise.resolve({ data: null, error: { message: "writes are not supported by the test client" } }); }
    update() { return this.insert(); }
    delete() { return this.insert(); }
    then(ok, bad) { return post("/__select", { q: this.q }).then(ok, bad); }
  }
  const user = () => ({ id: window.__TEST_UID, email: "admin@test.local" });
  window.supabase = {
    createClient() {
      const listeners = [];
      return {
        from: (t) => new Query(t),
        rpc: (fn, args) => post("/__rpc", { fn, args: args || {} }),
        auth: {
          onAuthStateChange(cb) { listeners.push(cb); setTimeout(() => cb(window.__TEST_UID ? "SIGNED_IN" : "SIGNED_OUT", window.__TEST_UID ? { user: user() } : null), 0); return { data: { subscription: { unsubscribe() {} } } }; },
          getSession: async () => ({ data: { session: window.__TEST_UID ? { user: user() } : null } }),
          getUser: async () => ({ data: { user: user() } }),
          signOut: async () => { window.__TEST_UID = null; listeners.forEach((cb) => cb("SIGNED_OUT", null)); return {}; },
          signInWithPassword: async () => ({ error: { message: "not in tests" } }),
        },
        storage: {
          from: (bucket) => ({
            upload: async (path) => { window.__uploads = (window.__uploads || []).concat(bucket + "/" + path); return { data: { path }, error: null }; },
            createSignedUrl: async () => ({ data: { signedUrl: "about:blank" }, error: null }),
            getPublicUrl: (path) => ({ data: { publicUrl: "about:blank#" + path } }),
          }),
        },
      };
    },
  };
})();
