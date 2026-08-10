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
