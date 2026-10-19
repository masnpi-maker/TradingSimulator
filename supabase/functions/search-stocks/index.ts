import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { corsHeaders, errorMessage, json } from '../_shared/http.ts'

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  if (req.method !== 'POST') return json({ error: 'Method not allowed' }, 405)
  const token = req.headers.get('Authorization')
  if (!token) return json({ error: 'Authentication required' }, 401)
  const apiKey = Deno.env.get('ALPHA_VANTAGE_API_KEY')
  if (!apiKey) return json({ error: 'Market data provider is not configured' }, 503)
  const client = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_ANON_KEY')!, { global: { headers: { Authorization: token } } })
  const { data: { user }, error: authError } = await client.auth.getUser()
  if (authError || !user) return json({ error: 'Invalid session' }, 401)
  try {
    const { query } = await req.json()
    const term = String(query ?? '').trim().slice(0, 40)
    if (term.length < 1) return json({ results: [] })
    const url = new URL('https://www.alphavantage.co/query')
    url.searchParams.set('function', 'SYMBOL_SEARCH'); url.searchParams.set('keywords', term); url.searchParams.set('apikey', apiKey)
    const response = await fetch(url, { signal: AbortSignal.timeout(10000) })
    if (!response.ok) return json({ error: 'Market provider request failed' }, 502)
    const payload = await response.json()
    if (payload.Note || payload.Information) return json({ error: 'Market provider request limit reached' }, 429)
    if (payload['Error Message']) return json({ error: 'Market provider rejected the search' }, 502)
    return json({ results: (payload.bestMatches ?? []).slice(0, 10).map((item: Record<string, string>) => ({ symbol: item['1. symbol'], name: item['2. name'], type: item['3. type'], region: item['4. region'], currency: item['8. currency'] })) })
  } catch (error) { return json({ error: errorMessage(error) }, 502) }
})
