import { NextRequest, NextResponse } from 'next/server';
import { query } from '@/lib/db';
import { getSession } from '@/lib/session';

export async function PUT(req: NextRequest, { params }: { params: Promise<{ id: string }> }) {
  const session = await getSession();
  if (!session) return NextResponse.json({ error: 'Unauthorized' }, { status: 401 });

  const { id } = await params;
  const body = await req.json();

  const updates: string[] = [];
  const values: (string | number | boolean | null)[] = [];
  let paramIdx = 2;

  for (const [key, value] of Object.entries(body)) {
    if (['name', 'subject', 'body', 'days_before_due', 'is_active'].includes(key)) {
      updates.push(`${key} = $${paramIdx}`);
      values.push(value as string | number | boolean | null);
      paramIdx++;
    }
  }

  if (!updates.length) {
    return NextResponse.json({ error: 'No valid fields to update' }, { status: 400 });
  }

  updates.push('updated_at = NOW()');

  const result = await query(
    `UPDATE reminder_templates SET ${updates.join(', ')}
     WHERE id = $1 AND user_id = $${paramIdx}
     RETURNING *`,
    [id, ...values, session.userId]
  );

  if (!result.length) return NextResponse.json({ error: 'Not found' }, { status: 404 });

  return NextResponse.json({ template: result[0] });
}

export async function DELETE(req: NextRequest, { params }: { params: Promise<{ id: string }> }) {
  const session = await getSession();
  if (!session) return NextResponse.json({ error: 'Unauthorized' }, { status: 401 });

  const { id } = await params;

  const result = await query(
    'DELETE FROM reminder_templates WHERE id = $1 AND user_id = $2 RETURNING id',
    [id, session.userId]
  );

  if (!result.length) return NextResponse.json({ error: 'Not found' }, { status: 404 });

  return NextResponse.json({ success: true });
}
