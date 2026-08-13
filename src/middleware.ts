import { NextRequest, NextResponse } from 'next/server';
import { jwtVerify } from 'jose';

const COOKIE_NAME = 'td_session';
// Paths reachable without a session cookie. Auth routes self-authenticate
// (password/magic-link), cron routes use Bearer CRON_SECRET, and /pay +
// /api/stripe/invoice-checkout serve the public invoice payment journey.
const PUBLIC_PATHS = [
  '/',
  '/login',
  '/signup',
  '/pricing',
  '/pay',
  '/api/auth',
  '/api/cron',
  '/api/stripe/invoice-checkout',
  '/api/webhooks',
];

export async function middleware(req: NextRequest) {
  const { pathname } = req.nextUrl;

  // Allow public paths
  if (PUBLIC_PATHS.some((p) => pathname === p || pathname.startsWith(p + '/')) || pathname.startsWith('/api/webhooks/')) {
    return NextResponse.next();
  }

  // Allow static assets
  if (pathname.startsWith('/_next') || pathname.startsWith('/favicon')) {
    return NextResponse.next();
  }

  const token = req.cookies.get(COOKIE_NAME)?.value;
  if (!token) {
    const loginUrl = new URL('/login', req.url);
    return NextResponse.redirect(loginUrl);
  }

  try {
    const secret = new TextEncoder().encode(process.env.JWT_SECRET || 'dev-secret-change-me');
    await jwtVerify(token, secret);
    return NextResponse.next();
  } catch {
    const loginUrl = new URL('/login', req.url);
    loginUrl.searchParams.set('error', 'session_expired');
    return NextResponse.redirect(loginUrl);
  }
}

export const config = {
  matcher: ['/((?!_next/static|_next/image|favicon.ico).*)'],
};
