# CamilaNika online shop: setup guide

The website is hosted on Hostinger at https://camilanika.store (deployed from this repo with Hostinger Git deployment). Supabase holds the menu, stock, accounts, orders and promos. iPaymu takes the payments.

| File | What it is |
|---|---|
| `index.html`, `js/shop.js` | Shop page: menu from the database, cart, promo codes, login, online payment, order history |
| `admin.html` | Admin dashboard: orders, stock, main menus and submenus, products and variants, Paket Hemat, Testimoni, promos |
| `js/config.js` | Public settings: Supabase URL and key |
| `supabase/schema.sql` | Database tables, security rules and functions |
| `supabase/seed.sql` | The current menu, loaded as products and variants |
| `supabase/functions/create-payment` | Edge Function: creates the order and gets an iPaymu payment page |
| `supabase/functions/ipaymu-webhook` | Edge Function: iPaymu calls this when a payment succeeds or expires |
| `supabase/functions/midtrans-webhook` | Old Midtrans webhook, no longer used |
| `supabase/functions/phone-signup` | Edge Function: creates an account from a WhatsApp number + password |
| `supabase/functions/admin-users` | Edge Function: lets an admin set a new password for a customer |
| `js/nota.js` | Printable bill (Cetak nota) for orders |
| `js/cashflow.js`, `js/cashflow-core.js` | Admin **Cashflow Summary** page: income, expenses, offline sales, menu sales |
| `tests/` | Automated tests (database, page helpers, browser). Not part of the website; see `tests/README.md` |

## 1. Database (Supabase → SQL Editor)
1. Run `supabase/schema.sql`.
2. Run `supabase/seed.sql`, then `supabase/migrations/002_menu_structure.sql` (main menus and submenus). Every variant starts with **stock = 10**, which is a placeholder; set the real numbers in the admin page.
3. Recommended: under Database → Extensions, enable **pg_cron**, then run this. It releases stock held by checkouts that were never paid:
   ```sql
   select cron.schedule('release-expired-orders', '*/5 * * * *', 'select public.release_expired_orders()');
   ```

## 2. Login settings (Supabase → Authentication → URL Configuration)
- Site URL: `https://camilanika.store/`
- Redirect URLs: add `https://camilanika.store/**`

## 3. Edge Functions (Supabase → Edge Functions)
1. Create a function named **create-payment** and paste in `supabase/functions/create-payment/index.ts`. Do the same for **ipaymu-webhook**.
2. **create-payment**: leave "Verify JWT" **ON** (the site sends the public key).
   **ipaymu-webhook**: turn "Verify JWT" **OFF**, because iPaymu can't send a Supabase key. It's still protected: it never trusts the notification body. It asks iPaymu's Check Transaction API (signed with your API Key) for the transaction, and takes the order number and amount from that answer.
3. Under Edge Functions → Secrets, add:
   - `IPAYMU_VA`: your iPaymu **VA** number (the Sandbox one while testing)
   - `IPAYMU_API_KEY`: your iPaymu **API Key** (the Sandbox one while testing)
   - `IPAYMU_IS_PRODUCTION`: `false` (change to `true` when you go live)
   - `ALLOWED_ORIGINS`: `https://camilanika.store` (only this one: the old camilanika.github.io site is gone, so remove it if it is still listed)
   - `SITE_URL`: `https://camilanika.store/`
   The old `MIDTRANS_*` secrets and the **midtrans-webhook** function are no longer used and can be deleted once no Midtrans orders are pending.

## 4. iPaymu dashboard
- Sandbox: sign up at sandbox.ipaymu.com. Live: my.ipaymu.com. The VA and API Key are under **Integrasi** (Sandbox and Live keys are different).
- Set the callback / notify URL to `https://qynznqapyfxvjjeaoman.supabase.co/functions/v1/ipaymu-webhook` (create-payment also sends it with every payment).
- Nothing from iPaymu goes in the website: the VA and API Key stay in the Edge Function secrets.

## 5. Website config
Put the Supabase **anon / publishable key** (Project Settings → API Keys) into `js/config.js`.

## 6. First admin
Sign up on the website with your email, then run this in the SQL Editor:
```sql
update public.profiles set role = 'admin'
where id = (select id from auth.users where email = 'YOUR_EMAIL');
```
Open `https://camilanika.store/admin.html`.

