# StockSim

StockSim is a virtual stock trading simulator starter built with React, Vite and Supabase. It never handles real money or sends broker orders. The current repository had no application code or integrations, so this first implementation establishes the app shell, authentication entry point, initial database schema, and server-side market data/order scaffolding.

## Run locally

1. Install Node.js 20 or newer.
2. Run `npm install`.
3. Copy `.env.example` to `.env` and set `VITE_SUPABASE_URL` and `VITE_SUPABASE_ANON_KEY`.
4. Run `npm run dev`.

Without the two Vite variables, the app shows a setup screen. This is intentional; it does not fabricate prices, balances, or trades.

## Supabase setup

Create a Supabase project and apply the schema:

1. Open your project in the Supabase Dashboard.
2. In the left menu, open **SQL Editor** and choose **New query**.
3. Open `supabase/migrations/001_initial_schema.sql` in this repository, copy the entire file, and paste it into the query editor.
4. Click **Run**. The script creates the tables, indexes, RLS policies, and database functions.
5. Configure Auth email sign-up and redirect URLs for your local site.

The schema includes profiles (`username` / registration nickname), virtual accounts and simulation balances, a per-user symbol watchlist, instruments, BUY/SELL orders and executed trades (time, price, quantity), per-simulation positions, cash transactions, price history, and portfolio equity snapshots over time. `positions` and `equity_snapshots` belong to a simulation so multiple portfolios stay separate. On sign-up, the trigger creates a virtual account with USD 10,000; each new simulation separately gets the starting balance selected in the app. RLS limits user data to its owner. Trade and cash balance changes are handled by database functions rather than direct client writes.

The initial schema is intended to run once on a new Supabase project. If you already ran the earlier version of this migration, don't run the whole file again (it contains `CREATE TABLE` statements); use a follow-up migration for the watchlist additions.

### Connect the app

1. Copy `.env.example` to `.env` if you have not already done so.
2. Set `VITE_SUPABASE_URL` to the project's **Project URL** and `VITE_SUPABASE_ANON_KEY` to its public **publishable/anon key** (Project Settings → API Keys). Do not use a `service_role` or secret key in a `VITE_` variable.
3. Save `.env` and restart Vite (`npm run dev`) so it reloads the environment values.
4. In Supabase **Authentication → URL Configuration**, add the local app URL (usually `http://localhost:5173`) to the allowed redirect URLs. If email confirmation is enabled, confirm the registration link before signing in.
5. Configure `ALPHA_VANTAGE_API_KEY` as an Edge Function secret and deploy `search-stocks`, `market-data`, `recent-history`, and `execute-trade` as described above. Search, quotes, recent watchlist charts, and trade execution depend on those functions.

The dashboard, portfolio, trade history, profile, simulations, and watchlist read/write through the signed-in Supabase client under RLS. A portfolio equity chart reads `equity_snapshots`; simulation creation inserts its initial snapshot. To build a continuing history, the app or a scheduled server task must append later snapshots as cash, positions, and market prices change.

Add the Edge Function secrets in the Supabase dashboard or CLI. Keep `ALPHA_VANTAGE_API_KEY` in `supabase/.env.local` (ignored by Git), then upload it to the linked Supabase project:

```sh
supabase secrets set --env-file supabase/.env.local
```

Alternatively, paste the key into **Project Settings → Edge Functions → Secrets** in the Supabase Dashboard. A local `.env` value by itself is not uploaded to Supabase; Edge Functions only receive secrets configured in the remote project.

Deploy functions with `supabase functions deploy search-stocks`, `supabase functions deploy market-data`, `supabase functions deploy recent-history`, and `supabase functions deploy execute-trade`. Supabase supplies `SUPABASE_URL`, `SUPABASE_ANON_KEY`, and `SUPABASE_SERVICE_ROLE_KEY` to functions. Never put the Alpha Vantage key in a `VITE_` variable or commit real keys.

`market-data` and `search-stocks` require a signed-in user. `GLOBAL_QUOTE` reports a trading day rather than a precise intraday timestamp; returned timestamps conservatively use midnight UTC for that date and responses are marked delayed. Orders use a server-fetched quote and reject quote dates older than 36 hours. The SQL applies average cost accounting and a 0.1% simulated fee. The service role is used only inside the trade Edge Function after validating the caller's JWT and simulation ownership.

## Tests and build

Run `npm test` for Vitest tests and `npm run build` for a production build. Test dependencies are configured in `package.json`.

## Implemented and current limits

- The responsive dark dashboard shell, navigation, setup state, Supabase registration/login, logout, and protected authenticated shell are implemented. New live/historical simulation records can be created; live simulations start immediately.
- `001_initial_schema.sql` includes the requested core tables, numeric precision, constraints, indexes, profile bootstrap, RLS policies, virtual deposit/withdrawal RPCs, simulation creation RPC, and an atomic live trade RPC.
- Edge Functions provide authenticated Alpha Vantage symbol search, cached/delayed quote retrieval, and server-side live order validation/execution.
- Market search, delayed quote display, trade confirmation, and BUY/SELL submissions call the authenticated Edge Functions. Simulation creation and listing use the database RPC and RLS-protected reads. The portfolio, transaction history/statistics, profile editing, equity charts, virtual deposit/withdrawal forms, and historical advance/pause lifecycle are not yet implemented. Historical trade execution is deliberately rejected.
- Automated coverage currently contains three unit tests for financial calculations. Authentication, RLS, concurrency, Edge Function API mocks, and browser end-to-end requirements still need tests.
- RLS and database concurrency behavior have not been validated against a live Supabase project in this environment. Alpha Vantage availability depends on the API plan and key. `GLOBAL_QUOTE` is delayed/day-level data, not real-time intraday pricing.
