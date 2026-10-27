# CamilaNika online shop: setup guide

The website stays on GitHub Pages. Supabase holds the menu, stock, accounts, orders and promos. Midtrans takes the payments.

| File | What it is |
|---|---|
| `index.html`, `js/shop.js` | Shop page: menu from the database, cart, promo codes, login, online payment, order history |
| `admin.html` | Admin dashboard: orders, stock, main menus and submenus, products and variants, promos |
| `js/config.js` | Public settings: Supabase URL and key, Midtrans client key |
| `supabase/schema.sql` | Database tables, security rules and functions |
| `supabase/seed.sql` | The current menu, loaded as products and variants |
| `supabase/functions/create-payment` | Edge Function: creates the order and gets a Midtrans payment token |
| `supabase/functions/midtrans-webhook` | Edge Function: Midtrans calls this when a payment succeeds, fails or expires |
| `supabase/functions/phone-signup` | Edge Function: creates an account from a WhatsApp number + password |
| `supabase/functions/admin-users` | Edge Function: lets an admin set a new password for a customer |

## 1. Database (Supabase → SQL Editor)
1. Run `supabase/schema.sql`.
2. Run `supabase/seed.sql`, then `supabase/migrations/002_menu_structure.sql` (main menus and submenus). Every variant starts with **stock = 10**, which is a placeholder; set the real numbers in the admin page.
3. Recommended: under Database → Extensions, enable **pg_cron**, then run this. It releases stock held by checkouts that were never paid:
   ```sql
   select cron.schedule('release-expired-orders', '*/5 * * * *', 'select public.release_expired_orders()');
   ```

## 2. Login settings (Supabase → Authentication → URL Configuration)
- Site URL: `https://camilanika.github.io/`
- Redirect URLs: add `https://camilanika.github.io/**`

## 3. Edge Functions (Supabase → Edge Functions)
1. Create a function named **create-payment** and paste in `supabase/functions/create-payment/index.ts`. Do the same for **midtrans-webhook**.
2. **create-payment**: leave "Verify JWT" **ON** (the site sends the public key).
   **midtrans-webhook**: turn "Verify JWT" **OFF**, because Midtrans can't send a Supabase key. It's still protected: every call must carry Midtrans' signature made with your Server Key, and the function re-checks the payment status with Midtrans before changing anything.
3. Under Edge Functions → Secrets, add:
   - `MIDTRANS_SERVER_KEY`: the Midtrans **Server Key** (the Sandbox one while testing)
   - `MIDTRANS_IS_PRODUCTION`: `false` (change to `true` when you go live)
   - `ALLOWED_ORIGINS`: `https://camilanika.github.io`
   - `SITE_URL`: `https://camilanika.github.io/`

## 4. Midtrans dashboard
- Settings → Payment → **Notification URL**: `https://qynznqapyfxvjjeaoman.supabase.co/functions/v1/midtrans-webhook`
- Copy the **Client Key** into `js/config.js`. Never put the Server Key in the website.

## 5. Website config
Put the Supabase **anon / publishable key** (Project Settings → API Keys) and the Midtrans **Client Key** into `js/config.js`.

## 6. First admin
Sign up on the website with your email, then run this in the SQL Editor:
```sql
update public.profiles set role = 'admin'
where id = (select id from auth.users where email = 'YOUR_EMAIL');
```
Open `https://camilanika.github.io/admin.html`.

## Going live
1. Once Midtrans has approved your account, switch the dashboard to Production.
2. Put the **production** Server Key in the secrets and set `MIDTRANS_IS_PRODUCTION=true`.
3. Put the production Client Key in `js/config.js` and set `MIDTRANS_IS_PRODUCTION: true`.
4. Set the Production Notification URL in Midtrans to the same webhook address.
5. Upgrade Supabase to Pro, which gives you backups and stops the project from being paused.

## How things work
- **Prices, promos and stock are always checked on the server**, so a customer can't change a price in their browser.
- Stock is **reserved** while a customer pays, for 30 minutes. It is deducted when Midtrans confirms payment and released if the payment expires, fails or is cancelled.
- **Promos:**
  - A promo without a code applies automatically. When several automatic discounts qualify, the biggest one is used.
  - Every free gift the order qualifies for is added.
  - A typed code replaces any automatic discount.
