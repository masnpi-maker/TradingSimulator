import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { corsHeaders, errorMessage, json } from '../_shared/http.ts'

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  if (req.method !== 'POST') return json({ error: 'Method not allowed' }, 405)
  const token = req.headers.get('Authorization')
  if (!token) return json({ error: 'Authentication required' }, 401)
  const url = Deno.env.get('SUPABASE_URL')!, anon = Deno.env.get('SUPABASE_ANON_KEY')!, key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, apiKey = Deno.env.get('ALPHA_VANTAGE_API_KEY')
  if (!apiKey) return json({ error: 'Market data provider is not configured' }, 503)
  const auth = createClient(url, anon, { global: { headers: { Authorization: token } } })
  const { data: { user }, error } = await auth.auth.getUser()
  if (error || !user) return json({ error: 'Invalid session' }, 401)
  try {
    const { symbol: rawSymbol } = await req.json()
    const symbol = String(rawSymbol ?? '').trim().toUpperCase()
    if (!/^[A-Z0-9.-]{1,15}$/.test(symbol)) return json({ error: 'Invalid symbol' }, 400)
    const admin = createClient(url, key)
    const { data: instrument, error: instrumentError } = await admin.from('instruments').select('id').eq('symbol', symbol).maybeSingle()
    if (instrumentError || !instrument) return json({ error: 'Stebimo simbolio nepavyko rasti.' }, 404)
    const startDate = new Date(Date.now() - 30 * 86400000).toISOString().slice(0, 10)
    const api = new URL('https://www.alphavantage.co/query')
    api.searchParams.set('function', 'TIME_SERIES_DAILY')
    api.searchParams.set('symbol', symbol)
    api.searchParams.set('outputsize', 'compact')
    api.searchParams.set('apikey', apiKey)
    const response = await fetch(api, { signal: AbortSignal.timeout(20000) })
    if (!response.ok) return json({ error: 'Rinkos duomenų teikėjas nepasiekiamas.' }, 502)
    const payload = await response.json()
    if (payload.Note || payload.Information) return json({ error: 'Alpha Vantage užklausų limitas pasiektas. Pabandykite vėliau.' }, 429)
    const series = payload['Time Series (Daily)']
    if (!series) return json({ error: payload['Error Message'] || 'Istorinių kainų gauti nepavyko.' }, 404)
    const bars = Object.entries(series)
      .filter(([date]) => date >= startDate)
      .map(([date, values]: [string, any]) => ({
        instrument_id: instrument.id,
        interval: 'daily',
        price_timestamp: `${date}T00:00:00.000Z`,
        open: Number(values['1. open']),
        high: Number(values['2. high']),
        low: Number(values['3. low']),
        close: Number(values['4. close']),
        volume: Number(values['5. volume']),
        source: 'Alpha Vantage TIME_SERIES_DAILY',
        fetched_at: new Date().toISOString(),
      }))
      .filter(bar => Number.isFinite(bar.close) && bar.close > 0)
    if (!bars.length) return json({ error: 'Per paskutines 30 dienų kainų duomenų nerasta.' }, 404)
    const { error: saveError } = await admin.from('price_history').upsert(bars, { onConflict: 'instrument_id,interval,price_timestamp' })
    if (saveError) throw saveError
    return json({ symbol, start_date: `${startDate}T00:00:00.000Z`, bars_saved: bars.length, source: 'Alpha Vantage TIME_SERIES_DAILY' })
  } catch (error) { return json({ error: errorMessage(error) }, 400) }
})
