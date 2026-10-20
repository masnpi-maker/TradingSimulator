create or replace function public.delete_simulation(p_simulation_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_user uuid:=auth.uid(); v_sim public.simulations;
begin
  if v_user is null then raise exception 'Authentication required'; end if;
  select * into v_sim from public.simulations where id=p_simulation_id and user_id=v_user for update;
  if not found then raise exception 'Simulation not found'; end if;

  delete from public.trades where simulation_id=p_simulation_id and user_id=v_user;
  delete from public.orders where simulation_id=p_simulation_id and user_id=v_user;
  delete from public.positions where simulation_id=p_simulation_id;
  delete from public.equity_snapshots where simulation_id=p_simulation_id;
  delete from public.transactions where simulation_id=p_simulation_id and user_id=v_user;
  delete from public.simulations where id=p_simulation_id and user_id=v_user;
  return jsonb_build_object('deleted',true,'simulation_id',p_simulation_id);
end; $$;

revoke all on function public.delete_simulation(uuid) from public,anon;
grant execute on function public.delete_simulation(uuid) to authenticated;