- **Cancelling a paid order** in the admin page doesn't refund it. Do the refund in the Midtrans dashboard, and adjust stock in the Stok tab if the items go back on sale.
- **Guests** can check out without an account. Their order status is saved on that device. Logged-in customers see their full history under Akun.
- WhatsApp and GoFood ordering still work as before.

## Menu structure
- **Main menus** (Minuman, Camilan) each become a section of the page and a link in the header. **Submenus** (Coffee Series, Cireng Isi Frozen…) group products inside them.
- Manage both in the admin page's **Menu** tab: add, rename, hide, delete, and reorder with ↑ ↓. Pick each product's submenu in the **Produk** tab.
- The page adapts on its own: empty or hidden submenus and main menus disappear, the jump links and size switch only show when they're needed, and product cards fill as many columns as fit.
- Deleting a main menu or submenu never deletes products or orders; its products are hidden until you move them to another submenu.
- Each main menu has its own **photo showcase**, set in **Menu → Ubah**: no photos, a swipeable photo row above the menu, or a photo mosaic beside the menu (the first photo is shown large). Upload photos, add captions, reorder or remove them. The same window holds the description, short info lines and round labels. A new main menu lays itself out from these settings.
- Database scripts to run once, in order: `migrations/002_menu_structure.sql`, `003_customer_accounts.sql`, `004_menu_showcase.sql`, `005_delete_accounts.sql`, `006_unlimited_stock.sql`, `007_shop_hours.sql`, `008_delivery.sql`, `009_order_history.sql`, `010_notifications.sql`, `011_referral_vouchers.sql`.

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
GitHub Pages lets browsers keep scripts for up to 10 minutes. When `js/shop.js` or `js/config.js` changes, bump the `?v=` number on their `<script>` tags in `index.html` (and `admin.html` for config) so visitors get the new version immediately.

## Stock
- In **Stok**, type how many are available and press **Simpan** (or Enter). **Kosongkan** marks it sold out. **Tak terbatas** makes it always available without counting; type a number again any time to go back to counting.
- New variants start as **Tak terbatas**. Unlimited items are never reserved or counted down when paid.
- Unpaid online orders hold ("Dipesan") counted stock for 30 minutes; the number you type is what's left for new customers on top of those.

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
- Customers open it from **Akun → Riwayat pesanan → Lihat semua pesanan** (or `camilanika.github.io/#pesanan`). It lists every order from their account plus orders made on that device without logging in, with filters: Belum dibayar, Diproses, Selesai, Batal.
- Tapping an order opens its page: status, items, discount, ongkir, total, delivery address and map pin, payment method.
- **Unpaid orders** show "Bayar sebelum HH:MM" and a **Lanjutkan pembayaran** button that reopens the same Midtrans payment, even on another phone when logged in. After 30 minutes the order shows as Kedaluwarsa and can't be paid any more.
- Paid orders show **Chat admin untuk pengiriman**; other orders show **Tanya lewat WhatsApp**.
- The page updates by itself while a payment is pending, and the phone's back button works.

## Notifications
- Registered customers open **Akun saya → Notifikasi** (the account button shows a red badge with everything that needs attention). Tapping one opens what it's about: the product on the menu, the promo details, or the order page. "Tandai semua dibaca" clears the counter. Notifications are kept, so they're still there next visit. Guests see a prompt to log in.
- Sent automatically by the database, to everyone registered at that moment:
  - **New product**: once it's visible in the shop (active, in an active submenu). Hiding and showing it again doesn't resend.
  - **New promo**: once it's active and its start time has passed. Each promo has **"Umumkan ke semua pelanggan"** (on by default); untick it for private codes. A promo with a code includes the code in the message.
