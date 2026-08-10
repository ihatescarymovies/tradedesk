-- TradeDesk Database Migration
-- Run this against your PostgreSQL database to create all required tables.
-- psql must stop on the explicit dual-table safety exception rather than continue.
\set ON_ERROR_STOP on

CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- Users
CREATE TABLE IF NOT EXISTS users (
  id            TEXT PRIMARY KEY,
  email         TEXT UNIQUE NOT NULL,
  name          TEXT,
  company       TEXT,
  password      TEXT NOT NULL,
  push_token    TEXT,
  push_enabled  BOOLEAN DEFAULT false,
  referral_code    TEXT UNIQUE,
  qb_state         TEXT,
  qb_access_token  TEXT,
  qb_refresh_token TEXT,
  qb_realm_id      TEXT,
  qb_connected_at  TIMESTAMPTZ,
  referred_by      TEXT REFERENCES users(id) ON DELETE SET NULL,
  created_at       TIMESTAMPTZ DEFAULT NOW()
);

-- Subscriptions (Stripe-managed)
CREATE TABLE IF NOT EXISTS subscriptions (
  id                 TEXT PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id            TEXT UNIQUE NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  plan               TEXT NOT NULL DEFAULT 'free',
  status             TEXT NOT NULL DEFAULT 'active',
  stripe_customer_id TEXT,
  created_at         TIMESTAMPTZ DEFAULT NOW(),
  updated_at         TIMESTAMPTZ DEFAULT NOW()
);

-- Customers
CREATE TABLE IF NOT EXISTS customers (
  id            TEXT PRIMARY KEY,
  user_id       TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  name          TEXT NOT NULL,
  email         TEXT,
  phone         TEXT,
  company_name  TEXT,
  address       TEXT,
  created_at    TIMESTAMPTZ DEFAULT NOW(),
  updated_at    TIMESTAMPTZ DEFAULT NOW()
);

-- Invoices
CREATE TABLE IF NOT EXISTS invoices (
  id             TEXT PRIMARY KEY,
  user_id        TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  customer_id    TEXT REFERENCES customers(id) ON DELETE SET NULL,
  invoice_number TEXT NOT NULL,
  issue_date     DATE,
  due_date       DATE,
  subtotal       NUMERIC(12,2) DEFAULT 0,
  tax_rate       NUMERIC(5,2) DEFAULT 0,
  tax_amount     NUMERIC(12,2) DEFAULT 0,
  total          NUMERIC(12,2) DEFAULT 0,
  status         TEXT NOT NULL DEFAULT 'draft',
  notes          TEXT,
  created_at     TIMESTAMPTZ DEFAULT NOW(),
  updated_at     TIMESTAMPTZ DEFAULT NOW()
);

-- Invoice line items
CREATE TABLE IF NOT EXISTS invoice_items (
  id          TEXT PRIMARY KEY DEFAULT gen_random_uuid(),
  invoice_id  TEXT NOT NULL REFERENCES invoices(id) ON DELETE CASCADE,
  description TEXT,
  quantity    NUMERIC(10,2) DEFAULT 1,
  unit_price  NUMERIC(12,2) DEFAULT 0,
  total       NUMERIC(12,2) DEFAULT 0,
  created_at  TIMESTAMPTZ DEFAULT NOW()
);

-- Payments (Stripe + manual)
CREATE TABLE IF NOT EXISTS payments (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  invoice_id  TEXT NOT NULL REFERENCES invoices(id) ON DELETE CASCADE,
  amount      NUMERIC(12,2) NOT NULL,
  method      TEXT NOT NULL DEFAULT 'manual',
  date        TIMESTAMPTZ DEFAULT NOW(),
  reference   TEXT
);

-- Quotes
CREATE TABLE IF NOT EXISTS quotes (
  id            TEXT PRIMARY KEY,
  user_id       TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  customer_id   TEXT REFERENCES customers(id) ON DELETE SET NULL,
  quote_number  TEXT NOT NULL,
  status        TEXT NOT NULL DEFAULT 'draft',
  issue_date    DATE,
  expiry_date   DATE,
  subtotal      NUMERIC(12,2) DEFAULT 0,
  tax_rate      NUMERIC(5,2) DEFAULT 0,
  tax_amount    NUMERIC(12,2) DEFAULT 0,
  total         NUMERIC(12,2) DEFAULT 0,
  notes         TEXT,
  created_at    TIMESTAMPTZ DEFAULT NOW(),
  updated_at    TIMESTAMPTZ DEFAULT NOW()
);