## Going live
1. Once iPaymu has approved your account, switch to the Live VA and API Key. In the admin page, **Cashflow Summary → Pengaturan → Ganti ke Production** at the same time.
2. Put the **Live** VA and API Key in the secrets and set `IPAYMU_IS_PRODUCTION=true`.
3. Set the Live callback URL in the iPaymu dashboard to the same webhook address.
4. iPaymu Production only accepts API calls from a **registered IP**, and Supabase Edge Functions don't have a fixed one. So the functions send their signed iPaymu requests through `api/ipaymu.php` on Hostinger: add the secret `IPAYMU_RELAY_URL` = `https://camilanika.store/api/ipaymu.php`, and register Hostinger's outgoing IP in iPaymu → Integrasi → Kelola IP (open `https://camilanika.store/api/ipaymu.php?ip=1` to see it; currently `195.35.62.161`). The relay holds no keys and only forwards to iPaymu's payment and transaction APIs.
   So that only the shop's own iPaymu account can use the relay, create the file `ipaymu-relay.php` in the Hostinger home folder, one level **above** `public_html` (Hostinger → File Manager), with your VA numbers: `<?php return ['va' => ['<Live VA>', '<Sandbox VA>']];`. It stays out of the public repo. Until the file exists, the relay forwards every account and adds an `X-Relay-Warning` header to its answers.
5. Upgrade Supabase to Pro, which gives you backups and stops the project from being paused.

## How things work
- **Prices, promos and stock are always checked on the server**, so a customer can't change a price in their browser.
- Stock is **reserved** while a customer pays, for 60 minutes (iPaymu counts payment time in hours). It is deducted when iPaymu confirms payment and released if the payment expires, fails or is cancelled.
- **Promos:**
  - A promo without a code applies automatically. When several automatic discounts qualify, the biggest one is used.
  - Every free gift the order qualifies for is added.
  - A typed code replaces any automatic discount.
- **Cancelling a paid order** in the admin page doesn't refund it. Do the refund in the iPaymu dashboard, and adjust stock in the Stok tab if the items go back on sale.
- **Guests** can check out without an account. Their order status is saved on that device. Logged-in customers see their full history under Akun.
- WhatsApp and GoFood ordering still work as before.

## Menu structure
- **Main menus** (Minuman, Camilan) each become a section of the page and a link in the header. **Submenus** (Coffee Series, Cireng Isi Frozen…) group products inside them.
- Manage both in the admin page's **Menu** tab: add, rename, hide, delete, and reorder with ↑ ↓. Pick each product's submenu in the **Produk** tab.
- The page adapts on its own: empty or hidden submenus and main menus disappear, the jump links and size switch only show when they're needed, and product cards fill as many columns as fit.
- Deleting a main menu or submenu never deletes products or orders; its products are hidden until you move them to another submenu.
- Each main menu has its own **photo showcase**, set in **Menu → Ubah**: no photos, a swipeable photo row above the menu, or a photo mosaic beside the menu (the first photo is shown large). Upload photos, add captions, reorder or remove them. The same window holds the description, short info lines and round labels. A new main menu lays itself out from these settings.
- Database scripts to run once, in order: `migrations/002_menu_structure.sql`, `003_customer_accounts.sql`, `004_menu_showcase.sql`, `005_delete_accounts.sql`, `006_unlimited_stock.sql`, `007_shop_hours.sql`, `008_delivery.sql`, `009_order_history.sql`, `010_notifications.sql`, `011_referral_vouchers.sql`, `012_loyalty.sql`, `013_shipping_vouchers.sql`, `014_cashflow.sql`, `015_cashflow_hide_mock.sql`, `016_offline_payment_status.sql`, `017_qa_fixes.sql`, `018_order_privacy_checkout_guard.sql`, `019_order_columns_private.sql`, `020_paket_testimoni.sql`.

## Storefront redesign (Nov 2026): Paket Hemat, Best Seller, Testimoni
**Install once:** run `supabase/migrations/020_paket_testimoni.sql` in the SQL Editor. Until it runs, the shop looks the same as before minus the new sections, and the two new admin pages say the migration is needed.

