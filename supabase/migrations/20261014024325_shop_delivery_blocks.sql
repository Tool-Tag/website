-- Shop-controlled Delivery scheduling. Existing routes and evidence are retained.
-- The rollout switch exists only to retain the legacy regression fixture; new units use shop scheduling.
alter table public.unit_settings add column shop_delivery_blocks_enabled boolean not null default true;
alter table public.pick_return_orders add column delivery_not_before date;
alter table public.pick_return_routes add column block_number integer not null default 1 check(block_number>0);
alter table public.pick_return_routes add column delivery_capacity integer not null default 20 check(delivery_capacity>0);
alter table public.pick_return_routes add column manual_stop_order boolean not null default false;
alter table public.pick_return_routes add column capacity_authorized_by uuid references auth.users(id);
alter table public.pick_return_routes add column capacity_authorization_reason text;
alter table public.pick_return_routes add constraint delivery_capacity_authorization check(delivery_capacity<=20 or (capacity_authorized_by is not null and length(trim(capacity_authorization_reason))>0));

create function private.shop_delivery_enabled(p_job uuid) returns boolean language sql stable security definer set search_path='' as $$
 select coalesce((select s.shop_delivery_blocks_enabled from public.unit_settings s join public.jobs j on j.unit_id=s.unit_id where j.id=p_job),false)
$$;
create function private.delivery_retry_paid(p_job uuid) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.delivery_attempt_fees f join public.sale_balances b on b.transaction_id=f.sale_id where f.job_id=p_job and b.balance_due=0 and b.transaction_status<>'Voided')
$$;
create function private.delivery_queue_eligible(p_job uuid) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.pick_return_orders p join public.jobs j on j.id=p.job_id where p.job_id=p_job
 and p.service_method in ('Pickup & Delivery','Drop-off + Delivery') and p.production_ready_at is not null
 and p.returned_at is null and p.delivery_attempts<2 and p.delivery_payment_status<>'Shop Pickup'
 and j.status not in ('Cancelled','Completed','Closed') and not p.hold_until_paid
 and (p.delivery_attempts=0 or private.delivery_retry_paid(p_job))
 and not exists(select 1 from public.pick_return_stops s join public.pick_return_routes r on r.id=s.route_id where s.job_id=p_job and r.leg='Return' and s.status in ('Requested','Scheduled','En Route','Arrived')))
$$;

-- Enforce capacity at the database boundary, including old scheduling RPCs.
create function private.delivery_block_capacity_guard() returns trigger language plpgsql security definer set search_path='' as $$
declare r public.pick_return_routes;n integer;
begin
 if new.status='Cancelled' then return new;end if;
 select * into r from public.pick_return_routes where id=new.route_id for update;
 if r.leg<>'Return' then return new;end if;
 if tg_op='UPDATE' and old.route_id=new.route_id and old.status<>'Cancelled' then return new;end if;
 select count(*) into n from public.pick_return_stops where route_id=r.id and status<>'Cancelled' and id<>new.id;
 if n>=r.delivery_capacity then raise exception 'Delivery block is full (% stops)',r.delivery_capacity;end if;
 return new;
end $$;
create trigger delivery_block_capacity_guard before insert or update of route_id,status on public.pick_return_stops for each row execute function private.delivery_block_capacity_guard();

-- A single block per date remains enforced by the existing unit/date/leg unique key.
-- Reordering uses an offset greater than every current sequence to avoid uniqueness collisions.
create function private.order_delivery_block(p_route uuid,p_order uuid[] default null) returns void language plpgsql security definer set search_path='' as $$
declare ids uuid[];sid uuid;off integer;i integer:=0;
begin
 select coalesce(max(sequence),0)+1000 into off from public.pick_return_stops where route_id=p_route;
 if p_order is null then
  select array_agg(s.id order by p.production_ready_at,j.created_at,s.id) into ids from public.pick_return_stops s join public.jobs j on j.id=s.job_id join public.pick_return_orders p on p.job_id=j.id where s.route_id=p_route and s.status<>'Cancelled';
 else ids:=p_order;end if;
 update public.pick_return_stops set sequence=sequence+off where route_id=p_route;
 foreach sid in array coalesce(ids,'{}'::uuid[]) loop i:=i+1;update public.pick_return_stops set sequence=i where id=sid and route_id=p_route;end loop;
 for sid in select id from public.pick_return_stops where route_id=p_route and status='Cancelled' order by sequence loop i:=i+1;update public.pick_return_stops set sequence=i where id=sid;end loop;