-- Quote line items
CREATE TABLE IF NOT EXISTS quote_items (
  id          TEXT PRIMARY KEY DEFAULT gen_random_uuid(),
  quote_id    TEXT NOT NULL REFERENCES quotes(id) ON DELETE CASCADE,
  description TEXT,
  quantity    NUMERIC(10,2) DEFAULT 1,
  unit_price  NUMERIC(12,2) DEFAULT 0,
  total       NUMERIC(12,2) DEFAULT 0,
  created_at  TIMESTAMPTZ DEFAULT NOW()
);

-- Jobs (field service)
CREATE TABLE IF NOT EXISTS jobs (
  id             TEXT PRIMARY KEY,
  user_id        TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  customer_id    TEXT REFERENCES customers(id) ON DELETE SET NULL,
  title          TEXT NOT NULL,
  description    TEXT,
  status         TEXT NOT NULL DEFAULT 'scheduled',
  scheduled_date TIMESTAMPTZ,
  location       TEXT,
  estimate_amount NUMERIC(12,2),
  final_amount    NUMERIC(12,2),
  notes          TEXT,
  created_at     TIMESTAMPTZ DEFAULT NOW(),
  updated_at     TIMESTAMPTZ DEFAULT NOW()
);

-- Expenses
CREATE TABLE IF NOT EXISTS expenses (
  id          TEXT PRIMARY KEY,
  user_id     TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  category    TEXT,
  vendor      TEXT,
  amount      NUMERIC(12,2) NOT NULL DEFAULT 0,
  date        DATE,
  description TEXT,
  receipt_url TEXT,
  job_id      TEXT REFERENCES jobs(id) ON DELETE SET NULL,
  created_at  TIMESTAMPTZ DEFAULT NOW()
);

-- Compliance documents
CREATE TABLE IF NOT EXISTS compliance_docs (
  id          TEXT PRIMARY KEY,
  user_id     TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  customer_id  TEXT REFERENCES customers(id) ON DELETE SET NULL,
  doc_type    TEXT NOT NULL,
  doc_name    TEXT NOT NULL,
  expiry_date DATE,
  status      TEXT NOT NULL DEFAULT 'active',
  notes       TEXT,
  created_at  TIMESTAMPTZ DEFAULT NOW(),
  updated_at  TIMESTAMPTZ DEFAULT NOW()
);

-- Team members (multi-user support)
CREATE TABLE IF NOT EXISTS team_members (
  id        TEXT PRIMARY KEY,
  owner_id  TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  user_id   TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  role      TEXT NOT NULL DEFAULT 'member',
  created_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(owner_id, user_id)
);

