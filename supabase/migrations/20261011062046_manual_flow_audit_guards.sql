alter table public.jobs drop constraint jobs_customer_stage_check;
alter table public.jobs add CONSTRAINT jobs_customer_stage_check CHECK ((customer_stage = ANY (ARRAY['Received at Shop'::text, 'In Process'::text, 'Engraving'::text, 'Final Details'::text, 'Completed'::text])));
alter table public.jobs drop constraint jobs_work_stage_check;
alter table public.jobs add CONSTRAINT jobs_work_stage_check CHECK ((work_stage = ANY (ARRAY['Received at Shop'::text, 'Not Started'::text, 'Receiving Evidence'::text, 'Preparing'::text, 'Engraving'::text, 'Final Evidence'::text, 'Final Details'::text, 'Delivery In Progress'::text, 'Awaiting Delivery Acceptance'::text, 'Issue Review'::text, 'Payment'::text, 'Payment Verification'::text, 'Closed'::text, 'Cancellation Requested / Production Hold'::text])));
-- Additive manual audit: immutable commercial snapshots and applied migrations remain unchanged.
alter table public.job_items add column shop_received_at timestamptz, add column shop_received_by uuid references auth.users(id);
alter table public.pick_return_routes add column live_channel uuid not null default gen_random_uuid();
create table private.route_item_checks (
 stop_id uuid not null references public.pick_return_stops(id) on delete cascade,
 item_id uuid not null references public.job_items(id) on delete cascade,
 kind text not null check(kind in ('Loaded','Returned')),
 checked_by uuid not null references auth.users(id), checked_at timestamptz not null default now(),
 primary key(stop_id,item_id,kind)
);
alter table private.route_item_checks enable row level security;
revoke all on private.route_item_checks from public,anon,authenticated;
create table private.customer_extra_addresses (
 customer_id uuid not null references public.customers(id) on delete cascade,
 address text not null check(length(address) between 1 and 500), created_at timestamptz not null default now(),
 primary key(customer_id,address)
);
alter table private.customer_extra_addresses enable row level security;
revoke all on private.customer_extra_addresses from public,anon,authenticated;

create function private.audit_status_job(p_token text) returns public.jobs language plpgsql security definer set search_path='' as $$
declare j public.jobs;
begin
 select x.* into j from public.jobs x join private.job_status_links l on l.job_id=x.id
 where l.token_hash=encode(sha256(convert_to(coalesce(p_token,''),'UTF8')),'hex');
 if j.id is null then raise exception 'Status link unavailable';end if;return j;
end $$;
revoke all on function private.audit_status_job(text) from public;

-- Realtime carries only empty invalidation messages. Capability topics cannot be enumerated;
-- possession of the current status token is still required for every read/action.
create function public.status_live_channel(p_token text) returns text language plpgsql security definer set search_path='' as $$
declare j public.jobs;
begin j:=private.audit_status_job(p_token);return 'tt-status:'||encode(sha256(convert_to(p_token,'UTF8')),'hex');end $$;
revoke all on function public.status_live_channel(text) from public;
grant execute on function public.status_live_channel(text) to anon,authenticated;
create function public.route_live_channel(p_route uuid) returns text language plpgsql security definer set search_path='' as $$
declare r public.pick_return_routes;
begin select * into r from public.pick_return_routes where id=p_route;perform private.require_admin(r.unit_id);return 'tt-route:'||r.live_channel;end $$;
revoke all on function public.route_live_channel(uuid) from public;
grant execute on function public.route_live_channel(uuid) to authenticated;

create function private.audit_live_change() returns trigger language plpgsql security definer set search_path='' as $$
declare jid uuid; rid uuid; topic text; jobrow record; routes record;
begin
 if tg_table_name='jobs' then jid:=new.id;
 elsif tg_table_name='job_items' then jid:=new.job_id;
 elsif tg_table_name='pick_return_routes' then rid:=new.id;
 else jid:=new.job_id;rid:=new.route_id;end if;
 for jobrow in select l.token_hash from private.job_status_links l where l.job_id=jid or exists(select 1 from public.pick_return_stops s where s.route_id=rid and s.job_id=l.job_id) loop
  perform realtime.send('{}'::jsonb,'refresh','tt-status:'||jobrow.token_hash,false);
 end loop;
 for routes in select distinct r.live_channel from public.pick_return_routes r where r.id=rid or exists(select 1 from public.pick_return_stops s where s.job_id=jid and s.route_id=r.id) loop
  perform realtime.send('{}'::jsonb,'refresh','tt-route:'||routes.live_channel,false);
 end loop;
 return new;
end $$;
revoke all on function private.audit_live_change() from public;
create trigger audit_live_job after update on public.jobs for each row execute function private.audit_live_change();
create trigger audit_live_item after update on public.job_items for each row execute function private.audit_live_change();
create trigger audit_live_stop after insert or update on public.pick_return_stops for each row execute function private.audit_live_change();
create trigger audit_live_route after update on public.pick_return_routes for each row execute function private.audit_live_change();

create function public.customer_arrival_response(p_token text,p_leg text) returns void language plpgsql security definer set search_path='' as $$
declare j public.jobs;s public.pick_return_stops;
begin
 j:=private.audit_status_job(p_token);
 if p_leg not in ('Pickup','Return') then raise exception 'Invalid leg';end if;
 select ss.* into s from public.pick_return_stops ss join public.pick_return_routes r on r.id=ss.route_id
 where ss.job_id=j.id and r.leg=p_leg and ss.status='Arrived' order by ss.created_at desc limit 1 for update of ss;
 if s.id is null then raise exception 'Your driver is not at this stop';end if;
 update public.pick_return_stops set
 customer_coming_at=case when p_leg='Pickup' then coalesce(customer_coming_at,now()) else customer_coming_at end,
 pickup_wait_until=case when p_leg='Pickup' then null else pickup_wait_until end,
 return_customer_coming_at=case when p_leg='Return' then coalesce(return_customer_coming_at,now()) else return_customer_coming_at end,
 return_wait_until=case when p_leg='Return' then null else return_wait_until end where id=s.id;
end $$;
revoke all on function public.customer_arrival_response(text,text) from public;
grant execute on function public.customer_arrival_response(text,text) to anon,authenticated;

create function public.customer_delivery_acknowledge(p_token text) returns jsonb language plpgsql security definer set search_path='' as $$
declare j public.jobs; t text;
begin j:=private.audit_status_job(p_token);
 if not exists(select 1 from public.pick_return_orders where job_id=j.id and returned_at is not null) and j.delivered_at is null then raise exception 'Delivery has not occurred';end if;
 select token into t from private.job_mail_links where job_id=j.id;
 if t is null then raise exception 'Delivery acknowledgment unavailable';end if;
 return public.public_completion(t,'accept');
end $$;
revoke all on function public.customer_delivery_acknowledge(text) from public;
grant execute on function public.customer_delivery_acknowledge(text) to anon,authenticated;

create function public.verify_shop_item(p_item uuid) returns void language plpgsql security definer set search_path='' as $$
declare wi public.job_items;j public.jobs;
begin
 select * into wi from public.job_items where id=p_item for update;
 select * into j from public.jobs where id=wi.job_id for update;perform private.require_admin(j.unit_id);
 if not exists(select 1 from public.pick_return_orders where job_id=j.id and pickup_status='Picked Up') then raise exception 'Pickup has not completed';end if;
 if not exists(select 1 from public.documents where job_id=j.id and type='Receiving Evidence' and status='Available') then raise exception 'Review receiving photos before verifying items';end if;
 update public.job_items set shop_received_at=coalesce(shop_received_at,now()),shop_received_by=coalesce(shop_received_by,auth.uid()) where id=wi.id;
 if not exists(select 1 from public.job_items where job_id=j.id and stage<>'Cancelled' and shop_received_at is null) then
  update public.jobs set work_stage='Receiving Evidence',customer_stage='Received at Shop',updated_at=now() where id=j.id and work_stage in ('Received at Shop','Receiving Evidence','Not Started');
 end if;
end $$;
revoke all on function public.verify_shop_item(uuid) from public;
grant execute on function public.verify_shop_item(uuid) to authenticated;