end $$;

alter function private.auto_return(uuid,date) rename to auto_return_before_shop_blocks;
create function private.auto_return(p_job uuid,p_after date default null) returns uuid language plpgsql security definer set search_path='' as $$
declare pr public.pick_return_orders;
begin
 if not private.shop_delivery_enabled(p_job) then return private.auto_return_before_shop_blocks(p_job,p_after);end if;
 select * into pr from public.pick_return_orders where job_id=p_job for update;
 if pr.service_method not in ('Pickup & Delivery','Drop-off + Delivery') then return null;end if;
 -- Existing assignments survive normal reconciliation; a cutoff explicitly supplies p_after.
 if p_after is null and exists(select 1 from public.pick_return_stops s join public.pick_return_routes r on r.id=s.route_id where s.job_id=p_job and r.leg='Return' and s.status in ('Scheduled','En Route','Arrived')) then return null;end if;
 if exists(select 1 from public.pick_return_stops s join public.pick_return_routes r on r.id=s.route_id where s.job_id=p_job and r.leg='Return' and s.status in ('En Route','Arrived')) then return null;end if;
 update public.pick_return_stops s set status='Cancelled' from public.pick_return_routes r where r.id=s.route_id and s.job_id=p_job and r.leg='Return' and s.status in ('Requested','Scheduled');
 update public.pick_return_orders set return_status='Delivery In Progress',return_window_start=null,return_window_end=null,return_eta=null,return_reservation_stop_id=null,
 delivery_not_before=greatest(delivery_not_before,p_after,(pickup_window_start at time zone 'America/Denver')::date),updated_at=now() where job_id=p_job;
 return null;
end $$;
alter function private.reserve_return_retry(uuid,uuid) rename to reserve_return_retry_before_shop_blocks;
create function private.reserve_return_retry(p_job uuid,p_missed uuid) returns uuid language plpgsql security definer set search_path='' as $$
begin
 if not private.shop_delivery_enabled(p_job) then return private.reserve_return_retry_before_shop_blocks(p_job,p_missed);end if;
 if not exists(select 1 from public.pick_return_stops s join public.pick_return_routes r on r.id=s.route_id where s.id=p_missed and s.job_id=p_job and s.status='Failed' and r.leg='Return') then raise exception 'Missed delivery unavailable';end if;
 update public.pick_return_orders set return_reservation_stop_id=null,return_reservation_expires_at=now()+interval '15 days',return_window_start=null,return_window_end=null,return_eta=null,return_status='Delivery In Progress',delivery_payment_status='Pending Delivery',
 delivery_not_before=greatest((now() at time zone 'America/Denver')::date+1,delivery_not_before),updated_at=now() where job_id=p_job and delivery_attempts=1 and returned_at is null and delivery_payment_status<>'Shop Pickup';
 return null;
end $$;
alter function private.reconcile_delivery(uuid) rename to reconcile_delivery_before_shop_blocks;
create function private.reconcile_delivery(p_job uuid) returns void language plpgsql security definer set search_path='' as $$
declare pr public.pick_return_orders;
begin
 if not private.shop_delivery_enabled(p_job) then perform private.reconcile_delivery_before_shop_blocks(p_job);return;end if;
 select * into pr from public.pick_return_orders where job_id=p_job for update;
 if pr.service_method not in ('Pickup & Delivery','Drop-off + Delivery') then return;end if;
 if pr.delivery_attempts=1 and pr.returned_at is null and pr.delivery_payment_status<>'Shop Pickup' and (pr.return_reservation_expires_at is not null or pr.return_window_start is null) then
  if private.delivery_retry_paid(p_job) then
   perform private.auto_return(p_job);
   update public.pick_return_orders set return_reservation_stop_id=null,return_reservation_expires_at=null,updated_at=now() where job_id=p_job;
  elsif now()>=pr.return_reservation_expires_at then perform private.release_return_reservation(p_job);end if;
  return;
 end if;
 perform private.reconcile_delivery_before_shop_blocks(p_job);