CREATE TABLE IF NOT EXISTS team_invites (
  id        TEXT PRIMARY KEY,
  owner_id  TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  email     TEXT NOT NULL,
  role      TEXT NOT NULL DEFAULT 'member',
  token     TEXT UNIQUE NOT NULL,
  accepted  BOOLEAN DEFAULT false,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Feedback
CREATE TABLE IF NOT EXISTS feedback (
  id          BIGSERIAL PRIMARY KEY,
  user_id     TEXT NOT NULL REFERENCES users(id),
  type        TEXT NOT NULL DEFAULT 'general',
  message     TEXT NOT NULL,
  page        TEXT,
  created_at  TIMESTAMPTZ DEFAULT NOW()
);

-- Reminder templates
-- Canonical table name: reminder_templates (plural). A database containing both
-- names is ambiguous: do not silently strand rows in the legacy table.
DO $$
BEGIN
  IF to_regclass('public.reminder_templates') IS NOT NULL
     AND to_regclass('public.reminder_template') IS NOT NULL THEN
    RAISE EXCEPTION 'Reminder migration stopped: both public.reminder_template and public.reminder_templates exist. Back up and deliberately reconcile/merge the tables, then re-run db/migration.sql.';
  ELSIF to_regclass('public.reminder_templates') IS NULL
        AND to_regclass('public.reminder_template') IS NOT NULL THEN
    ALTER TABLE public.reminder_template RENAME TO reminder_templates;
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS public.reminder_templates (
  id             TEXT PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id        TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  name           TEXT NOT NULL,
  subject        TEXT,
  body           TEXT,
  days_before_due INTEGER DEFAULT 3,
  is_active      BOOLEAN DEFAULT true,
  created_at     TIMESTAMPTZ DEFAULT NOW(),
  updated_at     TIMESTAMPTZ DEFAULT NOW()
);

-- Sent reminders log
CREATE TABLE IF NOT EXISTS reminders (
  id            TEXT PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id       TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  invoice_id    TEXT REFERENCES invoices(id) ON DELETE CASCADE,
  template_id   TEXT REFERENCES reminder_templates(id) ON DELETE SET NULL,
  type          TEXT,
  subject       TEXT,
  body          TEXT,
  sent_at       TIMESTAMPTZ DEFAULT NOW(),
  reminder_date TIMESTAMPTZ DEFAULT NOW(),
  status        TEXT NOT NULL DEFAULT 'sent',
  created_at    TIMESTAMPTZ DEFAULT NOW()
);

-- Referrals tracking
CREATE TABLE IF NOT EXISTS referrals (
  id           TEXT PRIMARY KEY DEFAULT gen_random_uuid(),
  referrer_id  TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  referred_id  TEXT UNIQUE REFERENCES users(id) ON DELETE SET NULL,
  referral_code TEXT NOT NULL,
  status       TEXT NOT NULL DEFAULT 'signed_up',
  reward_sent  BOOLEAN DEFAULT false,
  created_at   TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_referrals_referrer ON referrals(referrer_id);
CREATE INDEX IF NOT EXISTS idx_referrals_code ON referrals(referral_code);

-- Indexes for common queries
CREATE INDEX IF NOT EXISTS idx_invoices_user_id        ON invoices(user_id);
CREATE INDEX IF NOT EXISTS idx_invoices_customer_id   ON invoices(customer_id);
CREATE INDEX IF NOT EXISTS idx_invoices_status         ON invoices(status);
CREATE INDEX IF NOT EXISTS idx_customers_user_id       ON customers(user_id);
CREATE INDEX IF NOT EXISTS idx_jobs_user_id            ON jobs(user_id);
CREATE INDEX IF NOT EXISTS idx_jobs_status             ON jobs(status);
CREATE INDEX IF NOT EXISTS idx_quotes_user_id          ON quotes(user_id);
CREATE INDEX IF NOT EXISTS idx_expenses_user_id       ON expenses(user_id);
CREATE INDEX IF NOT EXISTS idx_compliance_user_id     ON compliance_docs(user_id);
CREATE INDEX IF NOT EXISTS idx_compliance_expiry      ON compliance_docs(expiry_date);
CREATE INDEX IF NOT EXISTS idx_payments_invoice_id   ON payments(invoice_id);
CREATE INDEX IF NOT EXISTS idx_reminders_user_id      ON reminders(user_id);
CREATE INDEX IF NOT EXISTS idx_subscriptions_user_id  ON subscriptions(user_id);
CREATE INDEX IF NOT EXISTS idx_subscriptions_stripe   ON subscriptions(stripe_customer_id);

-- Recurring invoices
CREATE TABLE IF NOT EXISTS recurring_invoices (
  id TEXT PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  customer_id TEXT NOT NULL REFERENCES customers(id) ON DELETE CASCADE,
  invoice_number_prefix TEXT NOT NULL DEFAULT 'INV',
  frequency TEXT NOT NULL DEFAULT 'monthly',
  day_of_month INTEGER NOT NULL DEFAULT 1,
  start_date DATE NOT NULL,
  end_date DATE,
  tax_rate NUMERIC(5,2) DEFAULT 0,
  notes TEXT,
  last_generated DATE,
  is_active BOOLEAN DEFAULT true,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS recurring_invoice_items (
  id TEXT PRIMARY KEY DEFAULT gen_random_uuid(),
  recurring_invoice_id TEXT NOT NULL REFERENCES recurring_invoices(id) ON DELETE CASCADE,
  description TEXT NOT NULL,
  quantity NUMERIC(10,2) NOT NULL DEFAULT 1,
  unit_price NUMERIC(12,2) NOT NULL DEFAULT 0
);

CREATE INDEX IF NOT EXISTS idx_recurring_invoices_user_id ON recurring_invoices(user_id);
CREATE INDEX IF NOT EXISTS idx_recurring_invoices_active ON recurring_invoices(is_active);

-- Company settings (add columns to users)
ALTER TABLE users ADD COLUMN IF NOT EXISTS company_address TEXT;
ALTER TABLE users ADD COLUMN IF NOT EXISTS company_city TEXT;
ALTER TABLE users ADD COLUMN IF NOT EXISTS company_state TEXT;
ALTER TABLE users ADD COLUMN IF NOT EXISTS company_zip TEXT;
ALTER TABLE users ADD COLUMN IF NOT EXISTS company_country TEXT DEFAULT 'US';
ALTER TABLE users ADD COLUMN IF NOT EXISTS tax_id TEXT;
ALTER TABLE users ADD COLUMN IF NOT EXISTS logo_url TEXT;
ALTER TABLE users ADD COLUMN IF NOT EXISTS phone TEXT;
ALTER TABLE users ADD COLUMN IF NOT EXISTS onboarding_completed BOOLEAN DEFAULT false;
