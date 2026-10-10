-- Explicit driver departure is distinct from automatic stop activation.
alter table public.pick_return_routes add column departed_at timestamptz;
create function public.depart_driver_route(p_route uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare r public.pick_return_routes;s public.pick_return_stops;counted integer:=0;
begin
 select * into r from public.pick_return_routes where id=p_route for update;
 if r.id is null then raise exception 'Route unavailable';end if;
 perform private.require_admin(r.unit_id);
 if r.departed_at is not null then return jsonb_build_object('ok',true,'already_departed',true);end if;
 if r.status in ('Completed','Cancelled') or r.confirmed_at is not null then raise exception 'Route is closed';end if;
 for s in select * from public.pick_return_stops where route_id=r.id and status in ('Scheduled','En Route','Arrived') order by sequence loop
  perform private.route_notice(s.job_id,case when r.leg='Pickup' then 'PICKUP_ROUTE_DEPARTED' else 'RETURN_ROUTE_DEPARTED' end,'route-departed:'||r.id||':'||s.id,'ToolTag is on the way. Our driver has left the shop for today’s '||case when r.leg='Pickup' then 'Pickup' else 'Return' end||' route. Follow your status page for updates.');
  counted:=counted+1;
 end loop;
 if counted=0 then raise exception 'No confirmed stops remain on this route';end if;
 update public.pick_return_routes set departed_at=now(),started_at=coalesce(started_at,now()),status='Active' where id=r.id;
 return jsonb_build_object('ok',true,'notified',counted);
end $$;
revoke all on function public.depart_driver_route(uuid) from public;
grant execute on function public.depart_driver_route(uuid) to authenticated;

alter table public.pick_return_routes add column proximity_at timestamptz;
alter table public.pick_return_stops add column latitude double precision check(latitude between -90 and 90);
alter table public.pick_return_stops add column longitude double precision check(longitude between -180 and 180);
alter table public.pick_return_stops add column approximate_eta timestamptz;
alter table public.pick_return_orders add column pickup_approximate_eta timestamptz;
alter table public.pick_return_orders add column return_approximate_eta timestamptz;
alter table public.pick_return_orders add column route_eta_updated_at timestamptz;

create function private.route_three_remaining() returns trigger language plpgsql security definer set search_path='' as $$
declare r public.pick_return_routes;s public.pick_return_stops;
begin
 if new.status<>'Completed' or old.status='Completed' then return new;end if;
 select * into r from public.pick_return_routes where id=new.route_id for update;
 if r.proximity_at is not null or r.status in ('Completed','Cancelled') then return new;end if;
 if (select count(*) from public.pick_return_stops where route_id=r.id and status in ('Scheduled','En Route','Arrived'))<>3 then return new;end if;
 update public.pick_return_routes set proximity_at=now() where id=r.id;
 for s in select * from public.pick_return_stops where route_id=r.id and status in ('Scheduled','En Route','Arrived') order by sequence loop
  perform private.route_notice(s.job_id,case when r.leg='Pickup' then 'PICKUP_DRIVER_NEARBY' else 'RETURN_DRIVER_NEARBY' end,'route-nearby:'||r.id||':'||s.id,'Driver nearby: 3 stops remaining. ETA aprox. unavailable while location is being updated. Check your status page for the latest estimate.');
  -- Give the server time to attach its estimate before a concurrent worker claims mail.
  update public.notifications set due_at=now()+interval '30 seconds' where dedupe_key='route-nearby:'||r.id||':'||s.id and status='Pending Integration' and mail_claim is null;
 end loop;
 return new;
end $$;
revoke all on function private.route_three_remaining() from public;
create trigger route_three_remaining after update on public.pick_return_stops for each row execute function private.route_three_remaining();

create function public.driver_route_estimate_context(p_route uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare r public.pick_return_routes;stops jsonb;
begin
 select * into r from public.pick_return_routes where id=p_route;
 if r.id is null then raise exception 'Route unavailable';end if;
 perform private.require_admin(r.unit_id);
 select coalesce(jsonb_agg(jsonb_build_object('id',s.id,'address',s.address,'latitude',s.latitude,'longitude',s.longitude) order by s.sequence),'[]'::jsonb) into stops from public.pick_return_stops s where s.route_id=r.id and s.status in ('Scheduled','En Route','Arrived');
 return jsonb_build_object('closed',r.status in ('Completed','Cancelled') or r.confirmed_at is not null,'stops',stops);
end $$;
revoke all on function public.driver_route_estimate_context(uuid) from public;
grant execute on function public.driver_route_estimate_context(uuid) to authenticated;

create function public.update_driver_route_estimates(p_route uuid,p_estimates jsonb) returns void language plpgsql security definer set search_path='' as $$
declare r public.pick_return_routes;s public.pick_return_stops;e jsonb;arrival timestamptz;eta_text text;
begin
 select * into r from public.pick_return_routes where id=p_route for update;
 if r.id is null then raise exception 'Route unavailable';end if;
 perform private.require_admin(r.unit_id);
 if r.status in ('Completed','Cancelled') or r.confirmed_at is not null then return;end if;
 if jsonb_typeof(p_estimates)<>'array' or jsonb_array_length(p_estimates)>100 then raise exception 'Invalid estimates';end if;
 for e in select * from jsonb_array_elements(p_estimates) loop
  select * into s from public.pick_return_stops where id=(e->>'id')::uuid and route_id=r.id and status in ('Scheduled','En Route','Arrived') for update;
  if s.id is null then continue;end if;
  arrival:=case when (e->>'minutes') is null then null else now()+make_interval(mins=>greatest(0,least(1440,(e->>'minutes')::integer))) end;
  update public.pick_return_stops set latitude=coalesce((e->>'latitude')::double precision,latitude),longitude=coalesce((e->>'longitude')::double precision,longitude),approximate_eta=arrival where id=s.id;
  update public.pick_return_orders set pickup_approximate_eta=case when r.leg='Pickup' then arrival else pickup_approximate_eta end,return_approximate_eta=case when r.leg='Return' then arrival else return_approximate_eta end,route_eta_updated_at=now() where job_id=s.job_id;
  eta_text:=case when arrival is null then 'ETA aprox. unavailable: driver location or address coordinates are missing.' else 'ETA aprox.: '||to_char(arrival at time zone 'America/Denver','FMHH12:MI AM')||' Denver time. This is an estimate, not a fixed arrival time.' end;
  update public.notifications set due_at=now(),payload=jsonb_set(payload,'{text}',to_jsonb('Driver nearby: 3 stops remaining. '||eta_text||' Follow your status page for recalculated estimates.')) where dedupe_key='route-nearby:'||r.id||':'||s.id and status='Pending Integration' and mail_claim is null;
 end loop;
end $$;
revoke all on function public.update_driver_route_estimates(uuid,jsonb) from public;
grant execute on function public.update_driver_route_estimates(uuid,jsonb) to authenticated;

create function private.clear_stale_route_estimate() returns trigger language plpgsql security definer set search_path='' as $$
declare leg text;
begin
 if new.address is distinct from old.address then new.latitude:=null;new.longitude:=null;end if;
 if new.address is distinct from old.address or (new.status<>old.status and new.status in ('Completed','Failed','Cancelled')) then
  new.approximate_eta:=null;
  select r.leg into leg from public.pick_return_routes r where r.id=new.route_id;
  update public.pick_return_orders set pickup_approximate_eta=case when leg='Pickup' then null else pickup_approximate_eta end,return_approximate_eta=case when leg='Return' then null else return_approximate_eta end,route_eta_updated_at=now() where job_id=new.job_id;
 end if;
 return new;
end $$;
revoke all on function private.clear_stale_route_estimate() from public;
create trigger clear_stale_route_estimate before update on public.pick_return_stops for each row execute function private.clear_stale_route_estimate();