end $$;

create function public.delivery_block_availability(p_job uuid,p_from date) returns jsonb language plpgsql security definer set search_path='' as $$
declare u uuid;pr public.pick_return_orders;d date;r public.pick_return_routes;n integer;result jsonb:='[]';days integer[];i integer;
begin
 select unit_id into u from public.jobs where id=p_job;
 if u is distinct from '10000000-0000-0000-0000-000000000002'::uuid or not private.has_block(u,'pr.routes.plan') then raise exception 'Route planning permission required' using errcode='42501';end if;
 if not private.delivery_queue_eligible(p_job) then raise exception 'This job is not awaiting delivery scheduling';end if;
 select * into pr from public.pick_return_orders where job_id=p_job;
 select return_route_iso_weekdays into days from public.unit_settings where unit_id=u;
 d:=greatest(p_from,(now() at time zone 'America/Denver')::date,pr.delivery_not_before,(pr.pickup_window_start at time zone 'America/Denver')::date);
 for i in 0..104 loop
  if extract(isodow from d)::integer=any(days) and (d+time '14:00') at time zone 'America/Denver'>now()+interval '1 hour' then
   select * into r from public.pick_return_routes where unit_id=u and route_date=d and leg='Return';
   select count(*) into n from public.pick_return_stops where route_id=r.id and status<>'Cancelled';
   if r.id is null or (not coalesce(r.status in ('Completed','Cancelled'),false) and r.confirmed_at is null and r.departed_at is null and r.started_at is null and n<r.delivery_capacity) then
    result:=result||jsonb_build_array(jsonb_build_object('date',d,'blocks',jsonb_build_array(jsonb_build_object('id',r.id,'number',coalesce(r.block_number,1),'count',n,'capacity',coalesce(r.delivery_capacity,20)))));
   end if;
  end if;
  d:=d+1;
 end loop;
 return result;
end $$;
create function public.assign_delivery_block(p_job uuid,p_day date) returns uuid language plpgsql security definer set search_path='' as $$
declare u uuid;a jsonb;sid uuid;rid uuid;start_at timestamptz;
begin
 select unit_id into u from public.jobs where id=p_job;
 perform pg_advisory_xact_lock(hashtextextended(u::text||'Return',0));
 perform 1 from public.jobs where id=p_job for update;
 a:=public.delivery_block_availability(p_job,p_day);
 if not exists(select 1 from jsonb_array_elements(a) x where (x->>'date')::date=p_day) then raise exception 'This date/block is no longer available';end if;
 start_at:=(p_day+time '14:00') at time zone 'America/Denver';
 update public.pick_return_orders set return_status='Delivery In Progress' where job_id=p_job;
 sid:=private.assign_route(p_job,'Return',start_at,start_at+interval '4 hours',start_at);
 if sid is null then raise exception 'Delivery could not be assigned';end if;
 select route_id into rid from public.pick_return_stops where id=sid;
 if not (select manual_stop_order from public.pick_return_routes where id=rid) then perform private.order_delivery_block(rid);end if;
 update public.pick_return_orders set return_reservation_stop_id=null,return_reservation_expires_at=null where job_id=p_job;
 perform private.rbac_log('delivery.block.assigned',rid,jsonb_build_object('job_id',p_job));
 return rid;
