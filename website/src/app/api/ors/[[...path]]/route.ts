import { NextRequest, NextResponse } from 'next/server';

const ORS_ORIGIN = 'https://api.openrouteservice.org';

/**
 * Proxy to OpenRouteService / HeiGIT API.
 * Key is added server-side only (HEIGIT_API_KEY) so the client never sends it.
 * App sends POST to /api/ors/v2/... with same body as ORS; we forward and return the response.
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
  const url = `${ORS_ORIGIN}${orsPath}`;

  let body: string | undefined;
  try {
    body = await request.text();
  } catch {
    return NextResponse.json({ error: 'Invalid request body' }, { status: 400 });
  }

  const res = await fetch(url, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'Authorization': key.trim(),
    },
    body: body || undefined,
  });

  const data = await res.text();
  const contentType = res.headers.get('content-type') || 'application/json';

  return new NextResponse(data, {
    status: res.status,
    headers: {
      'Content-Type': contentType,
    },
  });
}
