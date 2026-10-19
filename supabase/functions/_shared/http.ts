export const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, GET, OPTIONS',
}
export function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { ...corsHeaders, 'Content-Type': 'application/json' } })
}
export function errorMessage(error: unknown) { return error instanceof Error ? error.message : 'Unexpected server error' }

// Alpha Vantage GLOBAL_QUOTE is an end-of-day feed on the free entitlement.
// Treat the previous trading day's close as usable before today's close is
// published, while still rejecting quotes older than the previous weekday.
export function isQuoteTooOld(day: string, now = new Date()) {
  if (!/^\d{4}-\d\d-\d\d$/.test(day)) return true
  const quoteDate = new Date(`${day}T00:00:00.000Z`)
  if (!Number.isFinite(quoteDate.getTime()) || quoteDate.getTime() > now.getTime()) return true
  const today = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate()))
  const latestExpected = new Date(today)
  const weekday = latestExpected.getUTCDay()
  if (weekday === 0) latestExpected.setUTCDate(latestExpected.getUTCDate() - 2)
  else if (weekday === 1) latestExpected.setUTCDate(latestExpected.getUTCDate() - 3)
  else latestExpected.setUTCDate(latestExpected.getUTCDate() - 1)
  return quoteDate < latestExpected
}
