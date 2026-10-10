-- A timestamp for every stop mutation invalidates an older ETA when route order/status changes.
alter table public.pick_return_stops add column tracking_updated_at timestamptz not null default now();
create function private.touch_stop_tracking() returns trigger language plpgsql set search_path='' as $$
begin new.tracking_updated_at:=now();return new;end $$;
revoke all on function private.touch_stop_tracking() from public;
create trigger stop_tracking_updated before update on public.pick_return_stops for each row execute function private.touch_stop_tracking();

-- Read-only customer route snapshot. Other customers' identities, addresses and coordinates are never exposed.
create function public.customer_route_tracking(p_job uuid,p_token text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare j public.jobs; pr public.pick_return_orders; own record; stops jsonb; result jsonb:='[]'; resolved integer; total integer; remaining integer; stamp timestamptz; eta timestamptz; changed timestamptz; paused boolean;
begin
 j:=private.route_actor(p_job,p_token);
 if not exists(select 1 from private.job_status_links where job_id=j.id and token_hash=encode(sha256(convert_to(coalesce(p_token,''),'UTF8')),'hex')) then raise exception 'Status link unavailable';end if;
 select * into pr from public.pick_return_orders where job_id=j.id;
 for own in
  select distinct on (r.leg) r.id route_id,r.leg,r.route_date,r.departed_at,r.confirmed_at,r.status route_status,s.id stop_id,s.sequence,s.status stop_status,s.eta scheduled_eta,s.approximate_eta,s.window_start,s.window_end
  from public.pick_return_stops s join public.pick_return_routes r on r.id=s.route_id
  where s.job_id=j.id and s.unit_id=j.unit_id
  order by r.leg,(s.status='Cancelled'),r.route_date desc,s.created_at desc
 loop
  select coalesce(jsonb_agg(jsonb_build_object('position',position,'status',status,'is_customer',id=own.stop_id) order by position),'[]'),count(*),count(*) filter(where status in ('Completed','Failed','Cancelled')),max(tracking_updated_at)
  into stops,total,resolved,changed
  from (select id,status,tracking_updated_at,row_number() over(order by sequence,id) position from public.pick_return_stops where route_id=own.route_id and (status<>'Cancelled' or id=own.stop_id)) x;
  select count(*) into remaining from public.pick_return_stops where route_id=own.route_id and sequence<=own.sequence and status in ('Scheduled','En Route','Arrived');
  select exists(select 1 from public.route_incidents where route_id=own.route_id and status='Open') into paused;
  stamp:=pr.route_eta_updated_at;
  eta:=case when not paused and own.departed_at is not null and own.stop_status in ('Scheduled','En Route') and stamp>now()-interval '10 minutes' and stamp>=changed and own.approximate_eta>now() then own.approximate_eta else null end;
  result:=result||jsonb_build_array(jsonb_build_object('leg',own.leg,'date',own.route_date,'stops',stops,'total',total,'resolved',resolved,'remaining_to_customer',remaining,'own_status',own.stop_status,'scheduled_eta',own.scheduled_eta,'estimated_eta',eta,'estimate_updated_at',case when eta is not null then stamp else null end,'updated_at',greatest(changed,own.departed_at,own.confirmed_at),'closed',own.confirmed_at is not null or own.route_status in ('Completed','Cancelled'),'paused',paused,'window_start',own.window_start,'window_end',own.window_end));
 end loop;
 return result;
end $$;
revoke all on function public.customer_route_tracking(uuid,text) from public;
grant execute on function public.customer_route_tracking(uuid,text) to anon,authenticated;