create function public.verify_route_items(p_stop uuid,p_kind text,p_items uuid[]) returns void language plpgsql security definer set search_path='' as $$
declare s public.pick_return_stops; r public.pick_return_routes; item uuid;
begin
 select * into s from public.pick_return_stops where id=p_stop for update;
 select * into r from public.pick_return_routes where id=s.route_id for update;
 perform private.require_admin(r.unit_id);
 if r.leg<>'Return' or p_kind not in ('Loaded','Returned') or r.confirmed_at is not null then raise exception 'Verification unavailable';end if;
 if p_kind='Loaded' and (r.departed_at is not null or s.status not in ('Scheduled','En Route')) then raise exception 'Verify items before departure';end if;
 if p_kind='Returned' and s.status<>'Failed' then raise exception 'Only undelivered items can be returned';end if;
 if coalesce(cardinality(p_items),0)=0 or exists(select 1 from unnest(p_items) x where not exists(select 1 from public.job_items where id=x and job_id=s.job_id and stage<>'Cancelled')) then raise exception 'Invalid item list';end if;
 foreach item in array p_items loop
 insert into private.route_item_checks(stop_id,item_id,kind,checked_by) values(s.id,item,p_kind,auth.uid()) on conflict do nothing;
 end loop;
end $$;
revoke all on function public.verify_route_items(uuid,text,uuid[]) from public;
grant execute on function public.verify_route_items(uuid,text,uuid[]) to authenticated;
create function public.route_item_checklist(p_route uuid,p_kind text) returns jsonb language plpgsql security definer set search_path='' as $$
declare r public.pick_return_routes;result jsonb;
begin
 select * into r from public.pick_return_routes where id=p_route;perform private.require_admin(r.unit_id);
 if p_kind not in ('Loaded','Returned') then raise exception 'Invalid checklist';end if;
 select coalesce(jsonb_agg(jsonb_build_object('stop',s.id,'name',c.name,'job',j.code,'items',(select coalesce(jsonb_agg(jsonb_build_object('id',i.id,'article',i.article,'sequence',i.sequence,'checked',exists(select 1 from private.route_item_checks ck where ck.stop_id=s.id and ck.item_id=i.id and ck.kind=p_kind)) order by i.sequence),'[]') from public.job_items i where i.job_id=j.id and i.stage<>'Cancelled')) order by s.sequence),'[]') into result
 from public.pick_return_stops s join public.jobs j on j.id=s.job_id join public.commercial_flows f on f.id=j.flow_id join public.customers c on c.id=f.customer_id
 where s.route_id=r.id and ((p_kind='Loaded' and s.status in ('Scheduled','En Route','Arrived')) or (p_kind='Returned' and s.status='Failed'));
 return result;
end $$;
revoke all on function public.route_item_checklist(uuid,text) from public;
grant execute on function public.route_item_checklist(uuid,text) to authenticated;


create or replace function public.advance_job_item(p_item uuid,p_action text)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  wi public.job_items;
  j public.jobs;
  current_sequence integer;
  remaining integer;
  prog jsonb;
  delivery boolean;
  next_item uuid;
begin
  select * into wi from public.job_items where id=p_item for update;
  if wi.id is null then raise exception 'Job item not found'; end if;

  select * into j from public.jobs where id=wi.job_id for update;
  perform private.require_admin(j.unit_id);

  if exists(
    select 1 from public.cancellation_requests c
    where c.job_id=j.id and c.status='Requested'
  ) then
    update public.jobs
    set work_stage='Cancellation Requested / Production Hold',updated_at=now()
    where id=j.id and status<>'Cancelled';

    return jsonb_build_object(
      'blocked',true,'reason','Cancellation request detected',
      'progress',private.job_item_progress(j.id)
    );
  end if;

  if j.status='Cancelled' then raise exception 'This Job is cancelled'; end if;

  select min(sequence) into current_sequence
  from public.job_items
  where job_id=j.id and stage not in ('Finished','Cancelled');

  if current_sequence is distinct from wi.sequence then
    raise exception 'Finish the current item before moving to another item';
  end if;

  if j.work_stage='Cancellation Requested / Production Hold' then
    update public.jobs
    set work_stage=case when wi.stage='Preparation' then 'Preparing' else 'Engraving' end,
        updated_at=now()
    where id=j.id;
  end if;

  if exists(select 1 from public.pick_return_orders where job_id=j.id and service_method in ('Pickup Only','Pickup & Delivery')) and exists(select 1 from public.job_items where job_id=j.id and stage<>'Cancelled' and shop_received_at is null) then raise exception 'Shop must verify every received item before production';end if;
  if p_action in ('next','preparation-done') and wi.stage='Preparation' then
    update public.job_items
    set stage='Engraving',
        preparation_started_at=coalesce(preparation_started_at,now()),
        engraving_started_at=coalesce(engraving_started_at,now()),
        updated_at=now()
    where id=wi.id;

    update public.jobs
    set status='In Process',work_stage='Engraving',
        customer_stage='Engraving',updated_at=now()
    where id=j.id;

  elsif p_action='finished' and wi.stage='Finished Evidence' then
    update public.job_items
    set stage='Finished',
        finished_at=coalesce(finished_at,now()),
        completed_at=coalesce(completed_at,now()),
        updated_at=now()
    where id=wi.id;

    select id into next_item
    from public.job_items
    where job_id=j.id and stage='Preparation'
    order by sequence limit 1;

    if next_item is not null then
      update public.job_items
      set preparation_started_at=coalesce(preparation_started_at,now()),
          updated_at=now()
      where id=next_item;
    end if;

    select count(*) into remaining
    from public.job_items
    where job_id=j.id and stage not in ('Finished','Cancelled');

    if remaining=0 then
      if exists(select 1 from public.quote_logistics where quote_id=j.quote_id) then
        select exists(
          select 1 from public.quote_logistics
          where quote_id=j.quote_id
            and option_code in ('pickup_delivery','dropoff_delivery')
        ) into delivery;
      else
        select exists(
          select 1 from public.pick_return_orders where job_id=j.id
        ) into delivery;
      end if;

      if delivery then
        update public.pick_return_orders
        set return_status='Delivery In Progress',updated_at=now()
        where job_id=j.id;

        update public.jobs
        set work_stage='Delivery In Progress',
            customer_stage='Final Details',updated_at=now()
        where id=j.id;

        insert into public.notifications(
          unit_id,event,entity_id,recipient,dedupe_key,payload
        )
        select
          j.unit_id,'DELIVERY_IN_PROGRESS',j.id,a.accepted_email,
          'delivery-in-progress:'||j.id,
          jsonb_build_object(
            'template','notification',
            'subject','Delivery in progress — '||j.code,
            'text','Your ToolTag Job is finished and has entered the delivery process.',
            'live_eligible',true
          )
        from public.agreements a
        where a.job_id=j.id
        order by a.accepted_at desc
        limit 1
        on conflict do nothing;
      else
        update public.jobs
        set work_stage='Final Details',
            customer_stage='Final Details',updated_at=now()
        where id=j.id;
      end if;
    else
      update public.jobs
      set work_stage='Engraving',customer_stage='Engraving',updated_at=now()
      where id=j.id;
    end if;
  else
    raise exception 'Invalid item transition';
  end if;

  prog:=private.job_item_progress(j.id);
  return jsonb_build_object(
    'blocked',false,'job_id',j.id,'item_id',wi.id,'progress',prog
  );
end $$;

create or replace function private.auto_return(p_job uuid,p_after date default null) returns uuid language plpgsql security definer set search_path='' as $$
declare j public.jobs; a jsonb; d date; sid uuid; chosen timestamptz;
begin
 select * into j from public.jobs where id=p_job for update;
 perform pg_advisory_xact_lock(hashtextextended(j.unit_id::text||'Return',0));
 d:=greatest(coalesce(p_after,(now() at time zone 'America/Denver')::date),(now() at time zone 'America/Denver')::date,(select (pickup_window_start at time zone 'America/Denver')::date from public.pick_return_orders where job_id=j.id));
 a:=public.route_availability(j.id,'Return',d,private.ensure_job_status_link(j.id));
 select (slot->>'eta')::timestamptz into chosen from jsonb_array_elements(a->'slots') slot order by (select count(*) from public.pick_return_stops ss join public.pick_return_routes r on r.id=ss.route_id where r.unit_id=j.unit_id and r.leg='Return' and ss.eta=(slot->>'eta')::timestamptz and ss.status not in ('Cancelled','Failed')), (slot->>'eta')::timestamptz limit 1;
 sid:=private.assign_route(j.id,'Return',(a->>'window_start')::timestamptz,(a->>'window_end')::timestamptz,chosen);
 return sid;