- Sent only to the customer who owns the order (guest orders have no account, so no notification): order created, paid, Diproses, **Siap diantar**, **Sedang diantar**, Selesai, Dibatalkan, payment failed or expired. A repeated Midtrans notification never sends the same update twice.
- Products and promos that existed before this update are not announced.
- If a product is deleted or a promo has ended, the notification stays but is labelled, and tapping it explains that it's no longer available.

## Order steps in Pesanan
- Each paid order has a button for its next step: **Proses** → **Siap diantar** → **Sedang diantar**, plus **Selesai** and **Batalkan**. Every step notifies the customer.
- **💬 Chat Customer** opens a ready-made message with the order number, delivery address (and map pin), every item with quantity and subtotal, discount, ongkir and total. Edit it if you like, then **Buka WhatsApp** opens a chat with the customer's number and the message filled in; nothing is sent until you press send in WhatsApp. If the number is missing or invalid you'll see a warning and can copy the message instead.

## Akun saya (customer menu)
- **Profile**: Nama, No. WhatsApp, Alamat (edit and save), plus Ganti password.
- **Pesanan**: order history and details. Red badge = unfinished orders (unpaid and not yet expired, paid, Diproses, Siap diantar, Sedang diantar).
- **Notifikasi**: badge = unread notifications.
- **Kode Voucher**: three sections, *Promo* (live promotions), *Voucher Referral* and *Voucher dari Admin*, each with code, discount, minimum, expiry, eligible products and status, plus **Salin kode** and **Pakai** (opens the cart with the code applied). Badge = vouchers the customer can use right now.
- The account button's badge is the sum of the three. Badges refresh on login, every minute, when the page comes back into view, and after paying, reading notifications or using a voucher.

## Referral campaigns (Admin → Referral & Voucher → Kampanye referral)
- A campaign has a **code** (e.g. `CNJUNI26`) you share on WhatsApp / Instagram. **Salin link** copies `camilanika.github.io/?ref=CODE`, which opens sign-up with the code filled in.
- New customers who sign up with an active code get their **own one-time voucher** (`REF-XXXX-XXXX`), shown right after sign-up and kept in Kode Voucher.
- Settings per campaign: start / end, status (Aktif, Dijeda, Berakhir), total voucher quota, daily quota, max vouchers per network (IP), and the voucher: percent or Rupiah, max discount, minimum purchase, products, validity in days.
- **"Voucher aktif: setelah pembayaran pertama"** keeps the voucher pending until the customer's first successful payment, which makes throwaway accounts less useful.
- Invalid, paused, ended, not-yet-started or full codes are refused at sign-up (the customer can fix or clear the code). One referral voucher per account, ever.
- **Pendaftar** lists who signed up, their voucher, its status, and the order it was used on.
- Sign-ups are rate limited per network (**Batas pendaftaran**: default 5 per hour, 20 per day). There's no identity check yet, so one person can still make several accounts with different numbers; a WhatsApp OTP check can be added later (profiles already have a `phone_verified` field for it).

## Vouchers (Admin → Referral & Voucher → Voucher)
- **+ Voucher baru**: a one-time code (typed or generated `CN-XXXX-XXXX`), percent or Rupiah, max discount, minimum, products, expiry, internal note.
- **Assign voucher**: search a customer by name, email, WhatsApp number or user ID, then pick an unassigned voucher or create one on the spot. The customer gets a notification. An assigned voucher only works for that customer.
- **Cabut** revokes a voucher (not possible once used or while an unpaid order holds it). **Riwayat** shows every step: created, assigned, reserved, released, used, revoked.
- Statuses: Menunggu bayar pertama (pending), Tersedia, Dipesan (an unpaid order holds it), Terpakai, Kedaluwarsa, Dicabut.
- Customers type vouchers in the same box as promo codes. The server checks owner, status, expiry, minimum and products, and calculates the discount. A voucher replaces automatic discounts (free gifts still apply). It's held while the order is unpaid, marked **used only when Midtrans confirms payment**, and released if the payment expires, fails or is cancelled. Two orders can't use the same voucher at once.
- Codes are unique across promos, vouchers and referral campaigns.
- Vouchers need online payment; a WhatsApp order that mentions a voucher code isn't checked automatically.
