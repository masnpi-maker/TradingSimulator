import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { corsHeaders, errorMessage, json } from '../_shared/http.ts'

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  if (req.method !== 'POST') return json({ error: 'Method not allowed' }, 405)
  const token = req.headers.get('Authorization')
  if (!token) return json({ error: 'Authentication required' }, 401)
  const apiKey = Deno.env.get('ALPHA_VANTAGE_API_KEY')
  if (!apiKey) return json({ error: 'Market data provider is not configured' }, 503)
  const userClient = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_ANON_KEY')!, { global: { headers: { Authorization: token } } })
  const { data: { user }, error: authError } = await userClient.auth.getUser()
  if (authError || !user) return json({ error: 'Invalid session' }, 401)
  const admin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!)
  try {
    const { symbol: rawSymbol, refresh = false } = await req.json()
    const symbol = String(rawSymbol ?? '').trim().toUpperCase()
    if (!/^[A-Z0-9.-]{1,15}$/.test(symbol)) return json({ error: 'Invalid symbol' }, 400)
    const { data: instrument } = await admin.from('instruments').select('id').eq('symbol', symbol).maybeSingle()
    let cached: Record<string, unknown> | null = null
    if (instrument) {
      const { data } = await admin.from('price_history').select('price_timestamp,close,source,fetched_at').eq('instrument_id', instrument.id).eq('interval', 'global_quote').order('price_timestamp', { ascending: false }).limit(1).maybeSingle()
      cached = data
    }
    const cachedPriceStale = !cached || Date.now() - new Date(String(cached.price_timestamp)).getTime() > 36 * 60 * 60 * 1000
    const cacheFresh = cached && Date.now() - new Date(String(cached.fetched_at)).getTime() < 15 * 60 * 1000
    if (cacheFresh && !refresh && !cachedPriceStale) return json({ symbol, price: cached.close, timestamp: cached.price_timestamp, source: cached.source, fetched_at: cached.fetched_at, stale: false, delayed: true })
    const url = new URL('https://www.alphavantage.co/query')
    url.searchParams.set('function', 'GLOBAL_QUOTE'); url.searchParams.set('symbol', symbol); url.searchParams.set('apikey', apiKey)
    const response = await fetch(url, { signal: AbortSignal.timeout(10000) })
    if (!response.ok) throw new Error('Market provider request failed')
    const payload = await response.json()
    if (payload.Note || payload.Information) return cached ? json({ symbol, price: cached.close, timestamp: cached.price_timestamp, source: cached.source, fetched_at: cached.fetched_at, stale: true, delayed: true }) : json({ error: 'Market provider request limit reached' }, 429)
    const quote = payload['Global Quote']
    if (!quote?.['05. price'] || !quote?.['07. latest trading day']) return cached ? json({ symbol, price: cached.close, timestamp: cached.price_timestamp, source: cached.source, fetched_at: cached.fetched_at, stale: true, delayed: true }) : json({ error: 'No quote available' }, 404)
    const close = Number(quote['05. price'])
    const tradingDay = quote['07. latest trading day']
    if (!Number.isFinite(close) || close <= 0) return json({ error: 'Invalid quote returned by provider' }, 502)
    // GLOBAL_QUOTE exposes only a trading date. Use midnight UTC as a
    // conservative timestamp and label the result delayed.
    const priceTimestamp = new Date(`${tradingDay}T00:00:00.000Z`).toISOString()
    let { data: instr } = await admin.from('instruments').upsert({ symbol, name: symbol }, { onConflict: 'symbol' }).select('id').single()
    if (instr) await admin.from('price_history').upsert({ instrument_id: instr.id, interval: 'global_quote', price_timestamp: priceTimestamp, close, source: 'Alpha Vantage GLOBAL_QUOTE', fetched_at: new Date().toISOString() }, { onConflict: 'instrument_id,interval,price_timestamp' })
    return json({ symbol, price: close, timestamp: priceTimestamp, source: 'Alpha Vantage GLOBAL_QUOTE', fetched_at: new Date().toISOString(), stale: Date.now() - new Date(priceTimestamp).getTime() > 36 * 60 * 60 * 1000, delayed: true })
  } catch (error) { return json({ error: errorMessage(error) }, 502) }
})