end $$;

create or replace function public.route_availability(p_job uuid,p_leg text,p_day date,p_token text default null) returns jsonb language plpgsql security definer set search_path='' as $$
declare j public.jobs; pr public.pick_return_orders; d date; start_at timestamptz; cap integer; slots jsonb; n integer; fee_stamp timestamptz; route_days integer[];
begin
 j:=private.route_actor(p_job,p_token);
 select * into pr from public.pick_return_orders where job_id=j.id;
 if pr.job_id is null or p_leg not in ('Pickup','Return') then raise exception 'Route unavailable'; end if;
 if p_day is null or p_day < (now() at time zone 'America/Denver')::date then raise exception 'Choose a future date'; end if;
 d:=greatest(p_day,case when p_leg='Return' then (pr.pickup_window_start at time zone 'America/Denver')::date else p_day end);
 select case when p_leg='Pickup' then coalesce(max_pickup_stops_per_saturday,10) else max_delivery_stops_per_sunday end into cap from public.unit_settings where unit_id=j.unit_id;
 select case when p_leg='Pickup' then pickup_route_iso_weekdays else return_route_iso_weekdays end into route_days from public.unit_settings where unit_id=j.unit_id;
 select max(p.confirmed_at) into fee_stamp from public.payment_requests p where job_id=j.id and status='Confirmed' and purpose in ('Pickup Fee','Logistics Fee','Logistics Full Prepayment');
 for n in 0..104 loop
  if not (extract(isodow from d)::integer = any(route_days)) then d:=d+1;continue;end if;
  start_at:=(d+case when p_leg='Pickup' then time '08:00' else time '14:00' end) at time zone 'America/Denver';
  if start_at<=now()+(case when p_leg='Return' then interval '1 hour' when pr.fee_status<>'Confirmed' or coalesce(fee_stamp,pr.created_at)>start_at-interval '48 hours' then interval '48 hours' else interval '24 hours' end) then d:=d+1;continue;end if;
  select coalesce(jsonb_agg(jsonb_build_object('eta',eta,'label',to_char(eta at time zone 'America/Denver','FMHH12:MI AM')) order by eta),'[]') into slots
  from generate_series(start_at,start_at+interval '4 hours',interval '20 minutes') as slots_at(eta)
  where (select count(*) from public.pick_return_stops s join public.pick_return_routes r on r.id=s.route_id where r.unit_id=j.unit_id and r.route_date=d and r.leg=p_leg and s.job_id<>j.id and s.status not in ('Cancelled','Failed'))<cap
  and (select count(*) from public.pick_return_stops s join public.pick_return_routes r on r.id=s.route_id where r.unit_id=j.unit_id and r.route_date=d and r.leg=p_leg and s.eta=slots_at.eta and s.job_id<>j.id and s.status not in ('Cancelled','Failed')) < case when p_leg='Pickup' then 1 else cap end;
  if jsonb_array_length(slots)>0 then return jsonb_build_object('route_iso_weekdays',to_jsonb(route_days),'route_iso_weekday',extract(isodow from d)::integer,'day',d,'slots',slots,'window_start',start_at,'window_end',start_at+interval '4 hours','moved',d<>p_day);end if;
  d:=d+1;
 end loop;
 raise exception 'No route availability';
end $$;

create or replace function public.report_driver_incident(p_route uuid) returns uuid language plpgsql security definer set search_path='' as $$
declare r public.pick_return_routes;i public.route_incidents;s public.pick_return_stops;
begin
 select * into r from public.pick_return_routes where id=p_route for update;
 if r.id is null or not exists(select 1 from public.business_units where id=r.unit_id and code='TOOLTAG') then raise exception 'Route unavailable';end if;perform private.require_admin(r.unit_id);
 if exists(select 1 from public.pick_return_stops where route_id=r.id and status='Arrived') then raise exception 'Resolve the arrived stop before reporting driver unavailable';end if;
 select * into i from public.route_incidents where route_id=r.id;
 if i.id is not null then return i.id;end if;
 if r.status in ('Cancelled','Completed') or r.confirmed_at is not null then raise exception 'Route is closed';end if;
 if not exists(select 1 from public.pick_return_stops where route_id=r.id and status in ('Scheduled','En Route','Arrived')) then raise exception 'No remaining confirmed stops';end if;
 insert into public.route_incidents(unit_id,route_id) values(r.unit_id,r.id) returning * into i;
 for s in select * from public.pick_return_stops where route_id=r.id and status in ('Scheduled','En Route','Arrived') order by sequence loop
  insert into public.route_incident_jobs(incident_id,unit_id,job_id,stop_id) values(i.id,r.unit_id,s.job_id,s.id);
  perform private.route_notice(s.job_id,'ROUTE_INTERRUPTED','route-incident:'||i.id||':'||s.job_id,'We are sorry: our driver is unable to continue right now. ToolTag will confirm within 15 minutes whether a replacement can continue or your service moves to the next available '||case when r.leg='Pickup' then 'Pickup route day' else 'delivery route day' end||'. If a replacement is available, you may wait approximately one hour with a $5 refund, or reschedule. If no driver is available, a $10 refund is due; '||case when r.leg='Pickup' then 'Pickup will be rescheduled free of charge. You do not need to bring your pieces to the shop.' else 'you may collect your items at the shop for free.' end||' Refunds go back to your original payment method when its provider supports automatic refunds; otherwise ToolTag must issue the payment. Follow your status page.');
 end loop;
 return i.id;
end $$;

create or replace function public.confirm_pick_return_route(p_route uuid) returns void language plpgsql security definer set search_path='' as $$
declare r public.pick_return_routes;
begin
 select * into r from public.pick_return_routes where id=p_route for update;
 perform private.require_admin(r.unit_id);
 if r.confirmed_at is not null then return;end if;
 if not exists(select 1 from public.pick_return_stops where route_id=r.id and status in ('Completed','Failed')) or exists(select 1 from public.pick_return_stops where route_id=r.id and status not in ('Completed','Failed','Cancelled')) then raise exception 'Resolve every stop before confirming the route';end if;
 if r.leg='Pickup' and exists(select 1 from public.pick_return_stops s join public.job_items i on i.job_id=s.job_id where s.route_id=r.id and s.status='Completed' and i.stage<>'Cancelled' and i.shop_received_at is null) then raise exception 'Shop must verify every received item before closing the route';end if;
 if r.leg='Return' and exists(select 1 from public.pick_return_stops s join public.job_items i on i.job_id=s.job_id where s.route_id=r.id and s.status='Failed' and i.stage<>'Cancelled' and not exists(select 1 from private.route_item_checks ck where ck.stop_id=s.id and ck.item_id=i.id and ck.kind='Returned')) then raise exception 'Return all undelivered items to the shop and verify each item before closing';end if;
 update public.pick_return_routes set status='Completed',completed_at=now(),confirmed_at=now() where id=r.id;
end $$;