- **Look:** cream page, white cards, one brand pink (`#B8325A`, dark enough for white text and for pink text on the blush bands) for buttons, caramel badges, dark espresso footer. The shop always shows the light theme (`<html data-theme="light">` in `index.html`); remove that attribute to follow the visitor's light/dark setting again.
- **Order of the page:** promo line above the header (the main automatic promo) → hero with one main button (**Pesan sekarang**) → category shortcuts (round photos, one per submenu) → **Best Seller** → **Paket Hemat** → menu → **Testimoni** → promo, GoFood, Cara order → footer.
- **Menu = one grid** ("Mau yang mana hari ini?"): every product in one grid, with tabs **Semua** + one per submenu. A tab shows only that submenu plus its info lines (tagline, the main menu's info lines and round labels from **Menu → Ubah**). Header links (Minuman, Camilan), the category shortcuts and outside links like `camilanika.store/#camilan` or `#sub-coffee-series` open the grid on that filter. Search looks through every product; closing it brings the chosen tab back.
- The per-main-menu **photo showcase** (swipeable row / mosaic) is no longer shown in the shop; its settings stay saved in **Menu → Ubah** in case you want them back.
- **Best Seller** is automatic: the 4 products sold most in the last 30 days, counting only real paid orders (test/Sandbox orders don't count). It shows once at least 2 products have sales.

### Paket Hemat (Admin → 🎁 Paket Hemat)
- **+ Paket baru**: name, optional short description and photo label (e.g. "Untuk 4 orang"), photo (upload or URL), the items inside with quantities (any variant of any menu item), and the paket price. The form shows the normal price and how much the buyer saves while you type.
- In the shop each paket shows its items, the normal price crossed out and "Hemat X%". The first paket gets the dark highlighted card.
- A paket is a normal product behind the scenes (one variant, the paket price), so the cart, online payment, promos, vouchers, loyalty, notifications and Cashflow all work with it unchanged. It also appears in **Produk** (edit it in Paket Hemat) and **Stok** (unlimited by default; set a number if you make a limited batch).
- A paket shows **Habis** while anything inside it is sold out or no longer for sale. Note: this check is in the shop page; the server checks the paket's own stock, so for strict limits also set the paket's stock in **Stok**.
- ↑ ↓ reorders, **Ubah → Tampilkan di toko** hides one temporarily, **Hapus** deletes it (past orders keep its name and price).
- The pakets live in a main menu called "Paket Hemat" (slug `paket`), which the shop shows as its own section. Don't hide or delete it in **Menu**, or the pakets stop being for sale.
- **Judul bagian di toko** sets the section's heading and line under it.

### Testimoni (Admin → 💬 Testimoni)
- **+ Testimoni**: a customer photo or review screenshot and/or the customer's own words, their name or @account (only with their permission), where it came from (Instagram, WhatsApp, GoFood, Google Maps, other) and an optional https link to the post. Photos go to the `product-images` storage (folder `testimoni/`).
- **Sembunyikan / Tampilkan**, ↑ ↓ to reorder, **Ubah**, **Hapus**.
- **Pengaturan bagian di toko**: section on/off, heading, line under it, how many to show (1–24), and the Instagram account linked next to the heading.
- The section only appears when at least one testimonial is shown. Use real customer content only.

## Customer accounts
- Run `supabase/migrations/003_customer_accounts.sql` once (adds the **Pelanggan** tab's data).
- The admin page's **Pelanggan** tab lists everyone who registered: name, email, WhatsApp, paid orders, total spent and last order. Search by name, email or number, open a customer's orders, and make someone admin or remove admin access. You can't remove your own admin access.
- **Sign-up with a WhatsApp number:** customers register with name, WhatsApp number and password, and are logged in straight away. No SMS or email is sent. Behind the scenes the login is a private address `<62number>@phone.camilanika.invalid`, created by the `phone-signup` Edge Function. Customers log in with their number (or email, for accounts made with email).
- **Forgotten passwords:** number accounts can't get a reset email. The customer chats you on WhatsApp; in **Pelanggan** press **Reset password**, then send the new password with the WhatsApp button. This uses the `admin-users` Edge Function, which only admins can call. Customers can change their password themselves under **Akun → Ganti password**.
- **Deleting an account:** in **Pelanggan** press **Hapus akun** and type HAPUS to confirm. The person can no longer log in and their profile is removed; their past orders stay in **Pesanan** (unlinked, like guest orders). You can't delete yourself or another admin (remove admin access first). The same number or email can register again later.
- **Admins:** Pelanggan → **Kelola admin**:
  - *Daftar admin* lists everyone with admin access; **Cabut admin** turns them back into a normal customer (the account stays). You can't remove your own access.
  - *Dari akun yang ada*: search by name, number, email or ID and press **Jadikan admin**.
  - *Buat akun admin baru*: name, WhatsApp number and a temporary password make a ready-to-use admin account (uses the `admin-users` Edge Function), with a button to send the login details over WhatsApp. If the number already has an account, you're offered to make that account admin instead.
  - The **Jadikan admin / Cabut admin** button on each customer row still works too.
- **Confirm email** is turned off (Authentication → Sign In / Providers), so email sign-ups can also log in right away.
- Anyone can register any number, since nothing is sent to verify it. Orders still need payment, so the risk is low; if it ever becomes a problem, add an SMS provider and switch to codes.

## Releasing changes
Browsers can keep scripts for up to 10 minutes. When `js/shop.js` or `js/config.js` changes, bump the `?v=` number on their `<script>` tags in `index.html` (and `admin.html` for config) so visitors get the new version immediately.

## Stock
- In **Stok**, type how many are available and press **Simpan** (or Enter). **Kosongkan** marks it sold out. **Tak terbatas** makes it always available without counting; type a number again any time to go back to counting.
- New variants start as **Tak terbatas**. Unlimited items are never reserved or counted down when paid.
- Unpaid online orders hold ("Dipesan") counted stock for 60 minutes (released up to 15 minutes later, so a payment page that is still open can finish); the number you type is what's left for new customers on top of those.

## Opening hours
- Admin page → **Toko**: **Tutup toko** closes the shop until you press **Buka toko** (ignores the schedule).
- **Jadwal buka**: tick "Buka & tutup otomatis setiap hari" and set the opening and closing time (WIB, GMT+7). A closing time earlier than the opening time means open past midnight.
- Optional message for customers while closed (e.g. holidays).
- While closed, customers still see the menu, but can't add to cart, pay or send a WhatsApp order; a banner explains why. The server also refuses new orders, so nothing slips through. The badge next to "CamilaNika Admin" shows whether the shop is open right now.

## Delivery location and fee
- At checkout customers press **Pilih di peta** and drop a pin (or use their phone's location). The map is OpenStreetMap, which is free; no Google key is needed. The pin fills the address if it's empty, and is saved with the order.
- In **Pesanan**, each order shows **📍 Buka di Google Maps**, the distance and the delivery fee.
- After payment, the customer's order shows **Chat admin untuk pengiriman**, a WhatsApp message with the order number and pin, so you can arrange the courier and ask for details.
- Admin page → **Toko → Pengiriman & ongkir**:
  - Drag the pin to the shop's exact location (starts at Bukit Cimanggu City).
  - **Gratis ongkir sampai**: free delivery up to this distance.
  - **Jarak maksimal**: farther than this can't be ordered online; the customer is asked to chat you.
  - **Tarif**: rows of "up to X km → Rp Y". Fill these from the Paxel app (its website rate check needs a CAPTCHA, so rates aren't fetched automatically).
  - Tick **Hitung ongkir otomatis** to turn it on. While off, delivery is free and the pin is optional.
- Distance is a straight line from the shop pin, so road distance is usually a bit longer; set tiers with that in mind.

## Order history ("Pesanan saya")
- Customers open it from **Akun → Riwayat pesanan → Lihat semua pesanan** (or `camilanika.store/#pesanan`). It lists every order from their account plus orders made on that device without logging in, with filters: Belum dibayar, Diproses, Selesai, Batal.
- Tapping an order opens its page: status, items, discount, ongkir, total, delivery address and map pin, payment method.
- **Unpaid orders** show "Bayar sebelum HH:MM" and a **Lanjutkan pembayaran** button that reopens the same iPaymu payment page, even on another phone when logged in. After 60 minutes the order shows as Kedaluwarsa and can't be paid any more.
- Paid orders show **Chat admin untuk pengiriman**; other orders show **Tanya lewat WhatsApp**.
- The page updates by itself while a payment is pending, and the phone's back button works.

## Notifications
- Registered customers open **Akun saya → Notifikasi** (the account button shows a red badge with everything that needs attention). Tapping one opens what it's about: the product on the menu, the promo details, or the order page. "Tandai semua dibaca" clears the counter. Notifications are kept, so they're still there next visit. Guests see a prompt to log in.
- Sent automatically by the database, to everyone registered at that moment:
  - **New product**: once it's visible in the shop (active, in an active submenu). Hiding and showing it again doesn't resend.
  - **New promo**: once it's active and its start time has passed. Each promo has **"Umumkan ke semua pelanggan"** (on by default); untick it for private codes. A promo with a code includes the code in the message.
- Sent only to the customer who owns the order (guest orders have no account, so no notification): order created, paid, Diproses, **Siap diantar**, **Sedang diantar**, Selesai, Dibatalkan, payment failed or expired. A repeated iPaymu notification never sends the same update twice.
- Products and promos that existed before this update are not announced.
- If a product is deleted or a promo has ended, the notification stays but is labelled, and tapping it explains that it's no longer available.

## Order steps in Pesanan
- Each paid order has a button for its next step: **Proses** → **Siap diantar** → **Sedang diantar**, plus **Selesai** and **Batalkan**. Every step notifies the customer.
- **💬 Chat Customer** opens a ready-made message in Bahasa Indonesia with the order number, delivery address (and map pin), every item with quantity and subtotal, discount, ongkir and total. Edit it if you like, then **Buka WhatsApp** opens a chat with the customer's number and the message filled in; nothing is sent until you press send in WhatsApp. If the number is missing or invalid you'll see a warning and can copy the message instead.

## Akun saya (customer menu)
- **Profile**: Nama, No. WhatsApp, Alamat (edit and save), plus Ganti password.
- **Pesanan**: order history and details. Red badge = unfinished orders (unpaid and not yet expired, paid, Diproses, Siap diantar, Sedang diantar).
- **Notifikasi**: badge = unread notifications.
- **Kode Voucher**: three sections, *Promo* (live promotions), *Voucher Referral* and *Voucher dari Admin*, each with code, discount, minimum, expiry, eligible products and status, plus **Salin kode** and **Pakai** (opens the cart with the code applied). Badge = vouchers the customer can use right now.
- The account button's badge is the sum of the three. Badges refresh on login, every minute, when the page comes back into view, and after paying, reading notifications or using a voucher.

## Referral campaigns (Admin → Voucher & Loyalty → Kampanye referral)
- A campaign has a **code** (e.g. `CNJUNI26`) you share on WhatsApp / Instagram. **Salin link** copies `camilanika.store/?ref=CODE`, which opens sign-up with the code filled in.
- New customers who sign up with an active code get their **own one-time voucher** (`REF-XXXX-XXXX`), shown right after sign-up and kept in Kode Voucher.
- Settings per campaign: start / end, status (Aktif, Dijeda, Berakhir), total voucher quota, daily quota, max vouchers per network (IP), and the voucher: percent or Rupiah, max discount, minimum purchase, products, validity in days.
- **"Voucher aktif: setelah pembayaran pertama"** keeps the voucher pending until the customer's first successful payment, which makes throwaway accounts less useful.
- Invalid, paused, ended, not-yet-started or full codes are refused at sign-up (the customer can fix or clear the code). One referral voucher per account, ever.
- **Pendaftar** lists who signed up, their voucher, its status, and the order it was used on.
- Sign-ups are rate limited per network (**Batas pendaftaran**: default 5 per hour, 20 per day). There's no identity check yet, so one person can still make several accounts with different numbers; a WhatsApp OTP check can be added later (profiles already have a `phone_verified` field for it).

## Vouchers (Admin → Voucher & Loyalty → Voucher)
- **+ Voucher baru**: a one-time code (typed or generated `CN-XXXX-XXXX`), percent or Rupiah, max discount, minimum, products, expiry, internal note.
- **Assign voucher**: search a customer by name, email, WhatsApp number or user ID, then pick an unassigned voucher or create one on the spot. The customer gets a notification. An assigned voucher only works for that customer.
- **Cabut** revokes a voucher (not possible once used or while an unpaid order holds it). **Riwayat** shows every step: created, assigned, reserved, released, used, revoked.
- Statuses: Menunggu bayar pertama (pending), Tersedia, Dipesan (an unpaid order holds it), Terpakai, Kedaluwarsa, Dicabut.
- Customers type vouchers in the same box as promo codes. The server checks owner, status, expiry, minimum and products, and calculates the discount. A voucher replaces automatic discounts (free gifts still apply). It's held while the order is unpaid, marked **used only when iPaymu confirms payment**, and released if the payment expires, fails or is cancelled. Two orders can't use the same voucher at once.
- Codes are unique across promos, vouchers and referral campaigns.
- Vouchers need online payment; a WhatsApp order that mentions a voucher code isn't checked automatically.

## Loyalty program (Admin → Voucher & Loyalty → Loyalty)
- **Milestones**: total spending (e.g. Rp100.000) → voucher (Rupiah or %, max discount, minimum purchase to use it, valid N days and/or until a date), description for customers, active/inactive. Tick **Berulang** to reward again at every multiple (Rp500.000, Rp1.000.000, …).
- **What counts**: orders from an account once paid (Dibayar, Diproses, Siap diantar, Sedang diantar, Selesai), the amount actually paid after discounts. Ongkir isn't counted unless you tick **Ongkir ikut dihitung**. Pending, unpaid, expired and failed orders never count. Each order counts once, even if iPaymu sends its notification several times.
- **Rewards**: when a payment takes a customer's total past a milestone, a one-time voucher (`LOY-XXXX-XXXX`) is created for them automatically with a notification. One payment can unlock several milestones. Each milestone is given once per customer (once per multiple for recurring ones), never twice.
- **Refunds**: cancelling a paid order (refund in iPaymu) removes its amount from the total. Vouchers already given stay; revoke one in **Voucher** if needed. Reaching the milestone again doesn't give a second voucher.
- **No surprise rewards**: customers already above a milestone you add or lower don't get it automatically. The milestone row shows **Berikan ke N pelanggan** if you want to give it to them on purpose (marked "diberikan admin" in their history).
- Orders paid before this update count toward totals, but don't give rewards.
- **Pelanggan** table: total spending, paid orders, highest milestone, next milestone, vouchers available / used, and **Riwayat** (each counted payment, refunds, and every reward with its voucher status).
- Customers see a **⭐ Loyalty** card in Akun saya, a **Program Loyalty** page (total, progress bar to the next reward, remaining amount, all milestones ✓/🔒, their loyalty vouchers, history), and a **Voucher Loyalty** section in Kode Voucher.
- Notifications: reward unlocked, "Sedikit lagi" when 80% of the way to the next one, and a reminder 3 days before any voucher expires.

## Ongkir vouchers ("Potongan ongkir saja")
- Available as a voucher type everywhere vouchers are made: **+ Voucher baru / Assign voucher**, referral campaign rewards, and loyalty milestones.
- The amount is the **most it takes off the ongkir** (e.g. Rp10.000). It never takes more than the order's ongkir, and never touches item prices, so automatic item promos still apply next to it. Minimum purchase and eligible products are checked on the items.
- If an order has no ongkir (inside the free radius, or delivery fees off), the voucher can't be used, so it isn't wasted; the cart explains why.
- Orders show it as **Potongan ongkir** (cart, order page, admin order card, Chat Customer message). On the iPaymu bill a discounted order is shown as one line with the final total.
- Loyalty counts the items paid, not the ongkir.

## Admin page on phones and tablets
- **Desktop (1024px and wider)**: menu in a sidebar on the left; the Voucher & Loyalty submenu (Kampanye referral, Voucher, Loyalty, Batas pendaftaran) sits under it. The rest of the screen is content.
- **Phones and tablets**: the sidebar is hidden; the **☰** button opens it as a drawer (close with ×, Escape, or by tapping outside; it also closes after choosing a page). The top bar shows the current page name.
- On phones, tables turn into cards (each value labelled with its column name) and popups use the whole screen, so nothing needs sideways scrolling.
- Each page has its own address (e.g. `admin.html#vouchers/loyalty`), so refresh and bookmarks keep you on the same page.

## Cashflow Summary (Admin → 💰 Cashflow Summary)
**Install once:** run `supabase/migrations/014_cashflow.sql`, `015_cashflow_hide_mock.sql` and `016_offline_payment_status.sql` (in that order) in the SQL Editor, then paste the updated `create-payment` and `ipaymu-webhook` Edge Functions again (they report whether a payment went through iPaymu Sandbox or Production). The page works before the functions are redeployed; until then the Pengaturan setting decides.

**What it shows** (for Hari ini, Kemarin, Minggu ini, Bulan ini, Tahun ini or any dates; WIB, weeks start Monday):
- **Offline Order Income**: walk-in / WhatsApp / phone sales you record here, once they're paid (on the day they were paid).
- **Total Income**: online orders with status **Selesai** (on the day they were completed) plus paid offline sales. The small print under it shows the online amount and number of orders, and the offline amount. **Total Expenses**: costs you record here. **Net Cashflow** = Total Income − Total Expenses. This is recorded cash in minus cash out, not accounting profit.
- **Total Items Sold** (online + offline sales that have item details).
- Orders that are unpaid, paid but not yet Selesai, cancelled, expired or failed never count.

**Test orders (Mock) are left out completely**
- Online orders paid through **Sandbox** are test orders (Mock); **Production** orders are real. If the environment wasn't reported, **Pengaturan → mode pembayaran** decides (starts as Sandbox).
- Test orders are **not listed and not counted anywhere** in Cashflow Summary: not in the cards, the lists, or Penjualan menu. There is no test option for offline sales; everything recorded here is a real sale.
- Every order placed before this update was made while payments were in Sandbox, so the update marked them as test orders. (If you install this after going live, set `v_live_since` at the top of the backfill block in 014 first.)
- To change an order's label, use **Pesanan**: test orders show a **Pesanan tes** badge, and each order has **Tandai pembelian asli** / **Tandai pesanan tes**. A completed order marked as a real purchase appears in Cashflow Summary straight away.
- Orders flagged **Perlu ditinjau** show in **Pesanan selesai** with **Benar, pembelian asli** (keep it) and **Ini pesanan tes** (hide it).
- Changing the label never changes the order's status, items or payment. Each change is recorded with who made it (Detail → Riwayat perubahan).
- Online orders can't be edited or deleted here; use **Pesanan** (Detail → **Buka di Pesanan**).

**Lists and Detail**
- Filters: Pelanggan (customers who bought in the selected period, with their number of orders; on Transaksi, Pesanan selesai and Penjualan offline), plus type, source, payment, status bayar, category and search depending on the list. **Reset filter** clears them.
- On phones: one row of period chips and one row of section tabs (swipe sideways), Total Income across the top, and the filters folded behind a **Filter** button (it shows how many are active); search stays visible.
- Every list shows only the date, who / what, and the amount. Tap a row (or **Detail**) for everything else: items, payment, source, notes, history, and the **Ubah / Hapus** and review buttons. Penjualan menu works the same way (category, average price and share are in Detail).

**Cetak nota (bill)**
- **🖨️ Cetak nota** is on every order card in **Pesanan** and in the Detail window of every online or offline sale in Cashflow Summary. It prints the same layout as the **Nota** sheet in Data Jualan (A5): No. Nota, time, buyer, items with detail, qty, unit price and total, discounts / ongkir, TOTAL PEMBAYARAN and the thank-you footer. Choose your printer or "Save as PDF" in the print window. Unpaid or cancelled orders are marked on the bill.

**Penjualan offline**
- **+ Penjualan offline**: date and time, receipt number (optional), customer (optional), source, payment method, then either **Per item menu** (pick menu and size; the menu price fills in and can be changed; quantity, discount per line, order discount, extra charge such as ongkir) or **Nominal saja** (just the amount received).
- **Status pembayaran**: **Lunas** (default; optionally the time it was paid) or **Belum dibayar** for orders that came in but haven't been paid yet. Unpaid sales are listed with a red **Belum dibayar** badge (filter: Status bayar) and a banner shows how many and how much is still owed, but they are **not income** and not in items sold or menu sales until paid. Open one and press **Tandai lunas** to record the payment date and method; it then counts on that date. A bill printed while unpaid says "Belum dibayar".
- The database recalculates the total; a different total is refused. Pressing save twice saves once. An online order number (CN-…) can't be recorded here, so nothing is counted twice, and a receipt number can only be used once.
- Nominal-saja sales count as income but have no items, so they're left out of menu sales; the Penjualan menu tab says how many and how much.
- Edit and delete (with confirmation) from the list. Deleted records are kept in the database (soft delete) for the audit trail.

**Pengeluaran**
- **+ Pengeluaran**: date and time, description, category, amount (whole Rupiah, more than 0), payment method, vendor, optional photo/PDF of the receipt (private storage, admins only), notes.
- 11 categories to start with. **Kelola kategori** adds, renames or hides them. Categories are never deleted, and renaming one doesn't change past expenses.

**Penjualan menu**: best sellers by quantity and revenue, sales per category (the submenus, e.g. Coffee Series), per menu or per size/variant, sort, filter and search, plus a full table with average price and share of menu revenue. Menu revenue = item lines (price × quantity − item discount); order discounts, vouchers and ongkir aren't split over items, so it can differ from income. No profit is calculated (costs per item aren't connected yet).

**Known limits**
- Refunds: a paid order cancelled in **Pesanan** (refund done in iPaymu) is not counted. Partial refunds aren't recorded anywhere in the shop, so they can't be shown.
- Orders completed before this update get their completion date from the order's last change (marked "perkiraan").
- Menu sales use each product's current submenu for online orders; offline lines keep the submenu they had when saved.

## QA fixes (8 Nov 2026)
The QA inspection's findings and the tests that cover them are in `docs/test-cases-and-automation.docx`.

**Install once:** run `supabase/migrations/017_qa_fixes.sql` in the SQL Editor (after 016; safe to run twice). Then paste the updated Edge Functions `create-payment`, `ipaymu-webhook`, `admin-users` and `phone-signup` again. The website changes go live when this branch is merged into `main`.

- Migrations 014, 015 and 016 now refuse to run again on their own once a later one is applied, because that would undo the later fixes. To re-run the whole Cashflow sequence on purpose, first run `set cn.rerun_cashflow = 'on';` in the same session, then every migration from 014 onwards, in order.
- Orders that need a look get a **Perlu dicek** badge in **Pesanan**: paid after their stock was sold to another order, or paid late after their voucher went to another order. Check them in the iPaymu dashboard (refund, or send the item if stock allows).

**Recommended settings (not in code):**
- Supabase → Authentication → Sign In / Providers: turn off **Allow new users to sign up**. Customers still sign up through `phone-signup` (it uses the service role), but nobody can create accounts directly with the public key.
- Supabase → Authentication: turn on leaked-password protection.

## Order privacy and checkout limits (migrations 018 and 019)
**Install once, in this order** (each step keeps the live shop working):
1. Run `supabase/migrations/018_order_privacy_checkout_guard.sql` in the SQL Editor (after 017; safe to run twice). It only adds things.
2. Merge the website changes into `main` (the admin page now reads orders through `admin_list_orders`, which step 1 creates).
3. Paste the updated Edge Function `create-payment` again (it calls `checkout_guard`, which step 1 creates).
4. Run `supabase/migrations/019_order_columns_private.sql` (safe to run twice). Only now are the admin-only fields hidden from customers; running it before step 2 would empty the admin's order list until the merge.

- **OBS-12:** customers can only read the order fields the shop shows them. Internal fields (classification note, review and source, payment environment, *Perlu dicek* reason, payment references, access token) are admin-only. A column added to `orders` later is hidden from customers until it is added to the `grant select (…)` list in migration 019.
- **DEF-002, online payment switch:** `create-payment` now follows **`shop_settings.online_payment`** as well as `ONLINE_PAYMENT` in `js/config.js`. Keep the two in step:

  | `js/config.js` `ONLINE_PAYMENT` | `shop_settings.online_payment` | Who can pay online |
  |---|---|---|
  | `false` | `off` | nobody |
  | `"test"` (with `?test=1`) | `test` | only admins: **log in to the shop with your admin account** before testing |
  | `true` | `on` | everyone |

  Change it in Supabase → Table Editor → `shop_settings` (the row with id 1). New installs start at `test`.
- **DEF-002, limits:** per network, at most `checkout_limit_hour` (default 10) checkout attempts an hour and `checkout_limit_day` (default 30) a day; per phone number, at most `checkout_max_pending` (default 3) unpaid orders at once. Admins are never limited. Customers who hit a limit see a message telling them to wait or order on WhatsApp.


## Privacy notice (OBS-35)
`privacy.html` is the shop's privacy notice under UU PDP (UU 27/2022). It is linked from the footer, under **Bayar online**, and on the sign-up form.
Update it, and change its *Berlaku sejak* date, **before** the shop starts collecting new personal data or uses a new service that receives it (Pasal 21 ayat 2). Examples: a new form field, an analytics or chat tool, moving the Supabase project to another region, or a new payment or delivery partner.

## Colours and contrast (OBS-33)
Text and button colours meet WCAG AA contrast (4.5:1) on the cream backgrounds. `--rose` (#B63853), `--caramel` (#A05F20) and `--wa` (#187A42) are slightly darker than the original brand colours for that reason; `--rose-bright` (#D9586F, the original rose) is kept for the logo, which is exempt, and for large text on the dark brown promo band. In dark mode, text on the light green, the pastel section colours and GoFood red uses `--wa-ink`, `--on-accent` and `--go-text`. `tests/ui/contrast.ui.test.js` checks the shop, the privacy notice and the admin page (light and dark) with axe-core, so a colour change that makes text hard to read fails the tests.
