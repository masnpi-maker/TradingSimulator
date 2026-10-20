-- Start historical playback on an actual available trading day. A requested
-- calendar start date can be a weekend or holiday and therefore have no bar.
create or replace function public.start_historical_simulation(p_simulation_id uuid)
returns public.simulations language plpgsql security definer set search_path=public as $$
declare v_sim public.simulations; v_first_bar timestamptz;
begin
  select * into v_sim from public.simulations where id=p_simulation_id and user_id=auth.uid() for update;
  if not found or v_sim.mode<>'historical' then raise exception 'Historical simulation not found'; end if;
  if v_sim.status not in ('draft','paused') then raise exception 'Simulation cannot be started from its current status'; end if;
  if v_sim.status='draft' then
    select min(price_timestamp) into v_first_bar from public.price_history
      where interval='daily'
        and price_timestamp >= (v_sim.start_date::timestamp at time zone 'UTC')
        and price_timestamp < ((v_sim.end_date+1)::timestamp at time zone 'UTC');
    if v_first_bar is null then raise exception 'No historical daily prices loaded in this simulation date range'; end if;
    update public.simulations set status='running',virtual_time=v_first_bar,updated_at=now() where id=p_simulation_id returning * into v_sim;
    insert into public.equity_snapshots(simulation_id,snapshot_time,cash_balance,positions_value,equity,realized_pnl,unrealized_pnl)
      values(p_simulation_id,v_first_bar,v_sim.cash_balance,0,v_sim.cash_balance,0,0)
      on conflict(simulation_id,snapshot_time) do update set cash_balance=excluded.cash_balance,positions_value=excluded.positions_value,equity=excluded.equity,realized_pnl=excluded.realized_pnl,unrealized_pnl=excluded.unrealized_pnl;
  else
    update public.simulations set status='running',updated_at=now() where id=p_simulation_id returning * into v_sim;
  end if;
  return v_sim;
end; $$;