create or replace function public.depart_driver_route(p_route uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare r public.pick_return_routes;s public.pick_return_stops;counted integer:=0;
begin
 select * into r from public.pick_return_routes where id=p_route for update;
 if r.id is null then raise exception 'Route unavailable';end if;
 perform private.require_admin(r.unit_id);
 if r.departed_at is not null then return jsonb_build_object('ok',true,'already_departed',true);end if;
 if r.status in ('Completed','Cancelled') or r.confirmed_at is not null then raise exception 'Route is closed';end if;
 if r.leg='Return' and exists(select 1 from public.pick_return_stops ss join public.jobs j on j.id=ss.job_id where ss.route_id=r.id and ss.status in ('Scheduled','En Route','Arrived') and (j.status='Cancelled' or j.work_stage like '%Production Hold%' or j.work_stage like '%Cancellation Requested%' or exists(select 1 from public.job_items i where i.job_id=j.id and i.stage not in ('Finished','Cancelled')) or exists(select 1 from public.job_extensions e where e.job_id=j.id and e.status in ('Requested','Draft','Sent')))) then raise exception 'Resolve unfinished work, extensions and holds before departure';end if;
 if r.leg='Return' and exists(select 1 from public.pick_return_stops ss join public.job_items i on i.job_id=ss.job_id where ss.route_id=r.id and ss.status in ('Scheduled','En Route','Arrived') and i.stage<>'Cancelled' and not exists(select 1 from private.route_item_checks ck where ck.stop_id=ss.id and ck.item_id=i.id and ck.kind='Loaded')) then raise exception 'Verify all items before leaving the shop';end if;
 if r.leg='Return' and exists(select 1 from public.pick_return_stops ss join public.pick_return_orders pr on pr.job_id=ss.job_id join public.job_commercial_totals b on b.id=ss.job_id where ss.route_id=r.id and ss.status in ('Scheduled','En Route','Arrived') and ((b.balance_due>0 and coalesce(pr.delivery_payment_method,'')<>'Cash') or exists(select 1 from public.delivery_attempt_fees f join public.sale_balances fb on fb.transaction_id=f.sale_id where f.job_id=ss.job_id and fb.balance_due>0))) then raise exception 'Only cash deliveries may leave with an unpaid balance; retry fees must be paid';end if;
 for s in select * from public.pick_return_stops where route_id=r.id and status in ('Scheduled','En Route','Arrived') order by sequence loop
  perform private.route_notice(s.job_id,case when r.leg='Pickup' then 'PICKUP_ROUTE_DEPARTED' else 'RETURN_ROUTE_DEPARTED' end,'route-departed:'||r.id||':'||s.id,'ToolTag is on the way. Our driver has left the shop for today’s '||case when r.leg='Pickup' then 'Pickup' else 'Return' end||' route. Follow your status page for updates.');
  counted:=counted+1;
 end loop;
 if counted=0 then raise exception 'No confirmed stops remain on this route';end if;
 update public.pick_return_routes set departed_at=now(),started_at=coalesce(started_at,now()),status='Active' where id=r.id;
 return jsonb_build_object('ok',true,'notified',counted);
end $$;

create or replace function private.quote_logistics_context(p_quote uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path=''
as $$
declare
  q public.quotes;
  c public.customers;
  l public.quote_logistics;
  predefined text;
  selected text;
  option_data jsonb;
  available jsonb:='[]'::jsonb;
  zone text;
  max_stops integer;
begin
  select * into q from public.quotes where id=p_quote;
  if q.id is null then return null; end if;

  select c0.* into c
  from public.commercial_flows f
  join public.customers c0 on c0.id=f.customer_id
  where f.id=q.flow_id;

  select * into l from public.quote_logistics where quote_id=q.id;
  predefined:=private.logistics_predefined(q.id);
  selected:=coalesce(l.option_code,predefined);
  option_data:=private.logistics_option(selected);

  select timezone,max_pickup_stops_per_saturday
  into zone,max_stops
  from public.unit_settings
  where unit_id=q.unit_id;

  if l.locked_at is null then
    select coalesce(jsonb_agg(x.obj order by x.route_date),'[]'::jsonb)
    into available
    from (
      select d.route_date,
             jsonb_build_object(
               'date',d.route_date,
               'remaining',greatest(max_stops-coalesce(used.used_stops,0),0),
               'window','8:00 AM–12:00 PM'
             ) obj
      from (
        select gs::date route_date
        from generate_series(
          ((now() at time zone zone)::date + 1)::timestamp,
          ((now() at time zone zone)::date + 70)::timestamp,
          interval '1 day'
        ) gs
        where extract(isodow from gs)::integer = any((select pickup_route_iso_weekdays from public.unit_settings where unit_id=q.unit_id)::integer[]) and ((gs::date+time '08:00') at time zone zone)>now()+interval '48 hours'
      ) d
      left join lateral (
        select count(*)::integer used_stops
        from public.pick_return_routes r
        join public.pick_return_stops s on s.route_id=r.id
        where r.unit_id=q.unit_id
          and r.route_date=d.route_date
          and r.leg='Pickup'
          and s.status not in ('Cancelled','Failed')
      ) used on true
      where coalesce(used.used_stops,0)<max_stops
      order by d.route_date
      limit 8
    ) x;
  end if;

  return jsonb_build_object('extra_addresses',(select coalesce(jsonb_agg(address order by created_at),'[]') from private.customer_extra_addresses where customer_id=c.id),
    'requires_selection',l.quote_id is null and predefined is null,
    'predefined',l.quote_id is null and predefined is not null,
    'selected_option',selected,
    'option',option_data,
    'options',jsonb_build_array(
      private.logistics_option('pickup_only'),
      private.logistics_option('pickup_delivery'),
      private.logistics_option('dropoff_pickup'),
      private.logistics_option('dropoff_delivery')
    ),
    'personal_address',nullif(trim(c.address),''),
    'company_address',nullif(trim(c.company_address),''),
    'pickup_address',l.pickup_address,
    'delivery_address',l.delivery_address,
    'saturday_date',l.saturday_date,
    'available_saturdays',available,
    'payment_status',l.payment_status,
    'payment_scope',l.payment_scope,
    'payment_method',l.payment_method,
    'locked',l.locked_at is not null
  );
end $$;

create or replace function public.accept_review_with_logistics(
  p_token text,
  p_quote_confirmed boolean,
  p_agreement_confirmed boolean,
  p_logistics jsonb
)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  jid uuid;
  q public.quotes;
  f public.commercial_flows;
  c public.customers;
  destination text;
  accepted_name text;
  accepted_email text;
  accepted_phone text;
  existing public.quote_logistics;
  predefined text;
  code text;
  opt jsonb;
  fee numeric(14,2);
  pickup_required boolean;
  delivery_required boolean;
  pickup_address text;
  delivery_address text;
  saturday date;
  zone text;
  max_stops integer;
  v_route_id uuid;
  stop_id uuid;
  used_stops integer;
  seq integer;
  window_start timestamptz;
  window_end timestamptz;
  agreement_version text;
begin
  if p_quote_confirmed is distinct from true
     or p_agreement_confirmed is distinct from true
  then
    raise exception 'Both quote and Agreement acknowledgments are required';
  end if;

  select x.* into q
  from public.quotes x
  join private.public_links l on l.quote_id=x.id
  where l.token_hash=encode(sha256(convert_to(p_token,'UTF8')),'hex')
  for update of x;

  if q.id is null then raise exception 'Quote is unavailable or expired'; end if;

  select * into existing from public.quote_logistics where quote_id=q.id;
  select a.job_id into jid from public.agreements a where a.quote_id=q.id;

  if jid is not null and existing.locked_at is not null then
    return jsonb_build_object(
      'job_id',jid,
      'payment_required',existing.fee_amount>0
        and existing.payment_status<>'paid_confirmed',
      'payment_status',existing.payment_status,
      'payment_path',case
        when existing.fee_amount>0
             and existing.payment_status<>'paid_confirmed'
        then '/review/'||p_token||'/payment'
        else null
      end
    );
  end if;

  if q.expires_at<=now()
     or q.status not in ('Sent','Viewed','Agreement Pending')
  then
    raise exception 'Quote is unavailable or expired';
  end if;

  select * into f from public.commercial_flows where id=q.flow_id;
  select * into c from public.customers where id=f.customer_id and unit_id=q.unit_id;
  select d.recipient into destination
  from private.quote_delivery d where d.quote_id=q.id;

  accepted_name:=coalesce(
    nullif(trim(q.review_snapshot->>'customer_name'),''),
    nullif(trim(c.name),'')
  );
  accepted_email:=coalesce(
    nullif(trim(destination),''),
    nullif(trim(q.review_snapshot->>'customer_email'),''),
    nullif(trim(c.email),'')
  );
  accepted_phone:=case
    when lower(coalesce(accepted_email,''))=
         lower(coalesce(q.review_snapshot->'company'->>'email',c.company_email,''))
    then coalesce(
      nullif(trim(q.review_snapshot->'company'->>'phone'),''),
      nullif(trim(c.company_phone),''),
      nullif(trim(q.review_snapshot->>'customer_phone'),''),
      nullif(trim(c.phone),'')
    )
    else coalesce(
      nullif(trim(q.review_snapshot->>'customer_phone'),''),
      nullif(trim(c.phone),''),
      nullif(trim(q.review_snapshot->'company'->>'phone'),''),
      nullif(trim(c.company_phone),'')
    )
  end;

  if accepted_name is null
     or accepted_email is null
     or accepted_email !~* '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$'
     or accepted_phone is null
  then
    raise exception 'Customer contact information is incomplete; update the customer before accepting';
  end if;

  predefined:=private.logistics_predefined(q.id);
  code:=nullif(trim(coalesce(p_logistics->>'option_code','')),'');

  if predefined is not null then
    if code is not null and code<>predefined then
      raise exception 'The logistics method on this Quote is already defined';
    end if;
    code:=predefined;
  end if;

  opt:=private.logistics_option(code);
  if opt is null then raise exception 'Choose a logistics option'; end if;

  fee:=(opt->>'fee')::numeric;
  pickup_required:=(opt->>'pickup')::boolean;
  delivery_required:=(opt->>'delivery')::boolean;

  pickup_address:=nullif(trim(coalesce(p_logistics->>'pickup_address','')),'');
  delivery_address:=nullif(trim(coalesce(p_logistics->>'delivery_address','')),'');

  if pickup_required and pickup_address is null then
    pickup_address:=nullif(trim(coalesce(q.intake_details->'service'->>'address','')),'');
  end if;
  if code='pickup_delivery' and delivery_address is null then
    delivery_address:=pickup_address;
  end if;

  if pickup_required and pickup_address is null then
    raise exception 'Enter a Pickup address';
  end if;
  if delivery_required and delivery_address is null then
    raise exception 'Enter a delivery address';
  end if;

  if pickup_required then
    begin
      saturday:=nullif(p_logistics->>'saturday_date','')::date;
    exception when others then
      raise exception 'Choose an available Pickup date';
    end;

    select timezone,max_pickup_stops_per_saturday
    into zone,max_stops
    from public.unit_settings where unit_id=q.unit_id;

    if saturday is null
       or not (extract(isodow from saturday)::integer = any((select pickup_route_iso_weekdays from public.unit_settings where unit_id=q.unit_id)::integer[]))
       or ((saturday+time '08:00') at time zone zone)<=now()+interval '48 hours'
    then
      raise exception 'Choose an available Pickup date';
    end if;
  else
    saturday:=null;
    select timezone,max_pickup_stops_per_saturday
    into zone,max_stops
    from public.unit_settings where unit_id=q.unit_id;
  end if;

  insert into public.quote_logistics(
    quote_id,unit_id,option_code,fee_amount,
    pickup_address,delivery_address,saturday_date,payment_status
  )
  values(
    q.id,q.unit_id,code,fee,
    pickup_address,delivery_address,saturday,
    case when fee=0 then 'not_applicable' else 'pending' end
  );

  perform public.accept_quote(p_token);
  jid:=public.accept_agreement(
    p_token,accepted_name,accepted_email,accepted_phone
  );

  update public.quote_logistics
  set job_id=jid,locked_at=now()
  where quote_id=q.id;

  if fee>0 then
    select p.version::text into agreement_version
    from public.policies p where p.id=q.policy_id;

    insert into public.pick_return_orders(
      job_id,unit_id,service_method,fee_amount,fee_status,scheduler_enabled,
      pickup_status,return_status,terms_version,terms_snapshot
    )
    values(
      jid,q.unit_id,opt->>'name',fee,'Required',false,
      case when pickup_required then 'Not Scheduled' else 'Not Applicable' end,
      case when delivery_required then 'Not Ready' else 'Not Applicable' end,
      coalesce(agreement_version,'current'),
      (select content_snapshot from public.agreements where quote_id=q.id)
    )
    on conflict(job_id) do update set
      service_method=excluded.service_method,
      fee_amount=excluded.fee_amount,
      fee_status=case
        when public.pick_return_orders.fee_status='Confirmed' then 'Confirmed'
        else excluded.fee_status
      end,
      pickup_status=excluded.pickup_status,
      return_status=excluded.return_status,
      terms_version=excluded.terms_version,
      terms_snapshot=excluded.terms_snapshot,
      updated_at=now();
  end if;

  if pickup_required then
    insert into public.pick_return_routes(unit_id,route_date,leg)
    values(q.unit_id,saturday,'Pickup')
    on conflict(unit_id,route_date,leg)
    do update set route_date=excluded.route_date
    returning id into v_route_id;

    perform 1
    from public.pick_return_routes r
    where r.id=v_route_id
    for update;

    select count(*)::integer into used_stops
    from public.pick_return_stops s
    where s.route_id=v_route_id
      and s.status not in ('Cancelled','Failed');

    if used_stops>=max_stops then
      raise exception 'That Pickup date is at capacity; choose another date';
    end if;

    select coalesce(max(s.sequence),0)+1 into seq
    from public.pick_return_stops s
    where s.route_id=v_route_id;

    window_start:=(saturday+time '08:00') at time zone zone;
    window_end:=(saturday+time '12:00') at time zone zone;

    insert into public.pick_return_stops(
      unit_id,route_id,job_id,sequence,status,
      window_start,window_end,eta,address,customer_phone,customer_email,requested_at
    )
    values(
      q.unit_id,v_route_id,jid,seq,'Requested',
      window_start,window_end,null,pickup_address,
      accepted_phone,accepted_email,now()
    )
    returning id into stop_id;

    update public.quote_logistics
    set pickup_stop_id=stop_id
    where quote_id=q.id;
  end if;

  insert into public.notifications(
    unit_id,event,entity_id,dedupe_key,payload
  )
  select
    q.unit_id,
    'Drive commercial archive pending',
    q.id,
    'drive-commercial:'||q.id,
    jsonb_build_object(
      'job_id',jid,
      'quote_id',q.id,
      'agreement_id',a.id,
      'snapshot_hash',a.snapshot_hash,
      'folders',jsonb_build_array('Quote','Agreement')
    )
  from public.agreements a
  where a.quote_id=q.id
  on conflict do nothing;

  update public.notifications n
  set payload=jsonb_build_object(
    'template','confirmation',
    'template_version',1,
    'snapshot',a.commercial_snapshot,
    'job_code',j.code,
    'delivery','Pending Integration'
  )
  from public.agreements a
  join public.jobs j on j.id=a.job_id
  where n.dedupe_key='agreement:'||q.id
    and a.quote_id=q.id
    and n.payload='{}'::jsonb;

  if q.status<>'Accepted' then
    perform private.freeze_accepted_document(q.id);
  end if;

  if coalesce((p_logistics->>'save_pickup_address')::boolean,false) and length(trim(coalesce(p_logistics->>'pickup_address',''))) between 1 and 500 then insert into private.customer_extra_addresses(customer_id,address) values(c.id,trim(p_logistics->>'pickup_address')) on conflict do nothing;end if;
  if coalesce((p_logistics->>'save_delivery_address')::boolean,false) and length(trim(coalesce(p_logistics->>'delivery_address',''))) between 1 and 500 then insert into private.customer_extra_addresses(customer_id,address) values(c.id,trim(p_logistics->>'delivery_address')) on conflict do nothing;end if;
  return jsonb_build_object(
    'job_id',jid,
    'payment_required',fee>0,
    'payment_status',case when fee=0 then 'not_applicable' else 'pending' end,
    'payment_path',case when fee>0 then '/review/'||p_token||'/payment' else null end
  );
end $$;


create function private.audit_item_gate() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.stage is distinct from old.stage and new.stage not in ('Preparation','Cancelled') and exists(select 1 from public.pick_return_orders where job_id=new.job_id and service_method in ('Pickup Only','Pickup & Delivery')) and exists(select 1 from public.job_items where job_id=new.job_id and stage<>'Cancelled' and shop_received_at is null) then raise exception 'Shop must verify every received item before production';end if;return new;
end $$;
revoke all on function private.audit_item_gate() from public;
create trigger audit_item_gate before update of stage on public.job_items for each row execute function private.audit_item_gate();
create function private.audit_document_gate() returns trigger language plpgsql security definer set search_path='' as $$
begin if new.type='Delivery Evidence' and new.pick_return_stop_id is not null and not exists(select 1 from public.pick_return_stops where id=new.pick_return_stop_id and job_id=new.job_id and unit_id=new.unit_id and status='Arrived') then raise exception 'Arrive before adding delivery photos';end if;return new;end $$;
revoke all on function private.audit_document_gate() from public;
create trigger audit_document_gate before insert on public.documents for each row execute function private.audit_document_gate();


create or replace function public.public_job_status(p_token text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  j public.jobs;
  customer_name text;
  prog jsonb;
  pr jsonb;
  tracking_stage text;
  tracking_steps jsonb;
  pickup_status text;
  return_status text;
  hold_until_paid boolean:=false;
  cancellation public.cancellation_requests;
begin
  select x.* into j
  from public.jobs x
  join private.job_status_links l on l.job_id=x.id
  where l.token_hash=encode(sha256(convert_to(p_token,'UTF8')),'hex');

  if j.id is null then raise exception 'Status link unavailable'; end if;

  select c.name into customer_name
  from public.commercial_flows f
  join public.customers c on c.id=f.customer_id
  where f.id=j.flow_id;

  prog:=private.job_item_progress(j.id);

  select
    to_jsonb(x)-'unit_id'-'terms_snapshot',
    x.pickup_status,
    x.return_status,
    x.hold_until_paid
  into pr,pickup_status,return_status,hold_until_paid
  from public.pick_return_orders x
  where x.job_id=j.id;

  if j.status='Cancelled' then
    select * into cancellation
    from public.cancellation_requests c
    where c.job_id=j.id and c.status='Cancelled'
    order by c.cancelled_at desc,c.created_at desc
    limit 1;

    if cancellation.id is not null then
      prog:=jsonb_build_object(
        'total',cancellation.items_total,
        'started',cancellation.items_started,
        'finished',cancellation.items_finished,
        'cancelled',greatest(cancellation.items_total-cancellation.items_finished,0),
        'current_item_id',null,
        'current_sequence',null
      );
    end if;

    if pr is not null and pickup_status='Picked Up' then
      tracking_steps:=jsonb_build_array(
        'Cancelled',
        'Cancellation Balance',
        'Delivery In Progress',
        'Return Scheduled',
        'Out for Delivery',
        'Delivered'
      );

      tracking_stage:=case
        when return_status='Delivered' then 'Delivered'
        when return_status in ('En Route','Arrived') then 'Out for Delivery'
        when return_status='Scheduled' then 'Return Scheduled'
        when hold_until_paid then 'Cancellation Balance'
        else 'Delivery In Progress'
      end;
    else
      tracking_steps:=jsonb_build_array('Cancelled');
      tracking_stage:='Cancelled';
    end if;

  elsif pr is not null then
    tracking_steps:=jsonb_build_array(
      'Pickup Fee','Pickup Scheduled','Pickup In Progress','Picked Up',
      'In Process','Engraving','Delivery In Progress','Return Scheduled',
      'Out for Delivery','Delivered','Completed'
    );

    tracking_stage:=case
      when j.status='Completed' or j.work_stage='Closed' then 'Completed'
      when return_status='Delivered' then 'Delivered'
      when return_status in ('En Route','Arrived') then 'Out for Delivery'
      when return_status='Scheduled' then 'Return Scheduled'
      when return_status='Delivery In Progress' then 'Delivery In Progress'
      when j.customer_stage='Engraving' then 'Engraving'
      when pickup_status='Picked Up' then 'In Process'
      when pickup_status in ('En Route','Arrived') then 'Pickup In Progress'
      when pickup_status='Scheduled' then 'Pickup Scheduled'
      when coalesce(pr->>'fee_status','Required')<>'Confirmed' then 'Pickup Fee'
      else 'Pickup Scheduled'
    end;
  else
    tracking_steps:=jsonb_build_array(
      'In Process','Engraving','Final Details','Completed'
    );
    tracking_stage:=j.customer_stage;
  end if;

  if exists(select 1 from public.pick_return_orders where pick_return_orders.job_id=j.id and pick_return_orders.pickup_status='Picked Up') and exists(select 1 from public.job_items where job_id=j.id and stage<>'Cancelled' and shop_received_at is null) and j.status not in ('Cancelled','Completed') then tracking_stage:='Received at Shop';end if;
  if tracking_steps ? 'Picked Up' and not (tracking_steps ? 'Received at Shop') then select jsonb_agg(step order by ord) into tracking_steps from (select value step,ordinality::numeric ord from jsonb_array_elements(tracking_steps) with ordinality union all select to_jsonb('Received at Shop'::text),ordinality+0.5 from jsonb_array_elements_text(tracking_steps) with ordinality where value='Picked Up') x;end if;
  return jsonb_build_object(
    'id',j.id,
    'code',j.code,
    'customer_name',customer_name,
    'stage',j.customer_stage,
    'tracking_stage',case when pr->>'delivery_payment_status'='Pending Delivery' and j.status<>'Cancelled' then 'Pending Delivery' when pr->>'delivery_payment_status'='Shop Pickup' then 'Shop Pickup' else tracking_stage end,
    'job_status',j.status,
    'work_stage',j.work_stage,
    'updated_at',greatest(j.updated_at,(pr->>'updated_at')::timestamptz,(select max(coalesce(confirmed_at,submitted_at)) from public.payment_requests where job_id=j.id)),
    'items_total',coalesce((prog->>'total')::integer,0),
    'items_completed',coalesce((prog->>'finished')::integer,0),
    'items_started',coalesce((prog->>'started')::integer,0),
    'payment_proofs',(select coalesce(jsonb_agg(jsonb_build_object('id',id,'submitted_at',submitted_at)),'[]') from public.payment_requests where job_id=j.id and proof_path is not null),
    'item_progress',prog,
    'payment',private.job_payment_snapshot(j.id),
    'pickup_return',pr,
    'second_return_fee',(select second_delivery_attempt_fee from public.unit_settings where unit_id=j.unit_id),
    'second_return_chosen',exists(select 1 from public.delivery_attempt_fees where job_id=j.id),
    'cancelled',j.status='Cancelled',
    'steps',tracking_steps
  );
end $$;


create function private.audit_cutoff_reminders() returns void language plpgsql security definer set search_path='' as $$
declare s record;cutoff timestamptz;hours integer;due numeric;
begin
 for s in select ss.*,r.leg,pr.fee_status,pr.delivery_payment_method from public.pick_return_stops ss join public.pick_return_routes r on r.id=ss.route_id join public.pick_return_orders pr on pr.job_id=ss.job_id join public.business_units u on u.id=ss.unit_id where u.code='TOOLTAG' and ss.status in ('Requested','Scheduled','En Route') and r.confirmed_at is null loop
  select balance_due into due from public.job_commercial_totals where id=s.job_id;
  foreach hours in array case when s.leg='Pickup' then array[48,24] else array[24,1] end loop
   cutoff:=s.window_start-make_interval(hours=>hours);
   if now()>=cutoff-interval '24 hours' and now()<cutoff and ((s.leg='Pickup' and ((hours=48 and s.fee_status<>'Confirmed') or (hours=24 and s.status='Requested'))) or (s.leg='Return' and coalesce(due,0)>0 and coalesce(s.delivery_payment_method,'')<>'Cash')) then
    perform private.route_notice(s.job_id,'PAYMENT_DUE','audit-cutoff:'||s.id||':'||s.window_start||':'||hours,'Payment deadline: '||to_char(cutoff at time zone 'America/Denver','Mon DD, YYYY FMHH12:MI AM')||' America/Denver. Please pay before this deadline.'||case when s.leg='Return' then ' You may choose cash until one hour before the delivery window. Unverified electronic payment moves delivery to the next available route.' else ' Pickup payment must be confirmed 48 hours before the route and scheduling completed 24 hours before the route.' end);
   end if;
  end loop;
 end loop;
end $$;
revoke all on function private.audit_cutoff_reminders() from public;


create or replace function public.run_scheduled_tasks() RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare u record; m date; j record; route_job record;
begin
 if coalesce(auth.role(),'')<>'service_role' then raise exception 'Worker credentials required'; end if;
 update public.notifications n set payload=n.payload||jsonb_build_object('due',true,'detected_at',now())
 where n.event='Quote expiration reminder' and n.due_at<=now() and coalesce((n.payload->>'due')::boolean,false)=false
 and exists(select 1 from public.quotes q where q.id=n.entity_id and q.status in ('Sent','Viewed','Agreement Pending') and q.expires_at>now());
 update public.quotes set status='Expired'  where status in ('Sent','Viewed','Agreement Pending') and expires_at<now();
 for j in update public.jobs set status='Completed',auto_closed_at=now(),completion_reason='Completed – Deemed Accepted per Agreement'
 where status='Delivered – Pending Customer Acceptance' and acceptance_deadline<now() returning * loop
 insert into public.notifications(unit_id,event,entity_id,dedupe_key) values(j.unit_id,'Administrative completion',j.id,'auto-complete:'||j.id) on conflict do nothing;
 end loop;
 perform private.audit_cutoff_reminders();
 perform private.reconcile_driver_exceptions();
 perform private.reconcile_pickups();
 for route_job in select p.job_id from public.pick_return_orders p join public.jobs jj on jj.id=p.job_id join public.business_units b on b.id=jj.unit_id where b.code='TOOLTAG' and p.production_ready_at is not null and p.returned_at is null and jj.status not in ('Cancelled','Completed') loop
  perform private.reconcile_delivery(route_job.job_id);
 end loop;
 -- TT only in phase 1. BOFT production and its monthly automation are untouched.
 for u in select s.* from public.unit_settings s join public.business_units b on b.id=s.unit_id where b.code='TOOLTAG' loop
 m:=(date_trunc('month',now() at time zone u.timezone)-interval '1 month')::date;
 if not exists(select 1 from public.monthly_closes where unit_id=u.unit_id and month=m) then perform public.close_month(u.unit_id,m); end if;
 end loop;
end $$;

create function private.audit_job_gate() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.work_stage is distinct from old.work_stage and new.work_stage in ('Preparing','Engraving','Final Evidence','Final Details') and exists(select 1 from public.pick_return_orders where job_id=new.id and service_method in ('Pickup Only','Pickup & Delivery')) and exists(select 1 from public.job_items where job_id=new.id and stage<>'Cancelled' and shop_received_at is null) then raise exception 'Shop must verify every received item before production';end if;return new;
end $$;
revoke all on function private.audit_job_gate() from public;
create trigger audit_job_gate before update of work_stage on public.jobs for each row execute function private.audit_job_gate();

create or replace function public.return_driver_action(p_stop uuid,p_action text,p_present boolean default false) returns jsonb language plpgsql security definer set search_path='' as $$
declare s public.pick_return_stops;r public.pick_return_routes;j public.jobs;pr public.pick_return_orders;result jsonb;
begin
 select * into s from public.pick_return_stops where id=p_stop for update;
 select * into r from public.pick_return_routes where id=s.route_id for update;
 select * into j from public.jobs where id=s.job_id for update;
 if j.id is null or r.leg<>'Return' then raise exception 'Return stop unavailable';end if;
 perform private.require_admin(j.unit_id);
 select * into pr from public.pick_return_orders where job_id=j.id for update;
 if pr.service_method not in ('Pickup & Delivery','Drop-off + Delivery') or pr.production_ready_at is null then raise exception 'This Job is not ready for Return';end if;
 if j.status='Cancelled' or j.work_stage like '%Cancellation Requested%' or j.work_stage like '%Production Hold%' then raise exception 'Delivery blocked: Cancellation Requested / Production Hold';end if;
 if exists(select 1 from public.job_extensions where job_id=j.id and status in ('Requested','Draft','Sent')) or exists(select 1 from public.job_items where job_id=j.id and stage not in ('Finished','Cancelled')) then raise exception 'Delivery blocked: resolve pending additional work first';end if;
 if p_action in ('en-route','arrived') and r.departed_at is null then raise exception 'Verify route items and start the route before driving';end if;
 if p_action='customer-coming' then
  if s.status<>'Arrived' then raise exception 'Arrive before recording the customer response';end if;
  update public.pick_return_stops set return_customer_coming_at=now(),return_wait_until=null where id=s.id;
  return jsonb_build_object('ok',true);
 end if;
 if p_action='not-home' then
  if s.status<>'Arrived' or s.return_customer_coming_at is not null or s.return_wait_until is null or now()<s.return_wait_until then raise exception 'Wait five minutes without a customer response before continuing';end if;
 elsif p_action='cash' then
  if s.status<>'Arrived' or not p_present then raise exception 'The customer must be present for the cash exchange';end if;
  if pr.delivery_payment_method<>'Cash' then raise exception 'This stop is not a cash delivery';end if;
  return public.collect_route_cash(s.id);
 elsif p_action='arrived' then
  if s.status<>'En Route' then raise exception 'Start the Return before arriving';end if;
 elsif p_action='delivered' then
  if s.status<>'Arrived' or not p_present then raise exception 'The customer must be present. Never leave items at the door';end if;
  update public.pick_return_stops set customer_present_at=now() where id=s.id;
 elsif p_action<>'en-route' then raise exception 'Unknown Return action';end if;
 result:=public.advance_pick_return_stop(p_stop,p_action);
 if coalesce((result->>'rescheduled')::boolean,false) then return result;end if;
 if p_action='arrived' then
  update public.pick_return_stops set return_wait_until=now()+interval '5 minutes',return_customer_coming_at=null where id=s.id;
  perform private.route_notice(j.id,'RETURN_ARRIVED','return-arrived:'||s.id,'ToolTag has arrived with your items. Please come out to receive them within five minutes. Nothing will be left unattended.');
 end if;
 return result;
end $$;
create function private.audit_incident_gate() returns trigger language plpgsql security definer set search_path='' as $$
begin
 perform 1 from public.pick_return_routes where id=new.route_id for update;
 if exists(select 1 from public.pick_return_stops where route_id=new.route_id and status='Arrived') then raise exception 'Resolve the arrived stop before reporting driver unavailable';end if;return new;
end $$;
revoke all on function private.audit_incident_gate() from public;
create trigger audit_incident_gate before insert on public.route_incidents for each row execute function private.audit_incident_gate();

create or replace function public.advance_pick_return_stop(p_stop uuid, p_action text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  s public.pick_return_stops;
  r public.pick_return_routes;
  j public.jobs;
  pr public.pick_return_orders;
  recipient text;
  status_token text;
  zone text;
  eta_text text;
  completion_token text;
  due numeric; fee numeric; sale uuid; cid uuid;
begin
  select * into s from public.pick_return_stops where id=p_stop for update;
  if s.id is null then raise exception 'Route stop not found'; end if;

  select * into r from public.pick_return_routes where id=s.route_id for update;
  select * into j from public.jobs where id=s.job_id for update;
  perform private.require_admin(j.unit_id);

  perform private.apply_pending_cancellation(j.id);

  select * into j from public.jobs where id=s.job_id for update;
  select * into pr from public.pick_return_orders where job_id=j.id for update;

  if j.status='Cancelled'
     and not (
       r.leg='Return'
       and pr.pickup_status='Picked Up'
     )
  then
    raise exception 'This cancelled Job cannot continue this route';
  end if;

  if p_action='en-route' and exists(select 1 from public.pick_return_stops where route_id=r.id and sequence<s.sequence and status not in ('Completed','Cancelled','Failed','Requested')) then raise exception 'Resolve the previous stop first';end if;
  if r.leg='Return' then
    perform private.reconcile_delivery(j.id);
    select * into s from public.pick_return_stops where id=p_stop;
    if s.status='Cancelled' then return jsonb_build_object('rescheduled',true);end if;
    if exists(select 1 from public.delivery_attempt_fees df join public.sale_balances b on b.transaction_id=df.sale_id where df.job_id=j.id and b.balance_due>0) then raise exception 'Confirm the second-attempt fee before starting Return';end if;
    select balance_due into due from public.job_commercial_totals where id=j.id;
    if p_action='delivered' and coalesce(due,0)>0 then raise exception 'Collect and confirm payment before handing over items';end if;
  end if;

  if p_action='not-home' then
    if r.leg<>'Return' or s.status not in ('Arrived','En Route') then raise exception 'Arrive before marking Customer not home';end if;
    update public.pick_return_stops set status='Failed',completed_at=now() where id=s.id;
    update public.pick_return_orders set delivery_attempts=delivery_attempts+1,return_status='Delivery In Progress',updated_at=now() where job_id=j.id returning * into pr;
    if pr.delivery_attempts>=2 then
      update public.pick_return_orders set delivery_payment_status='Shop Pickup' where job_id=j.id;
      perform private.route_notice(j.id,'RETURN_MISSED','return-missed:'||s.id,'The second delivery attempt was unsuccessful. Your items are held at the shop. Wait for pickup instructions; nothing was left at the door.');
    else
      update public.pick_return_orders set return_window_start=null,return_window_end=null,return_eta=null,delivery_payment_status='Pending Delivery' where job_id=j.id;
      perform private.reserve_return_retry(j.id,s.id);
      select * into pr from public.pick_return_orders where job_id=j.id;
      perform private.route_notice(j.id,'RETURN_MISSED','return-missed:'||s.id,'Delivery pending. Nothing was left at the door. A provisional place is reserved for '||to_char(pr.return_window_start at time zone 'America/Denver','FMDay, FMMonth DD, YYYY')||'. Confirm the second attempt by paying $'||(select to_char(second_delivery_attempt_fee,'FM999999990.00') from public.unit_settings where unit_id=j.unit_id)||' before the route payment cutoff, or choose free shop pickup. Unpaid reservations are released at the cutoff or after 15 days, whichever comes first. The first attempt is nonrefundable. A second miss requires shop pickup; there is no third trip.');
    end if;
    perform private.activate_next_route_stop(r.id,s.sequence);
  elsif p_action='en-route' then
    if s.status<>'Scheduled' then raise exception 'Stop is not ready to start'; end if;
    if r.leg='Pickup' and pr.fee_status<>'Confirmed' then
      raise exception 'Pickup fee must be confirmed before starting the route';
    end if;
    if r.leg='Return' and pr.hold_until_paid then
      raise exception 'Outstanding balance must be paid before Return';
    end if;

    update public.pick_return_stops set status='En Route' where id=s.id;
    update public.pick_return_routes
    set status='Active',started_at=coalesce(started_at,now())
    where id=r.id;

    if r.leg='Pickup' then
      update public.pick_return_orders
      set pickup_status='En Route',pickup_eta=s.eta,updated_at=now()
      where job_id=j.id;
    else
      update public.pick_return_orders
      set return_status='En Route',return_eta=s.eta,updated_at=now()
      where job_id=j.id;
    end if;

    recipient:=private.job_customer_recipient(j.id);
    status_token:=private.ensure_job_status_link(j.id);
    select timezone into zone from public.unit_settings where unit_id=j.unit_id;
    eta_text:=case
      when s.eta is null then ''
      else ' Estimated arrival: '||to_char(s.eta at time zone zone,'FMHH12:MI AM')||'.'
    end;

    insert into public.notifications(
      unit_id,event,entity_id,recipient,dedupe_key,payload
    )
    values(
      j.unit_id,
      case when r.leg='Pickup' then 'PICKUP_EN_ROUTE' else 'RETURN_EN_ROUTE' end,
      s.id,
      recipient,
      lower(r.leg)||'-en-route:'||s.id,
      jsonb_build_object(
        'template','notification',
        'subject','ToolTag is on the way — '||j.code,
        'text',
          case when r.leg='Pickup'
            then 'ToolTag is on the way for your scheduled Pickup.'
            else 'ToolTag is on the way with your items.'
          end||eta_text,
        'action_path','/status/'||status_token,
        'live_eligible',true
      )
    )
    on conflict do nothing;

  elsif p_action='arrived' then
    if s.status not in ('Scheduled','En Route') then
      raise exception 'Stop cannot be marked Arrived';
    end if;

    update public.pick_return_stops
    set status='Arrived',arrived_at=coalesce(arrived_at,now())
    where id=s.id;

    if r.leg='Pickup' then
      update public.pick_return_orders
      set pickup_status='Arrived',updated_at=now()
      where job_id=j.id;
    else
      update public.pick_return_orders
      set return_status='Arrived',updated_at=now()
      where job_id=j.id;
    end if;

  elsif p_action='picked-up' then
    if r.leg<>'Pickup' then raise exception 'This is not a Pickup stop'; end if;
    if s.status not in ('Arrived','En Route') then
      raise exception 'Arrive at the Pickup stop first';
    end if;
    if pr.fee_status<>'Confirmed' then
      raise exception 'Pickup fee must be confirmed before collecting items';
    end if;
    if not exists(
      select 1 from public.documents d
      where d.pick_return_stop_id=s.id
        and d.job_id=j.id
        and d.type='Receiving Evidence'
        and d.status='Available'
    ) then
      raise exception 'Add receiving photos before marking Picked Up';
    end if;

    update public.pick_return_stops
    set status='Completed',completed_at=coalesce(completed_at,now())
    where id=s.id;

    update public.pick_return_orders
    set pickup_status='Picked Up',
        picked_up_at=coalesce(picked_up_at,now()),
        updated_at=now()
    where job_id=j.id;

    update public.jobs
    set status='In Process',
        work_stage='Received at Shop',
        customer_stage='In Process',
        updated_at=now()
    where id=j.id;

    perform private.activate_next_route_stop(r.id,s.sequence);

  elsif p_action='delivered' then
    if r.leg<>'Return' then raise exception 'This is not a Return stop'; end if;
    if s.status not in ('Arrived','En Route') then
      raise exception 'Arrive at the Return stop first';
    end if;
    if pr.hold_until_paid then
      raise exception 'Outstanding balance must be paid before delivery';
    end if;
    if not exists(
      select 1 from public.documents d
      where d.pick_return_stop_id=s.id
        and d.job_id=j.id
        and d.type='Delivery Evidence'
        and d.status='Available'
    ) then
      raise exception 'Add delivery photos before marking Delivered';
    end if;

    update public.pick_return_stops
    set status='Completed',completed_at=coalesce(completed_at,now())
    where id=s.id;

    update public.pick_return_orders
    set return_status='Delivered',
        returned_at=coalesce(returned_at,now()),
        updated_at=now()
    where job_id=j.id;

    if j.status='Cancelled' then
      recipient:=private.job_customer_recipient(j.id);
      status_token:=private.ensure_job_status_link(j.id);

      insert into public.notifications(
        unit_id,event,entity_id,recipient,dedupe_key,payload
      )
      values(
        j.unit_id,
        'CANCELLED_ITEMS_RETURNED',
        s.id,
        recipient,
        'cancelled-items-returned:'||j.id,
        jsonb_build_object(
          'template','notification',
          'subject','Items returned — '||j.code,
          'text','Your items from the cancelled ToolTag Job have been returned. Delivery evidence has been recorded.',
          'action_path','/status/'||status_token,
          'live_eligible',true
        )
      )
      on conflict do nothing;
    else
      completion_token:=private.begin_delivery_acceptance(j.id);
    end if;

    perform private.activate_next_route_stop(r.id,s.sequence);

  else
    raise exception 'Invalid route action';
  end if;

  return jsonb_build_object(
    'blocked',false,'job_id',j.id,'stop_id',s.id,
    'leg',r.leg,'action',p_action,'completion_token',completion_token
  );
end $$;

create function public.customer_arrival_context(p_token text) returns jsonb language plpgsql security definer set search_path='' as $$
declare j public.jobs; result jsonb;
begin j:=private.audit_status_job(p_token);
 select jsonb_build_object('leg',r.leg,'responded',case when r.leg='Pickup' then s.customer_coming_at is not null else s.return_customer_coming_at is not null end) into result
 from public.pick_return_stops s join public.pick_return_routes r on r.id=s.route_id where s.job_id=j.id and s.status='Arrived' order by s.created_at desc limit 1;
 return result;
end $$;
revoke all on function public.customer_arrival_context(text) from public;
grant execute on function public.customer_arrival_context(text) to anon,authenticated;