end $$;
create function public.save_delivery_block(p_route uuid,p_operator uuid,p_stops uuid[],p_removed uuid[],p_capacity integer default 20,p_reason text default null) returns void language plpgsql security definer set search_path='' as $$
declare r public.pick_return_routes;sid uuid;jid uuid;actual uuid[];
begin
 select * into r from public.pick_return_routes where id=p_route for update;
 if r.unit_id is distinct from '10000000-0000-0000-0000-000000000002'::uuid or r.leg<>'Return' or not private.has_block(r.unit_id,'pr.routes.plan') then raise exception 'Route planning permission required' using errcode='42501';end if;
 if r.departed_at is not null or r.started_at is not null or r.confirmed_at is not null or r.status in ('Completed','Cancelled') then raise exception 'An executing or closed block cannot be edited';end if;
 if exists(select 1 from public.pick_return_stops where route_id=r.id and status not in ('Scheduled','Cancelled','Requested')) then raise exception 'Resolve executing stops before editing';end if;
 if p_stops is null or p_removed is null or array_position(p_stops,null) is not null or array_position(p_removed,null) is not null then raise exception 'Invalid stop list';end if;
 select array_agg(id order by id) into actual from public.pick_return_stops where route_id=r.id and status<>'Cancelled';
 if coalesce(actual,'{}') is distinct from (select coalesce(array_agg(id order by id),'{}') from unnest(p_stops||p_removed) id) then raise exception 'The block changed; reopen it before saving';end if;
 if p_capacity<20 then raise exception 'Delivery capacity must be at least 20';end if;
 if p_capacity>20 and (p_capacity<>r.delivery_capacity or p_reason is distinct from r.capacity_authorization_reason) then
  perform private.require_owner(r.unit_id);
  if length(trim(coalesce(p_reason,'')))=0 then raise exception 'An Owner authorization reason is required';end if;
  update public.pick_return_routes set capacity_authorized_by=auth.uid(),capacity_authorization_reason=trim(p_reason),delivery_capacity=p_capacity where id=r.id;
  perform private.rbac_log('delivery.capacity.authorized',r.id,jsonb_build_object('capacity',p_capacity,'reason',p_reason));
 else update public.pick_return_routes set delivery_capacity=p_capacity where id=r.id;end if;
 if cardinality(p_stops)>p_capacity then raise exception 'Delivery block exceeds authorized capacity';end if;
 if p_operator is not null and not exists(select 1 from public.staff_access a where a.unit_id=r.unit_id and a.user_id=p_operator and a.active and exists(select 1 from public.user_roles ur join public.roles rr on rr.id=ur.role_id left join public.role_blocks b on b.role_id=ur.role_id where ur.user_id=a.user_id and ur.unit_id=r.unit_id and (rr.system_key='Owner' or b.block_key='driver.routes'))) then raise exception 'Choose an active authorized driver';end if;
 perform public.assign_route_operator(r.id,p_operator);
 foreach sid in array p_removed loop
  select job_id into jid from public.pick_return_stops where id=sid and route_id=r.id;
  update public.pick_return_stops set status='Cancelled' where id=sid;
  update public.pick_return_orders set return_status='Delivery In Progress',return_window_start=null,return_window_end=null,return_eta=null,updated_at=now() where job_id=jid;
 end loop;
 perform private.order_delivery_block(r.id,p_stops);
 update public.pick_return_routes set manual_stop_order=true where id=r.id;
 perform private.rbac_log('delivery.block.saved',r.id,jsonb_build_object('stops',p_stops,'removed',p_removed,'operator',p_operator));
end $$;

-- Retain public rescheduling for already assigned deliveries, but initial/retry scheduling belongs to the shop.
alter function public.route_schedule(uuid,text,date,timestamptz,text) rename to route_schedule_before_shop_blocks;
create function public.route_schedule(p_job uuid,p_leg text,p_day date,p_eta timestamptz,p_token text default null) returns uuid language plpgsql security definer set search_path='' as $$
begin
 perform private.route_actor(p_job,p_token);
 if p_leg='Return' and private.shop_delivery_enabled(p_job) and not exists(select 1 from public.pick_return_stops s join public.pick_return_routes r on r.id=s.route_id where s.job_id=p_job and r.leg='Return' and s.status='Scheduled') then raise exception 'ToolTag will schedule your delivery from the shop';end if;
 return public.route_schedule_before_shop_blocks(p_job,p_leg,p_day,p_eta,p_token);
