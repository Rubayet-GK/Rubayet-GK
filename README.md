# ChuriStock — Bangles Inventory & Reservation System

Vercel-ready Next.js + Supabase dashboard for Bangles **Design → Colour → Size** variants, shared across admins and moderators.

## Features
- Staff email/password authentication (Supabase Auth)
- Roles: **admin** (add designs, variants, adjust stock, orders), **moderator** (orders, inventory)
- One order contains multiple different variants and quantities
- **Reserved order** increases `reserved` but not `on_hand`; available = on_hand - reserved
- **Cancelled order** releases reserved stock
- **Completed order** decreases both on-hand and reserved stock
- Atomic PostgreSQL RPC functions, row locks, RLS, stock-movement audit trail
- Low-stock dashboard and orders listing; 12-second polling for shared state

## Quick setup (Supabase)
1. Create a new project at https://supabase.com and wait for its database.
2. In Supabase **SQL Editor**, paste/run all of `supabase/schema.sql` on a **fresh project**. It creates database tables, role policies, and transaction functions.
3. Supabase Authentication → Users → **Add user** (create an admin's email/password). Ensure the user is confirmed. A trigger will create a moderator profile for every new user.
4. In SQL Editor, promote your admin (replace the email):

   ```sql
   update public.profiles set role='admin'
   where id=(select id from auth.users where email='you@example.com');
   ```

5. Add each moderator in Authentication → Users → Add user. They will receive `moderator` role automatically. Disable public signups if you want invitation-only staff access. Never share the admin password.
6. Copy `.env.example` to `.env.local`. Set your Supabase Project URL and **publishable/anon key** (NOT service_role/secret key). These are found in Supabase Project Settings → API / Connect.

## Run locally

```bash
npm install
npm run dev
```

Visit http://localhost:3000. Sign in as admin, add a design, add its individual colour/size variants, then add stock. Test moderator orders.

## Deploy to Vercel
1. Extract the ZIP, push the folder to a **private GitHub repository**.
2. Vercel → Add New → Project → Import repository.
3. Framework should auto-detect **Next.js**. Add environment variables:
   - `NEXT_PUBLIC_SUPABASE_URL`
   - `NEXT_PUBLIC_SUPABASE_ANON_KEY`
4. Deploy. Use the generated `.vercel.app` address. All moderators share the same Supabase database.

## Stock example

A variant (Royal Design / Red / Size 2.4) starts with `on_hand=30, reserved=0`, so available 30.
- Moderator A creates an order for 2: `on_hand=30, reserved=2`, available 28.
- Moderator B can only reserve from remaining 28.
- A cancels: `on_hand=30, reserved=0`, available 30.
- Alternatively, A completes: `on_hand=28, reserved=0`, available 28.

The database locks each variant record during reservation so concurrent moderators cannot over-reserve it. Duplicate variants in one order are rejected, and order status is terminal after completion/cancellation.

## Notes and limits
- This is an operational **starter MVP**, not audited production software. Test all flows and access controls before entering real customer data.
- Stock reservation is immediate. There is **no automatic reservation expiry** or payment gateway.
- Stock numbers are live from Supabase but the UI **polls every 12 seconds**, so another moderator's change may take up to 12 seconds to appear. The database still rechecks stock on every order.
- Order-list view displays the **latest 200 orders**; add pagination for large stores.
- Inventory is tracked in **pieces**, not pairs or sets; update data model if your sales units differ.
- Orders cannot be edited after creation; cancel and recreate instead. Completed orders aren't reversible in this starter.
- Supabase never receives a service-role key from client code. SQL functions verify the logged-in user's role.
- Deploying to Vercel alone does NOT create the database or staff accounts; complete the Supabase setup first.
