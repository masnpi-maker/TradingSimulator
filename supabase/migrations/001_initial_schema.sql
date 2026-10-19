create extension if not exists pgcrypto;

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  username text, full_name text, avatar_url text,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create table public.accounts (
  id uuid primary key default gen_random_uuid(), user_id uuid not null references auth.users(id) on delete cascade,
  name text not null default 'Virtual account', currency text not null default 'USD' check(currency='USD'),
  initial_balance numeric(20,2) not null default 0 check(initial_balance>=0), cash_balance numeric(20,2) not null default 0 check(cash_balance>=0), created_at timestamptz not null default now()
);
create table public.simulations (
  id uuid primary key default gen_random_uuid(), account_id uuid not null references public.accounts(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade, name text not null,
  mode text not null check(mode in ('live','historical')), status text not null default 'draft' check(status in ('draft','running','paused','completed')),
  start_date date, end_date date, initial_balance numeric(20,2) not null check(initial_balance>=0), cash_balance numeric(20,2) not null check(cash_balance>=0),
  virtual_time timestamptz, playback_mode text not null default 'step' check(playback_mode in ('step','auto')),
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  check((mode='live' and start_date is null and end_date is null) or (mode='historical' and start_date is not null and end_date>=start_date))
);
create table public.instruments (
  id uuid primary key default gen_random_uuid(), symbol text not null unique check(symbol=upper(symbol)), name text not null,
  exchange text, currency text not null default 'USD', asset_type text not null default 'Equity', created_at timestamptz not null default now()
);
-- A user's watchlist is shared across their simulations.
create table public.watchlist (
  user_id uuid not null references auth.users(id) on delete cascade,
  instrument_id uuid not null references public.instruments(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key(user_id,instrument_id)
);
create table public.orders (
  id uuid primary key default gen_random_uuid(), request_key uuid not null, simulation_id uuid not null references public.simulations(id),
  user_id uuid not null references auth.users(id), instrument_id uuid not null references public.instruments(id),
  side text not null check(side in ('buy','sell')), order_type text not null default 'market', quantity numeric(20,6) not null check(quantity>0),
  status text not null default 'pending' check(status in ('pending','filled','rejected')), requested_at timestamptz not null default now(),
  executed_at timestamptz, error_message text, unique(user_id,request_key)
);
create table public.trades (
  id uuid primary key default gen_random_uuid(), simulation_id uuid not null references public.simulations(id), user_id uuid not null references auth.users(id),
  instrument_id uuid not null references public.instruments(id), order_id uuid not null unique references public.orders(id),
  side text not null check(side in ('buy','sell')), quantity numeric(20,6) not null check(quantity>0), price numeric(20,8) not null check(price>0),
  fees numeric(20,8) not null default 0 check(fees>=0), gross_amount numeric(20,8) not null check(gross_amount>=0),
  realized_pnl numeric(20,8), executed_at timestamptz not null, market_timestamp timestamptz not null, simulation_timestamp timestamptz not null, created_at timestamptz not null default now()
);
create table public.positions (
  id uuid primary key default gen_random_uuid(), simulation_id uuid not null references public.simulations(id) on delete cascade,
  instrument_id uuid not null references public.instruments(id), quantity numeric(20,6) not null default 0 check(quantity>=0),
  average_cost numeric(20,8) not null default 0 check(average_cost>=0), realized_pnl numeric(20,8) not null default 0, updated_at timestamptz not null default now(),
  unique(simulation_id,instrument_id)
);
create table public.transactions (
  id uuid primary key default gen_random_uuid(), account_id uuid not null references public.accounts(id), simulation_id uuid references public.simulations(id), user_id uuid not null references auth.users(id),
  request_key uuid not null, type text not null check(type in ('deposit','withdrawal')), amount numeric(20,2) not null check(amount>0), currency text not null default 'USD' check(currency='USD'),
  description text, created_at timestamptz not null default now(), unique(user_id,request_key)
);
create table public.price_history (
  id bigint generated always as identity primary key, instrument_id uuid not null references public.instruments(id), interval text not null,
  price_timestamp timestamptz not null, open numeric(20,8), high numeric(20,8), low numeric(20,8), close numeric(20,8) not null check(close>0),
  volume numeric(24,4), source text not null, fetched_at timestamptz not null default now(), unique(instrument_id,interval,price_timestamp)
);
create table public.equity_snapshots (
  id bigint generated always as identity primary key, simulation_id uuid not null references public.simulations(id) on delete cascade,
  snapshot_time timestamptz not null, cash_balance numeric(20,2) not null, positions_value numeric(20,8) not null,
  equity numeric(20,8) not null, realized_pnl numeric(20,8) not null, unrealized_pnl numeric(20,8) not null, unique(simulation_id,snapshot_time)
);
create index simulations_user_idx on public.simulations(user_id,created_at desc);
create index orders_simulation_idx on public.orders(simulation_id,requested_at desc);
create index trades_simulation_idx on public.trades(simulation_id,executed_at desc);
create index positions_simulation_idx on public.positions(simulation_id);
create index transactions_account_idx on public.transactions(account_id,created_at desc);
create index prices_lookup_idx on public.price_history(instrument_id,interval,price_timestamp desc);
create index snapshots_lookup_idx on public.equity_snapshots(simulation_id,snapshot_time);

create function public.handle_new_user() returns trigger language plpgsql security definer set search_path=public as $$
begin
  insert into public.profiles(id,username,full_name) values(new.id, nullif(new.raw_user_meta_data->>'username',''), nullif(new.raw_user_meta_data->>'full_name','')) on conflict(id) do nothing;
  insert into public.accounts(user_id,name,currency,initial_balance,cash_balance) values(new.id,'Virtual account','USD',10000,10000);
  return new;
end; $$;
create trigger on_auth_user_created after insert on auth.users for each row execute function public.handle_new_user();

create function public.create_simulation(p_name text,p_mode text,p_initial_balance numeric,p_start_date date default null,p_end_date date default null,p_playback_mode text default 'step')
returns uuid language plpgsql security definer set search_path=public as $$
declare v_user uuid:=auth.uid(); v_account public.accounts; v_id uuid;
begin
  if v_user is null then raise exception 'Authentication required'; end if;
  if p_name is null or length(trim(p_name)) not between 1 and 80 or p_initial_balance<0 or p_initial_balance>100000000 then raise exception 'Invalid simulation settings'; end if;
  if p_mode not in ('live','historical') or p_playback_mode not in ('step','auto') then raise exception 'Invalid simulation mode'; end if;
  if p_mode='historical' and (p_start_date is null or p_end_date is null or p_end_date<p_start_date or p_end_date>current_date) then raise exception 'Invalid historical dates'; end if;
  select * into v_account from public.accounts where user_id=v_user order by created_at limit 1 for update;
  if not found then raise exception 'Account not found'; end if;
  insert into public.simulations(account_id,user_id,name,mode,status,start_date,end_date,initial_balance,cash_balance,virtual_time,playback_mode)
  values(v_account.id,v_user,trim(p_name),p_mode,case when p_mode='live' then 'running' else 'draft' end,p_start_date,p_end_date,p_initial_balance,p_initial_balance,case when p_mode='historical' then (p_start_date::timestamp at time zone 'UTC') end,p_playback_mode) returning id into v_id;
  insert into public.equity_snapshots(simulation_id,snapshot_time,cash_balance,positions_value,equity,realized_pnl,unrealized_pnl)
  values(v_id,coalesce(case when p_mode='historical' then (p_start_date::timestamp at time zone 'UTC') end,now()),p_initial_balance,0,p_initial_balance,0,0);
  return v_id;
end; $$;

create function public.deposit_virtual_funds(p_account_id uuid,p_amount numeric,p_request_key uuid,p_description text default null) returns numeric
language plpgsql security definer set search_path=public as $$ declare v_balance numeric; begin
  if auth.uid() is null or p_amount<=0 or p_amount>100000000 then raise exception 'Invalid deposit'; end if;
  if exists(select 1 from public.transactions where user_id=auth.uid() and request_key=p_request_key) then select cash_balance into v_balance from public.accounts where id=p_account_id and user_id=auth.uid(); return v_balance; end if;
  update public.accounts set cash_balance=cash_balance+p_amount where id=p_account_id and user_id=auth.uid() returning cash_balance into v_balance;
  if not found then raise exception 'Account not found'; end if;
  insert into public.transactions(account_id,user_id,request_key,type,amount,description) values(p_account_id,auth.uid(),p_request_key,'deposit',p_amount,p_description);
  return v_balance;
end; $$;
create function public.withdraw_virtual_funds(p_account_id uuid,p_amount numeric,p_request_key uuid,p_description text default null) returns numeric
language plpgsql security definer set search_path=public as $$ declare v_balance numeric; begin
  if auth.uid() is null or p_amount<=0 then raise exception 'Invalid withdrawal'; end if;
  if exists(select 1 from public.transactions where user_id=auth.uid() and request_key=p_request_key) then select cash_balance into v_balance from public.accounts where id=p_account_id and user_id=auth.uid(); return v_balance; end if;
  update public.accounts set cash_balance=cash_balance-p_amount where id=p_account_id and user_id=auth.uid() and cash_balance>=p_amount returning cash_balance into v_balance;
  if not found then raise exception 'Insufficient funds or account not found'; end if;
  insert into public.transactions(account_id,user_id,request_key,type,amount,description) values(p_account_id,auth.uid(),p_request_key,'withdrawal',p_amount,p_description);
  return v_balance;
end; $$;

-- Called only by the authenticated execute-trade Edge Function after it validates
-- Alpha Vantage data. All balance, position and ledger updates commit atomically.
create function public.execute_trade(p_user_id uuid,p_simulation_id uuid,p_symbol text,p_side text,p_quantity numeric,p_price numeric,p_market_timestamp timestamptz,p_request_key uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_sim public.simulations; v_inst public.instruments; v_pos public.positions; v_order uuid; v_gross numeric; v_fee numeric; v_realized numeric:=0; v_new_qty numeric; v_new_avg numeric;
begin
  if p_user_id is null or p_side not in ('buy','sell') or p_quantity<=0 or p_quantity>100000000 or p_price<=0 or p_market_timestamp is null then raise exception 'Invalid order'; end if;
  if exists(select 1 from public.orders where user_id=p_user_id and request_key=p_request_key and status='filled') then
    return (select jsonb_build_object('order_id',o.id,'status',o.status,'price',t.price,'quantity',t.quantity,'gross_amount',t.gross_amount) from public.orders o join public.trades t on t.order_id=o.id where o.user_id=p_user_id and o.request_key=p_request_key);
  end if;
  select * into v_sim from public.simulations where id=p_simulation_id and user_id=p_user_id for update;
  if not found or v_sim.status<>'running' or v_sim.mode<>'live' then raise exception 'Simulation is not active or unsupported'; end if;
  -- This is a virtual simulator: use the latest available quote even when its
  -- trading date is old. The Edge Function still requires a valid positive price.
  if p_market_timestamp is null then raise exception 'Invalid market timestamp'; end if;
  select * into v_inst from public.instruments where symbol=upper(p_symbol);
  if not found then insert into public.instruments(symbol,name) values(upper(p_symbol),upper(p_symbol)) on conflict(symbol) do update set symbol=excluded.symbol returning * into v_inst; end if;
  v_gross:=round(p_quantity*p_price,8); v_fee:=round(v_gross*0.001,8);
  insert into public.orders(request_key,simulation_id,user_id,instrument_id,side,quantity,status,executed_at)
    values(p_request_key,p_simulation_id,p_user_id,v_inst.id,p_side,p_quantity,'pending',now()) returning id into v_order;
  select * into v_pos from public.positions where simulation_id=p_simulation_id and instrument_id=v_inst.id for update;
  if p_side='buy' then
    if v_sim.cash_balance<v_gross+v_fee then raise exception 'Insufficient virtual cash'; end if;
    if not found then insert into public.positions(simulation_id,instrument_id,quantity,average_cost) values(p_simulation_id,v_inst.id,p_quantity,(v_gross+v_fee)/p_quantity);
    else v_new_qty:=v_pos.quantity+p_quantity; v_new_avg:=(v_pos.quantity*v_pos.average_cost+v_gross+v_fee)/v_new_qty; update public.positions set quantity=v_new_qty,average_cost=v_new_avg,updated_at=now() where id=v_pos.id; end if;
    update public.simulations set cash_balance=cash_balance-v_gross-v_fee,updated_at=now() where id=p_simulation_id;
  else
    if not found or v_pos.quantity<p_quantity then raise exception 'Insufficient shares'; end if;
    v_realized:=v_gross-v_fee-(v_pos.average_cost*p_quantity);
    update public.positions set quantity=quantity-p_quantity,realized_pnl=realized_pnl+v_realized,average_cost=case when quantity-p_quantity=0 then 0 else average_cost end,updated_at=now() where id=v_pos.id;
    update public.simulations set cash_balance=cash_balance+v_gross-v_fee,updated_at=now() where id=p_simulation_id;
  end if;
  update public.orders set status='filled' where id=v_order;
  insert into public.trades(simulation_id,user_id,instrument_id,order_id,side,quantity,price,fees,gross_amount,realized_pnl,executed_at,market_timestamp,simulation_timestamp)
    values(p_simulation_id,p_user_id,v_inst.id,v_order,p_side,p_quantity,p_price,v_fee,v_gross,case when p_side='sell' then v_realized else null end,now(),p_market_timestamp,now());
  return jsonb_build_object('order_id',v_order,'status','filled','symbol',v_inst.symbol,'side',p_side,'quantity',p_quantity,'price',p_price,'fees',v_fee,'gross_amount',v_gross,'realized_pnl',case when p_side='sell' then v_realized else null end);
end; $$;

alter table public.profiles enable row level security;
alter table public.accounts enable row level security;
alter table public.simulations enable row level security;
alter table public.instruments enable row level security;
alter table public.watchlist enable row level security;
alter table public.orders enable row level security;
alter table public.trades enable row level security;
alter table public.positions enable row level security;
alter table public.transactions enable row level security;
alter table public.price_history enable row level security;
alter table public.equity_snapshots enable row level security;
create policy profiles_read_own on public.profiles for select using(id=auth.uid());
create policy profiles_update_own on public.profiles for update using(id=auth.uid()) with check(id=auth.uid());
create policy accounts_read_own on public.accounts for select using(user_id=auth.uid());
create policy simulations_read_own on public.simulations for select using(user_id=auth.uid());
create policy instruments_read_authenticated on public.instruments for select to authenticated using(true);
create policy watchlist_read_own on public.watchlist for select using(user_id=auth.uid());
create policy watchlist_add_own on public.watchlist for insert to authenticated with check(user_id=auth.uid());
create policy watchlist_remove_own on public.watchlist for delete to authenticated using(user_id=auth.uid());
create policy positions_read_own on public.positions for select using(exists(select 1 from public.simulations s where s.id=simulation_id and s.user_id=auth.uid()));
create policy trades_read_own on public.trades for select using(user_id=auth.uid());
create policy orders_read_own on public.orders for select using(user_id=auth.uid());
create policy transactions_read_own on public.transactions for select using(user_id=auth.uid());
create policy prices_read_authenticated on public.price_history for select to authenticated using(true);
create policy snapshots_read_own on public.equity_snapshots for select using(exists(select 1 from public.simulations s where s.id=simulation_id and s.user_id=auth.uid()));
revoke insert,update,delete on public.accounts,public.orders,public.trades,public.positions,public.transactions,public.price_history,public.equity_snapshots from anon,authenticated;
revoke all on public.watchlist from anon,authenticated;
grant select,insert,delete on public.watchlist to authenticated;
revoke insert,delete on public.simulations from anon,authenticated;
grant execute on function public.create_simulation(text,text,numeric,date,date,text) to authenticated;
grant execute on function public.deposit_virtual_funds(uuid,numeric,uuid,text) to authenticated;
grant execute on function public.withdraw_virtual_funds(uuid,numeric,uuid,text) to authenticated;
revoke all on function public.execute_trade(uuid,uuid,text,text,numeric,numeric,timestamptz,uuid) from public,anon,authenticated;
grant execute on function public.execute_trade(uuid,uuid,text,text,numeric,numeric,timestamptz,uuid) to service_role;
