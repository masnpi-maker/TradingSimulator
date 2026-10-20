-- Historical playback lifecycle. Prices are stored as daily bars in price_history.
create or replace function public.start_historical_simulation(p_simulation_id uuid)
returns public.simulations language plpgsql security definer set search_path=public as $$
declare v_sim public.simulations;
begin
  select * into v_sim from public.simulations where id=p_simulation_id and user_id=auth.uid() for update;
  if not found or v_sim.mode<>'historical' then raise exception 'Historical simulation not found'; end if;
  if v_sim.status not in ('draft','paused') then raise exception 'Simulation cannot be started from its current status'; end if;
  update public.simulations set status='running',updated_at=now() where id=p_simulation_id returning * into v_sim;
  return v_sim;
end; $$;

create or replace function public.pause_historical_simulation(p_simulation_id uuid)
returns public.simulations language plpgsql security definer set search_path=public as $$
declare v_sim public.simulations;
begin
  update public.simulations set status='paused',updated_at=now() where id=p_simulation_id and user_id=auth.uid() and mode='historical' and status='running' returning * into v_sim;
  if not found then raise exception 'Running historical simulation not found'; end if;
  return v_sim;
end; $$;

create or replace function public.advance_historical_simulation(p_simulation_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_sim public.simulations; v_next timestamptz; v_positions numeric:=0; v_realized numeric:=0; v_unrealized numeric:=0;
begin
  select * into v_sim from public.simulations where id=p_simulation_id and user_id=auth.uid() for update;
  if not found or v_sim.mode<>'historical' or v_sim.status<>'running' then raise exception 'Historical simulation is not running'; end if;
  select min(price_timestamp) into v_next from public.price_history where interval='daily' and price_timestamp>v_sim.virtual_time and price_timestamp < ((v_sim.end_date+1)::timestamp at time zone 'UTC');
  if v_next is null then
    if not exists(select 1 from public.price_history where interval='daily' and price_timestamp >= (v_sim.start_date::timestamp at time zone 'UTC') and price_timestamp < ((v_sim.end_date+1)::timestamp at time zone 'UTC')) then raise exception 'Load historical prices for at least one symbol before playback'; end if;
    update public.simulations set status='completed',updated_at=now() where id=p_simulation_id;
    return jsonb_build_object('status','completed','virtual_time',v_sim.virtual_time);
  end if;
  select coalesce(sum(p.quantity*coalesce((select h.close from public.price_history h where h.instrument_id=p.instrument_id and h.interval='daily' and h.price_timestamp<=v_next order by h.price_timestamp desc limit 1),p.average_cost)),0),coalesce(sum(p.realized_pnl),0),coalesce(sum(p.quantity*(coalesce((select h.close from public.price_history h where h.instrument_id=p.instrument_id and h.interval='daily' and h.price_timestamp<=v_next order by h.price_timestamp desc limit 1),p.average_cost)-p.average_cost)),0)
    into v_positions,v_realized,v_unrealized from public.positions p where p.simulation_id=p_simulation_id;
  update public.simulations set virtual_time=v_next,updated_at=now() where id=p_simulation_id;
  insert into public.equity_snapshots(simulation_id,snapshot_time,cash_balance,positions_value,equity,realized_pnl,unrealized_pnl)
    values(p_simulation_id,v_next,v_sim.cash_balance,v_positions,v_sim.cash_balance+v_positions,v_realized,v_unrealized)
    on conflict(simulation_id,snapshot_time) do update set cash_balance=excluded.cash_balance,positions_value=excluded.positions_value,equity=excluded.equity,realized_pnl=excluded.realized_pnl,unrealized_pnl=excluded.unrealized_pnl;
  return jsonb_build_object('status','running','virtual_time',v_next,'equity',v_sim.cash_balance+v_positions);
end; $$;

create or replace function public.execute_historical_trade(p_user_id uuid,p_simulation_id uuid,p_symbol text,p_side text,p_quantity numeric,p_request_key uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_sim public.simulations; v_inst public.instruments; v_pos public.positions; v_order uuid; v_price numeric; v_gross numeric; v_fee numeric; v_realized numeric:=0; v_qty numeric; v_avg numeric; v_bar timestamptz;
begin
  if p_user_id is null or p_side not in ('buy','sell') or p_quantity<=0 or p_quantity>100000000 then raise exception 'Invalid order'; end if;
  if exists(select 1 from public.orders where user_id=p_user_id and request_key=p_request_key and status='filled') then
    return (select jsonb_build_object('order_id',o.id,'status',o.status,'price',t.price,'quantity',t.quantity,'gross_amount',t.gross_amount) from public.orders o join public.trades t on t.order_id=o.id where o.user_id=p_user_id and o.request_key=p_request_key);
  end if;
  select * into v_sim from public.simulations where id=p_simulation_id and user_id=p_user_id for update;
  if not found or v_sim.mode<>'historical' or v_sim.status<>'running' then raise exception 'Historical simulation is not running'; end if;
  select * into v_inst from public.instruments where symbol=upper(p_symbol);
  if not found then raise exception 'Instrument history has not been loaded'; end if;
  select close,price_timestamp into v_price,v_bar from public.price_history where instrument_id=v_inst.id and interval='daily' and price_timestamp=v_sim.virtual_time;
  if not found then raise exception 'No price for this symbol on the current simulation day'; end if;
  v_gross:=round(p_quantity*v_price,8); v_fee:=round(v_gross*0.001,8);
  insert into public.orders(request_key,simulation_id,user_id,instrument_id,side,quantity,status,executed_at) values(p_request_key,p_simulation_id,p_user_id,v_inst.id,p_side,p_quantity,'pending',now()) returning id into v_order;
  select * into v_pos from public.positions where simulation_id=p_simulation_id and instrument_id=v_inst.id for update;
  if p_side='buy' then
    if v_sim.cash_balance<v_gross+v_fee then raise exception 'Insufficient virtual cash'; end if;
    if not found then insert into public.positions(simulation_id,instrument_id,quantity,average_cost) values(p_simulation_id,v_inst.id,p_quantity,(v_gross+v_fee)/p_quantity);
    else v_qty:=v_pos.quantity+p_quantity; v_avg:=(v_pos.quantity*v_pos.average_cost+v_gross+v_fee)/v_qty; update public.positions set quantity=v_qty,average_cost=v_avg,updated_at=v_bar where id=v_pos.id; end if;
    update public.simulations set cash_balance=cash_balance-v_gross-v_fee,updated_at=now() where id=p_simulation_id;
  else
    if not found or v_pos.quantity<p_quantity then raise exception 'Insufficient shares'; end if;
    v_realized:=v_gross-v_fee-v_pos.average_cost*p_quantity;
    update public.positions set quantity=quantity-p_quantity,realized_pnl=realized_pnl+v_realized,average_cost=case when quantity-p_quantity=0 then 0 else average_cost end,updated_at=v_bar where id=v_pos.id;
    update public.simulations set cash_balance=cash_balance+v_gross-v_fee,updated_at=now() where id=p_simulation_id;
  end if;
  update public.orders set status='filled' where id=v_order;
  insert into public.trades(simulation_id,user_id,instrument_id,order_id,side,quantity,price,fees,gross_amount,realized_pnl,executed_at,market_timestamp,simulation_timestamp)
    values(p_simulation_id,p_user_id,v_inst.id,v_order,p_side,p_quantity,v_price,v_fee,v_gross,case when p_side='sell' then v_realized else null end,now(),v_bar,v_bar);
  return jsonb_build_object('order_id',v_order,'status','filled','symbol',v_inst.symbol,'side',p_side,'quantity',p_quantity,'price',v_price,'fees',v_fee,'gross_amount',v_gross,'realized_pnl',case when p_side='sell' then v_realized else null end,'simulation_timestamp',v_bar);
end; $$;

grant execute on function public.start_historical_simulation(uuid) to authenticated;
grant execute on function public.pause_historical_simulation(uuid) to authenticated;
grant execute on function public.advance_historical_simulation(uuid) to authenticated;
revoke all on function public.execute_historical_trade(uuid,uuid,text,text,numeric,uuid) from public,anon,authenticated;
grant execute on function public.execute_historical_trade(uuid,uuid,text,text,numeric,uuid) to service_role;
