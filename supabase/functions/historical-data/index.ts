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
    const { simulation_id, symbol: rawSymbol } = await req.json()
    const symbol = String(rawSymbol ?? '').trim().toUpperCase()
    if (!/^[0-9a-f-]{36}$/i.test(String(simulation_id)) || !/^[A-Z0-9.-]{1,15}$/.test(symbol)) return json({ error: 'Invalid parameters' }, 400)
    const admin = createClient(url, key)
    const { data: sim } = await admin.from('simulations').select('id,mode,start_date,end_date').eq('id', simulation_id).eq('user_id', user.id).maybeSingle()
    if (!sim || sim.mode !== 'historical') return json({ error: 'Historical simulation not found' }, 404)
    const api = new URL('https://www.alphavantage.co/query')
    const daysFromStart = (Date.now() - Date.parse(`${sim.start_date}T00:00:00Z`)) / 86400000
    api.searchParams.set('function', 'TIME_SERIES_DAILY'); api.searchParams.set('symbol', symbol); api.searchParams.set('outputsize', daysFromStart <= 180 ? 'compact' : 'full'); api.searchParams.set('apikey', apiKey)
    const response = await fetch(api, { signal: AbortSignal.timeout(20000) })
    if (!response.ok) return json({ error: 'Market provider unavailable' }, 502)
    let payload = await response.json()
    if (payload.Note) return json({ error: 'Alpha Vantage užklausų limitas pasiektas. Palaukite ir bandykite dar kartą.' }, 429)
    if (payload.Information) {
      const info = String(payload.Information).toLowerCase()
      if (info.includes('premium') || info.includes('full')) {
        api.searchParams.set('outputsize', 'compact')
        const compactResponse = await fetch(api, { signal: AbortSignal.timeout(20000) })
        if (!compactResponse.ok) return json({ error: 'Market provider unavailable' }, 502)
        payload = await compactResponse.json()
        if (payload.Note) return json({ error: 'Alpha Vantage užklausų limitas pasiektas. Palaukite ir bandykite dar kartą.' }, 429)
      }
      if (payload.Information) return json({ error: 'Alpha Vantage negrąžino istorinių kainų. Patikrinkite API rakto planą ir bandykite vėliau.' }, 429)
    }
    const series = payload['Time Series (Daily)']
    if (!series) return json({ error: payload['Error Message'] || 'No daily price history available' }, 404)
    const { data: instrument, error: instrumentError } = await admin.from('instruments').upsert({ symbol, name: symbol }, { onConflict: 'symbol' }).select('id').single()
    if (instrumentError) throw instrumentError
    const bars = Object.entries(series).filter(([date]) => date >= sim.start_date && date <= sim.end_date).map(([date, values]: [string, any]) => ({
      instrument_id: instrument.id, interval: 'daily', price_timestamp: `${date}T00:00:00.000Z`, open: Number(values['1. open']), high: Number(values['2. high']), low: Number(values['3. low']), close: Number(values['4. close']), volume: Number(values['5. volume']), source: 'Alpha Vantage TIME_SERIES_DAILY', fetched_at: new Date().toISOString(),
    })).filter(bar => Number.isFinite(bar.close) && bar.close > 0)
    if (!bars.length) return json({ error: 'Alpha Vantage grąžintoje istorijoje nėra kainų pasirinktam laikotarpiui. Nemokamas planas pateikia tik paskutines 100 prekybos dienų; pasirinkite naujesnes datas arba naudokite Premium raktą.' }, 422)
    for (let i = 0; i < bars.length; i += 500) {
      const { error: saveError } = await admin.from('price_history').upsert(bars.slice(i, i + 500), { onConflict: 'instrument_id,interval,price_timestamp' })
      if (saveError) throw saveError
    }
    return json({ symbol, bars_saved: bars.length, start_date: sim.start_date, end_date: sim.end_date, source: 'Alpha Vantage TIME_SERIES_DAILY' })
  } catch (error) { return json({ error: errorMessage(error) }, 400) }
})