end $$;
revoke all on function public.route_schedule_before_shop_blocks(uuid,text,date,timestamptz,text) from public,anon,authenticated;
revoke all on function public.route_schedule(uuid,text,date,timestamptz,text) from public;
grant execute on function public.route_schedule(uuid,text,date,timestamptz,text) to anon,authenticated;
revoke all on function public.delivery_block_availability(uuid,date),public.assign_delivery_block(uuid,date),public.save_delivery_block(uuid,uuid,uuid[],uuid[],integer,text) from public,anon;
grant execute on function public.delivery_block_availability(uuid,date),public.assign_delivery_block(uuid,date),public.save_delivery_block(uuid,uuid,uuid[],uuid[],integer,text) to authenticated;
revoke all on function private.shop_delivery_enabled(uuid),private.delivery_retry_paid(uuid),private.delivery_queue_eligible(uuid),private.delivery_block_capacity_guard(),private.order_delivery_block(uuid,uuid[]),private.auto_return(uuid,date),private.reserve_return_retry(uuid,uuid),private.reconcile_delivery(uuid) from public,anon,authenticated;

create function public.delivery_queue_state() returns jsonb language plpgsql stable security definer set search_path='' as $$
declare u uuid:='10000000-0000-0000-0000-000000000002';
begin
 if not private.has_any(u,array['pr.routes.plan','pr.routes.live','pr.returns','pr.reschedule']) then raise exception 'Delivery operations permission required' using errcode='42501';end if;
 return coalesce((select jsonb_agg(jsonb_build_object('job',p.job_id,'eligible',private.delivery_queue_eligible(p.job_id),'retry_paid',private.delivery_retry_paid(p.job_id),'awaiting_resolution',p.delivery_attempts>0 and p.returned_at is null and p.delivery_payment_status<>'Shop Pickup' and not private.delivery_retry_paid(p.job_id) and (p.return_reservation_expires_at is null or p.return_reservation_expires_at>now()))) from public.pick_return_orders p where p.unit_id=u and p.service_method in ('Pickup & Delivery','Drop-off + Delivery')),'[]');
end $$;
revoke all on function public.delivery_queue_state() from public,anon;
grant execute on function public.delivery_queue_state() to authenticated;

-- Update generated notices, never the published Customer Agreement.
do $patch$
declare f record;definition text;
begin
 for f in select p.oid from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname in ('public','private') and p.prokind='f' and p.prosrc like '%A provisional place is reserved for %' loop
  definition:=pg_get_functiondef(f.oid);
  definition:=replace(definition,$old$'Delivery pending. Nothing was left at the door. A provisional place is reserved for '||to_char(pr.return_window_start at time zone 'America/Denver','FMDay, FMMonth DD, YYYY')||'. Confirm the second attempt by paying $'$old$,$new$'Delivery pending. Nothing was left at the door. Choose a second attempt by paying $'$new$);
  definition:=replace(definition,' before the route payment cutoff, or choose free shop pickup. Unpaid reservations are released at the cutoff or after 15 days, whichever comes first.',' or choose free shop pickup. After payment, ToolTag will schedule the delivery from the shop. Unresolved requests move to free shop pickup after 15 days.');
  execute definition;
 end loop;
 for f in select p.oid from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='private' and p.prokind='f' and p.prosrc like '%Your Return route is assigned%' loop
  definition:=replace(pg_get_functiondef(f.oid),'Your Return route is assigned','Your delivery is awaiting scheduling from the shop');execute definition;
 end loop;
end $patch$;

