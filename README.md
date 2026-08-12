# TradeDesk

A simple business management tool for tradespeople and small service businesses. Customers, invoices, quotes, expenses, field service, compliance tracking, and automated reminders — all in one place.

## Features

- **Dashboard** — Overview of revenue, outstanding invoices, active jobs, upcoming compliance expiries
- **Customers** — Contact management with company details
- **Invoices** — Create, send, and track invoices with online payment links
- **Quotes** — Generate and send quotes that convert to invoices
- **Field Service** — Job scheduling, status tracking, location notes
- **Expenses** — Categorize spending by job or vendor
- **Compliance** — Track license and certificate expiry dates
- **Reminders** — Automated email reminders for overdue invoices
- **Reports** — Revenue, expense, and profitability breakdowns
- **Mobile** — React Native app for on-the-go access

## Tech Stack

- **Framework:** Next.js 16 (App Router)
- **Database:** PostgreSQL
- **Auth:** JWT sessions (bcrypt + jose)
- **Payments:** Stripe
- **Email:** Resend
- **Mobile:** Expo / React Native
- **Deployment:** Vercel

## Getting Started

### Prerequisites

- Node.js 20+
- pnpm (recommended) or npm
- PostgreSQL database
- Stripe account
- Resend account (for transactional email)

### Installation

```bash
# Clone the repo
git clone https://github.com/daggerstuff/tradedesk.git
cd tradedesk

# Install dependencies
pnpm install

# Set up environment variables
cp .env.example .env.local
# Fill in your values in .env.local

# Run the database migration
psql $DATABASE_URL < db/migration.sql

# Start dev server
pnpm run dev
```

Visit `http://localhost:3000`.

## Local verification gates

Two tracked scripts provide repeatable pre-merge gates. Run both from the repo root.

### `pnpm run verify:build` — build health gate

Verifies the **committed tree (HEAD)** in a clean disposable copy (uncommitted changes are not tested):

1. `pnpm install --frozen-lockfile` — content store on root-backed storage; the pnpm *virtual* store stays inside the project (`node_modules/.pnpm`), which Next 16/Turbopack requires
2. `pnpm exec tsc --noEmit`
3. `pnpm run build`
4. Landing-route smoke — `next start` on an ephemeral port, `GET /` must return `200`

The working copy is created under `/tmp` (root-backed) via `git archive` and removed on exit, so the gate works even when `/home` is capacity-constrained. Environment overrides: `VERIFY_TMPDIR`, `PNPM_STORE_DIR` (default `/tmp/tradedesk-pnpm-store`, reused across runs to keep re-installs fast), `VERIFY_PORT`, `KEEP_WORK=1` (keep the copy/log for inspection).

### `pnpm run verify:migration` — migration-contract regression gate

Runs the **working-tree** `db/migration.sql` against disposable local PostgreSQL databases (dropped on exit — only databases this run created are ever dropped; a pre-existing name aborts the run instead of being deleted) and asserts the reminder-template canonicalization contract:

1. Fresh install completes under a non-default `search_path` and creates `public.reminder_templates`
2. Strict custom-`search_path` (public absent) legacy upgrade completes — the contract restored by PR #2 (`f0a7b42`, qualify `reminders.template_id` FK as `public.reminder_templates`) — preserving the legacy row and FKs, with `reminders.template_id` referencing `public.reminder_templates`
3. Canonical re-run is idempotent (rc=0, no duplicated rows)
4. Dual-table state (both `reminder_template` and `reminder_templates` present) aborts with the explicit "both … exist" safety exception and strands no data

Prerequisite: a local PostgreSQL server reachable as the postgres superuser via passwordless `sudo -u postgres`. Install/start on Ubuntu:

```bash
sudo apt-get update && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y postgresql postgresql-client
sudo pg_ctlcluster 16 main start
```

The script fails with these instructions if the tools or a live server are unavailable — it never installs anything (it will attempt a one-time cluster start if one is installed but down). Overrides: `MIGRATION_FILE`, `WORK_DIR` (base directory for scratch logs — a unique child scratch dir is created under it per run and removed on exit, so concurrent runs never share a dir and the base itself is never deleted), `KEEP_WORK=1`.

> **Out of scope for both gates:** the reminder-cron handler (`src/app/api/cron/send-reminders/route.ts`) inserts into `reminders` without the NOT NULL `user_id` column. That runtime defect is tracked separately and is not claimed fixed by these gates.

## Environment Variables

See `.env.example` for the complete setup contract. Reminder templates use the canonical `reminder_templates` table; the migration safely renames the earlier singular table when upgrading an existing database. If both `reminder_template` and `reminder_templates` already exist, the migration stops before continuing: back up the database, deliberately reconcile/merge the two tables, then re-run the migration.

| Variable | Description |
|----------|-------------|
| `DATABASE_URL` | PostgreSQL connection string |
| `JWT_SECRET` | Secret key for signing session JWTs |
| `NEXT_PUBLIC_APP_URL` | Public URL of the app |
| `STRIPE_SECRET_KEY` | Stripe secret key |
| `STRIPE_WEBHOOK_SECRET` | Stripe webhook signing secret |
| `STRIPE_PRICE_*` | Stripe price IDs for each plan |
| `RESEND_API_KEY` | Resend API key for email |
| `CRON_SECRET` | Secret for authenticating cron job requests |

## Deployment

### Vercel

```bash
vercel deploy
```

Cron jobs are configured in `vercel.json`:
- Daily at 9 AM UTC — Invoice reminders
- Daily at 8 AM UTC — Compliance expiry checks

### Database Migration

After deploying, back up the database and run the migration:

```bash
pg_dump "$DATABASE_URL" > tradedesk-pre-migration.sql
psql "$DATABASE_URL" < db/migration.sql
```

The migration preserves the canonical `reminder_templates` name and upgrades a legacy-singular-only database by renaming `reminder_template`. If it reports that both `reminder_template` and `reminder_templates` exist, stop: back up the database, deliberately reconcile/merge the two tables (including dependent foreign keys and any duplicate/conflicting rows), then re-run `db/migration.sql`. It will not choose a table or discard data automatically.

## License

MIT
