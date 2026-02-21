import { NextRequest, NextResponse } from 'next/server';

const ORS_ORIGIN = 'https://api.openrouteservice.org';

/** Allow up to 25s for ORS to respond (helps with client retries; Vercel free tier function limit is 10s). */
const FETCH_TIMEOUT_MS = 25_000;

/**
 * GET /api/ors or /api/ors/warm – keep-warm endpoint for cron.
 * Hit every 5–10 min to reduce cold starts. Returns 200.
 */
export async function GET(
  _request: NextRequest,
  context: { params: Promise<{ path?: string[] }> }
) {
  const { path = [] } = await context.params;
  const segment = path[0];
  if (segment === undefined || segment === 'warm') {
    return NextResponse.json({ ok: true, message: 'ORS proxy warm' }, { status: 200 });
  }
  return NextResponse.json({ error: 'Not found' }, { status: 404 });
}

/**
 * Proxy to OpenRouteService / HeiGIT API.
 * Key is added server-side only (HEIGIT_API_KEY) so the client never sends it.
 * App sends POST to /api/ors/v2/... or /api/ors/pois with same body as ORS; we forward and return the response.
 * Uses a timeout so the client can retry instead of hanging.
 */
export async function POST(
  request: NextRequest,
  context: { params: Promise<{ path?: string[] }> }
) {
  const key = process.env.HEIGIT_API_KEY;
  if (!key || key.trim() === '') {
    return NextResponse.json(
      { error: 'ORS proxy: HEIGIT_API_KEY not configured' },
      { status: 503 }
    );
  }

  const { path = [] } = await context.params;
  const orsPath = '/' + path.join('/');
  // POI (openpoiservice) may expect api_key in query; keep Authorization header as well for compatibility
  const isPois = path[0] === 'pois';
  const url = isPois
    ? `${ORS_ORIGIN}${orsPath}?api_key=${encodeURIComponent(key.trim())}`
    : `${ORS_ORIGIN}${orsPath}`;

  let body: string | undefined;
  try {
    body = await request.text();
  } catch {
    return NextResponse.json({ error: 'Invalid request body' }, { status: 400 });
  }

  const controller = new AbortController();
  const timeoutId = setTimeout(() => controller.abort(), FETCH_TIMEOUT_MS);

  let res: Response;
  try {
    res = await fetch(url, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': key.trim(),
      },
      body: body || undefined,
      signal: controller.signal,
    });
  } catch (err) {
    clearTimeout(timeoutId);
    const message = err instanceof Error && err.name === 'AbortError'
      ? 'ORS proxy: upstream timeout'
      : err instanceof Error ? err.message : 'Unknown error';
    return NextResponse.json({ error: message }, { status: 504 });
  }
  clearTimeout(timeoutId);

  const data = await res.text();
  const contentType = res.headers.get('content-type') || 'application/json';

  return new NextResponse(data, {
    status: res.status,
    headers: {
      'Content-Type': contentType,
    },
  });
}