-- Include former operators for history, but only active authorized drivers can be selected.
create function public.delivery_block_drivers() returns jsonb language plpgsql stable security definer set search_path='' as $$
declare u uuid:='10000000-0000-0000-0000-000000000002';
begin
 if not private.has_any(u,array['pr.routes.plan','pr.routes.live','pr.returns','pr.reschedule']) then raise exception 'Delivery operations permission required' using errcode='42501';end if;
 return coalesce((select jsonb_agg(jsonb_build_object('id',a.user_id,'name',coalesce(nullif(a.display_name,''),'Driver'),'selectable',a.active and exists(select 1 from public.user_roles ur join public.roles r on r.id=ur.role_id left join public.role_blocks b on b.role_id=ur.role_id where ur.user_id=a.user_id and ur.unit_id=u and (r.system_key='Owner' or b.block_key='driver.routes')))) from public.staff_access a where a.unit_id=u and (exists(select 1 from public.pick_return_routes r where r.unit_id=u and r.leg='Return' and r.operator_id=a.user_id) or exists(select 1 from public.user_roles ur join public.roles r on r.id=ur.role_id left join public.role_blocks b on b.role_id=ur.role_id where ur.user_id=a.user_id and ur.unit_id=u and (r.system_key='Owner' or b.block_key='driver.routes')))),'[]');
end $$;
revoke all on function public.delivery_block_drivers() from public,anon;
grant execute on function public.delivery_block_drivers() to authenticated;

do $patch$
declare d text;
begin
 d:=pg_get_functiondef('public.choose_second_return(uuid,text)'::regprocedure);
 d:=replace(d,'Your provisional second delivery is pending. Its reservation is confirmed only after the additional fee is paid and verified.','Your second delivery is pending. After the additional fee is paid and verified, ToolTag will schedule your delivery from the shop.');execute d;
 d:=pg_get_functiondef('private.release_return_reservation(uuid)'::regprocedure);
 d:=replace(d,'Your provisional second Return was not paid in time and the reserved place has been released.','Your second delivery was not paid within the resolution period.');execute d;
 d:=pg_get_functiondef('private.reconcile_delivery_before_shop_blocks(uuid)'::regprocedure);
 d:=replace(d,'Your delivery has moved to the next available delivery route day because payment was not confirmed by the final cutoff. See your updated schedule.','Your delivery is awaiting rescheduling from the shop because payment was not confirmed by the final cutoff. ToolTag will confirm your new delivery date.');execute d;
end $patch$;

-- Driver-interruption reschedules also return to the shop queue; Pickup keeps its existing flow.
alter function private.reschedule_incident_job(uuid,uuid) rename to reschedule_incident_job_before_shop_blocks;
create function private.reschedule_incident_job(p_incident uuid,p_job uuid) returns void language plpgsql security definer set search_path='' as $$
declare r public.pick_return_routes;
begin
 select rr.* into r from public.pick_return_routes rr join public.route_incidents i on i.route_id=rr.id where i.id=p_incident;
 if r.leg<>'Return' or not private.shop_delivery_enabled(p_job) then perform private.reschedule_incident_job_before_shop_blocks(p_incident,p_job);return;end if;
 update public.pick_return_stops set status='Cancelled' where job_id=p_job and route_id=r.id and status in ('Scheduled','En Route','Arrived');
 perform private.auto_return(p_job,greatest(r.route_date+1,(now() at time zone 'America/Denver')::date));
 update public.route_incident_jobs set choice='Reschedule' where incident_id=p_incident and job_id=p_job;
 perform private.queue_route_compensation(p_incident,p_job,10);
 perform private.route_notice(p_job,'ROUTE_RESCHEDULED','incident-reschedule:'||p_incident||':'||p_job,'We are sorry for the interruption. Your delivery is awaiting rescheduling from the shop at no extra charge. ToolTag will confirm the new date. A $10 refund is due. Check your status page for refund progress.');
end $$;
revoke all on function private.reschedule_incident_job(uuid,uuid) from public,anon,authenticated;
notify pgrst,'reload schema';
