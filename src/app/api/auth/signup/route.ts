import { NextRequest, NextResponse } from 'next/server';
import { queryOne } from '@/lib/db';
import { signToken, generateId } from '@/lib/auth';
import { sendEmail, welcomeEmail } from '@/lib/resend';
import bcrypt from 'bcryptjs';

function generateCode(): string {
  const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  let code = '';
  for (let i = 0; i < 8; i++) code += chars[Math.floor(Math.random() * chars.length)];
  return code;
}

export async function POST(req: NextRequest) {
  const { name, email, password, company, referralCode } = await req.json();
  if (!email || !password || !name) {
    return NextResponse.json({ error: 'Name, email, and password required' }, { status: 400 });
  }
  const existing = await queryOne('SELECT id FROM users WHERE email = $1', [email]);
  if (existing) {
    return NextResponse.json({ error: 'Email already registered' }, { status: 409 });
  }

  // Resolve referrer
  let referredBy: string | null = null;
  if (referralCode) {
    const referrer = await queryOne<{ id: string }>(
      'SELECT id FROM users WHERE referral_code = $1',
      [referralCode.toUpperCase()]
    );
    if (referrer) {
      referredBy = referrer.id;
    }
  }

  const hashed = await bcrypt.hash(password, 10);
  const id = generateId();
  const myCode = generateCode();

  await queryOne(
    'INSERT INTO users (id, email, name, company, password, referral_code, referred_by) VALUES ($1, $2, $3, $4, $5, $6, $7) RETURNING id, email, name',
    [id, email, name, company || null, hashed, myCode, referredBy]
  );

  if (referredBy) {
    await queryOne(
      'INSERT INTO referrals (referrer_id, referred_id, referral_code, status) VALUES ($1, $2, $3, $4)',
      [referredBy, id, referralCode.toUpperCase(), 'signed_up']
    );
  }

  // Send welcome email (fire-and-forget)
  sendEmail({ to: email, subject: 'Welcome to TradeDesk!', html: welcomeEmail(name) }).catch(() => {});

  const token = await signToken({ userId: id, email });
  return NextResponse.json({ token, user: { id, email, name }, referralCode: myCode });
}
