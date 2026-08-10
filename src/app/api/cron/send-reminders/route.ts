import { NextRequest, NextResponse } from 'next/server';
import { query } from '@/lib/db';
import { sendEmail } from '@/lib/resend';

interface ReminderRow {
  invoice_id: string;
  invoice_number: string;
  total: string;
  due_date: string;
  issue_date: string;
  user_id: string;
  customer_name: string;
  customer_email: string;
  template_id: string;
  subject: string;
  body: string;
  template_name: string;
  user_email: string;
}

export async function GET(req: NextRequest) {
  const authHeader = req.headers.get('authorization');
  if (authHeader !== `Bearer ${process.env.CRON_SECRET}`) {
    return NextResponse.json({ error: 'Unauthorized' }, { status: 401 });
  }

  // Find invoices that need reminders based on active templates
  const reminders = await query<ReminderRow>(
    `SELECT i.id as invoice_id, i.invoice_number, i.total, i.due_date, i.issue_date,
            i.user_id, c.name as customer_name, c.email as customer_email,
            t.id as template_id, t.subject, t.body, t.name as template_name,
            u.email as user_email
     FROM invoices i
     JOIN customers c ON i.customer_id = c.id
     JOIN users u ON i.user_id = u.id
     JOIN reminder_templates t ON t.user_id = i.user_id
     WHERE t.is_active = true
       AND i.status IN ('draft', 'sent')
       AND NOT EXISTS (
         SELECT 1 FROM reminders r
         WHERE r.invoice_id = i.id AND r.template_id = t.id
       )
       AND i.due_date::date = (CURRENT_DATE + t.days_before_due)::date`
  );

  let sent = 0;
  for (const r of reminders) {
    // Replace template variables
    const emailSubject = r.subject
      .replace('{invoice_number}', r.invoice_number)
      .replace('{customer_name}', r.customer_name)
      .replace('{total}', `$${Number(r.total).toFixed(2)}`)
      .replace('{due_date}', r.due_date?.split('T')[0])
      .replace('{issue_date}', r.issue_date?.split('T')[0]);

    const emailBody = r.body
      .replace('{invoice_number}', r.invoice_number)
      .replace('{customer_name}', r.customer_name)
      .replace('{total}', `$${Number(r.total).toFixed(2)}`)
      .replace('{due_date}', r.due_date?.split('T')[0])
      .replace('{issue_date}', r.issue_date?.split('T')[0]);

    try {
      await sendEmail({ to: r.customer_email, subject: emailSubject, html: emailBody });

      await query(
        `INSERT INTO reminders (invoice_id, template_id, reminder_date, status)
         VALUES ($1, $2, NOW(), 'sent')`,
        [r.invoice_id, r.template_id]
      );

      sent++;
    } catch (err) {
      await query(
        `INSERT INTO reminders (invoice_id, template_id, reminder_date, status)
         VALUES ($1, $2, NOW(), 'failed')`,
        [r.invoice_id, r.template_id]
      );
      console.error('Failed to send reminder:', err);
    }
  }

  return NextResponse.json({ sent, total: reminders.length });
}
