import { NextRequest, NextResponse } from 'next/server';
import { query } from '@/lib/db';
import { getSession } from '@/lib/session';
import { generateId } from '@/lib/auth';
import { checkLimit } from '@/lib/billing';

export async function GET() {
  const session = await getSession();
  if (!session) return NextResponse.json({ error: 'Unauthorized' }, { status: 401 });

  const invoices = await query(
    `SELECT i.*, c.name as customer_name
     FROM invoices i
     LEFT JOIN customers c ON i.customer_id = c.id
     WHERE i.user_id = $1
     ORDER BY i.created_at DESC`,
    [session.userId]
  );

  return NextResponse.json({ invoices });
}

export async function POST(req: NextRequest) {
  const session = await getSession();
  if (!session) return NextResponse.json({ error: 'Unauthorized' }, { status: 401 });

  const check = await checkLimit(session.userId, 'invoices');
  if (!check.allowed) {
    return NextResponse.json({ error: `Plan limit reached (${check.current}/${check.limit} invoices/month). Upgrade for more.` }, { status: 403 });
  }

  const body = await req.json();
  const { customerId, invoiceNumber, issueDate, dueDate, items, notes, taxRate } = body;

  if (!customerId || !invoiceNumber || !issueDate || !dueDate || !items?.length) {
    return NextResponse.json({ error: 'Missing required fields' }, { status: 400 });
  }

  const subtotal = items.reduce((sum: number, item: { quantity: number; unitPrice: number }) => 
    sum + item.quantity * item.unitPrice, 0);
  const taxAmount = subtotal * (taxRate || 0) / 100;
  const total = subtotal + taxAmount;
  const id = generateId('inv');

  const result = await query(
    `INSERT INTO invoices (id, user_id, customer_id, invoice_number, issue_date, due_date, subtotal, tax_rate, tax_amount, total, status, notes)
     VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, 'draft', $11)
     RETURNING *`,
    [id, session.userId, customerId, invoiceNumber, issueDate, dueDate, subtotal, taxRate || 0, taxAmount, total, notes || null]
  );

  const invoice = result[0];

  for (const item of items) {
    await query(
      `INSERT INTO invoice_items (invoice_id, description, quantity, unit_price, total)
       VALUES ($1, $2, $3, $4, $5)`,
      [invoice.id, item.description, item.quantity, item.unitPrice, item.quantity * item.unitPrice]
    );
  }

  return NextResponse.json({ invoice }, { status: 201 });
}
