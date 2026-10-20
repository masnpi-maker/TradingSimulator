import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { corsHeaders, errorMessage, json } from '../_shared/http.ts'

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  if (req.method !== 'POST') return json({ error: 'Method not allowed' }, 405)
  const token = req.headers.get('Authorization')
  if (!token) return json({ error: 'Authentication required' }, 401)
  const url = Deno.env.get('SUPABASE_URL')!
  const anon = Deno.env.get('SUPABASE_ANON_KEY')!
  const key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
  const auth = createClient(url, anon, { global: { headers: { Authorization: token } } })
  const { data: { user }, error: authError } = await auth.auth.getUser()
  if (authError || !user) return json({ error: 'Invalid session' }, 401)

  try {
    const { simulation_id: simulationId } = await req.json()
    if (!/^[0-9a-f-]{36}$/i.test(String(simulationId ?? ''))) return json({ error: 'Invalid simulation id' }, 400)
    const admin = createClient(url, key)
    const { data: simulation, error: simulationError } = await admin
      .from('simulations')
      .select('id,mode,cash_balance')
      .eq('id', simulationId)
      .eq('user_id', user.id)
      .maybeSingle()
    if (simulationError) throw simulationError
    if (!simulation) return json({ error: 'Simulation not found' }, 404)
    if (simulation.mode !== 'live') return json({ error: 'Snapshots are recorded by historical playback' }, 409)

    const { data: positions, error: positionsError } = await admin
      .from('positions')
      .select('instrument_id,quantity,average_cost,realized_pnl')
      .eq('simulation_id', simulationId)
      .gt('quantity', 0)
    if (positionsError) throw positionsError
    const instrumentIds = (positions || []).map(position => position.instrument_id)
    const latestPrices = new Map<string, number>()
    if (instrumentIds.length) {
      const { data: prices, error: pricesError } = await admin
        .from('price_history')
        .select('instrument_id,close,price_timestamp')
        .in('instrument_id', instrumentIds)
        .eq('interval', 'global_quote')
        .order('price_timestamp', { ascending: false })
      if (pricesError) throw pricesError
      for (const price of prices || []) {
        if (!latestPrices.has(price.instrument_id)) latestPrices.set(price.instrument_id, Number(price.close))
      }
    }

    let positionsValue = 0
    let realizedPnl = 0
    let unrealizedPnl = 0
    for (const position of positions || []) {
      const quantity = Number(position.quantity)
      const averageCost = Number(position.average_cost)
      const mark = latestPrices.get(position.instrument_id) ?? averageCost
      positionsValue += quantity * mark
      realizedPnl += Number(position.realized_pnl)
      unrealizedPnl += quantity * (mark - averageCost)
    }

    const now = new Date()
    const snapshotTime = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate())).toISOString()
    const snapshot = {
      simulation_id: simulationId,
      snapshot_time: snapshotTime,
      cash_balance: Number(simulation.cash_balance),
      positions_value: positionsValue,
      equity: Number(simulation.cash_balance) + positionsValue,
      realized_pnl: realizedPnl,
      unrealized_pnl: unrealizedPnl,
    }
    const { error: saveError } = await admin
      .from('equity_snapshots')
      .upsert(snapshot, { onConflict: 'simulation_id,snapshot_time' })
    if (saveError) throw saveError
    return json({ simulation_id: simulationId, snapshot_time: snapshotTime, equity: snapshot.equity })
  } catch (error) {
    return json({ error: errorMessage(error) }, 400)
  }
})
