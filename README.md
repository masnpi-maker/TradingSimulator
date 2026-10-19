# StockSim

StockSim is a virtual stock trading simulator starter built with React, Vite and Supabase. It never handles real money or sends broker orders. The current repository had no application code or integrations, so this first implementation establishes the app shell, authentication entry point, initial database schema, and server-side market data/order scaffolding.

## Run locally

1. Install Node.js 20 or newer.
2. Run `npm install`.
3. Copy `.env.example` to `.env` and set `VITE_SUPABASE_URL` and `VITE_SUPABASE_ANON_KEY`.
4. Run `npm run dev`.

Without the two Vite variables, the app shows a setup screen. This is intentional; it does not fabricate prices, balances, or trades.

## Supabase setup

Create a Supabase project, then apply `supabase/migrations/001_initial_schema.sql` using the Supabase CLI (`supabase db push`) or SQL editor. Configure Auth email sign-up and redirect URLs for your local site. The migration creates a profile and a virtual account on registration (with an explicitly virtual USD 10,000 starter balance), tables and indexes for simulations, orders, trades, positions, cash transactions, price history, and equity snapshots. It enables RLS and limits client access to reads of owned data; financial ledger writes are routed through security-definer RPCs / server functions.

Add the Edge Function secrets in the Supabase dashboard or CLI:

```sh
supabase secrets set ALPHA_VANTAGE_API_KEY=your_key
```

Deploy functions with `supabase functions deploy search-stocks`, `supabase functions deploy market-data`, and `supabase functions deploy execute-trade`. Supabase supplies `SUPABASE_URL`, `SUPABASE_ANON_KEY`, and `SUPABASE_SERVICE_ROLE_KEY` to functions. Never put the Alpha Vantage key in a `VITE_` variable or commit real keys.

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
