import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { corsHeaders, errorMessage, json } from '../_shared/http.ts'

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  if (req.method !== 'POST') return json({ error: 'Method not allowed' }, 405)
  const token = req.headers.get('Authorization')
  if (!token) return json({ error: 'Authentication required' }, 401)
  const url = Deno.env.get('SUPABASE_URL')!, anon = Deno.env.get('SUPABASE_ANON_KEY')!, key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, marketKey = Deno.env.get('ALPHA_VANTAGE_API_KEY')
  if (!marketKey) return json({ error: 'Market data provider is not configured' }, 503)
  const auth = createClient(url, anon, { global: { headers: { Authorization: token } } })
  const { data: { user }, error: authError } = await auth.auth.getUser()
  if (authError || !user) return json({ error: 'Invalid session' }, 401)
  try {
    const body = await req.json()
    const simulation_id = String(body.simulation_id ?? '')
    const symbol = String(body.symbol ?? '').trim().toUpperCase()
    const side = String(body.side ?? '').toLowerCase()
    const quantity = Number(body.quantity)
    const request_key = String(body.request_key ?? '')
    if (!/^[0-9a-f-]{36}$/i.test(simulation_id) || !/^[A-Z0-9.-]{1,15}$/.test(symbol) || !['buy','sell'].includes(side) || !Number.isFinite(quantity) || quantity <= 0 || quantity > 100000000 || !/^[0-9a-f-]{36}$/i.test(request_key)) return json({ error: 'Invalid order parameters' }, 400)
    const admin = createClient(url, key)
    const { data: simulation, error } = await admin.from('simulations').select('id,mode,status').eq('id', simulation_id).eq('user_id', user.id).maybeSingle()
    if (error || !simulation) return json({ error: 'Simulation not found' }, 404)
    if (simulation.mode !== 'live') return json({ error: 'Historical trading is not enabled yet' }, 409)
    const api = new URL('https://www.alphavantage.co/query')
    api.searchParams.set('function','GLOBAL_QUOTE'); api.searchParams.set('symbol',symbol); api.searchParams.set('apikey',marketKey)
    const response = await fetch(api, { signal: AbortSignal.timeout(10000) })
    if (!response.ok) return json({ error: 'Market provider unavailable; order not executed' }, 502)
    const payload = await response.json()
    if (payload.Note || payload.Information) return json({ error: 'Market provider limit reached; order not executed' }, 429)
    const quote = payload['Global Quote']
    const price = Number(quote?.['05. price'])
    const day = quote?.['07. latest trading day']
    if (!Number.isFinite(price) || price <= 0 || !/^\d{4}-\d\d-\d\d$/.test(day ?? '')) return json({ error: 'No valid market price; order not executed' }, 409)
    const market_timestamp = new Date(`${day}T00:00:00.000Z`)
    const { data: trade, error: tradeError } = await admin.rpc('execute_trade', { p_user_id:user.id,p_simulation_id:simulation_id,p_symbol:symbol,p_side:side,p_quantity:quantity,p_price:price,p_market_timestamp:market_timestamp.toISOString(),p_request_key:request_key })
    if (tradeError) {
      console.error('execute_trade RPC failed', { code: tradeError.code, message: tradeError.message, details: tradeError.details, hint: tradeError.hint })
      return json({ error: tradeError.message, code: tradeError.code, details: tradeError.details }, 409)
    }
    return json({ ...trade, market_timestamp: market_timestamp.toISOString(), source: 'Alpha Vantage GLOBAL_QUOTE', delayed: true })
  } catch (error) { return json({ error: errorMessage(error) }, 400) }
})
