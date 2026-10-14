-- Additive failed-delivery verification and Lost registers. No records are deleted.
alter table public.jobs add column is_lost boolean not null default false;
create table public.failed_delivery_verifications (
 stop_id uuid primary key references public.pick_return_stops(id),unit_id uuid not null references public.business_units(id),
 route_id uuid not null references public.pick_return_routes(id),job_id uuid not null references public.jobs(id),
 driver_id uuid references auth.users(id),status text not null default 'Pending' check(status in ('Pending','Verified','Lost')),
 created_at timestamptz not null default now(),verified_at timestamptz,verified_by uuid references auth.users(id)
);
create table public.lost_jobs (
 id uuid primary key default gen_random_uuid(),unit_id uuid not null references public.business_units(id),
 job_id uuid not null unique references public.jobs(id),stop_id uuid not null references public.pick_return_stops(id),
 route_id uuid not null references public.pick_return_routes(id),driver_id uuid references auth.users(id),driver_name text,
 missing_item_ids uuid[] not null check(cardinality(missing_item_ids)>0),explanation text not null check(length(trim(explanation))>0),
 reported_at timestamptz not null default now(),reported_by uuid not null references auth.users(id)
);
alter table public.failed_delivery_verifications enable row level security;
alter table public.lost_jobs enable row level security;
create policy failed_delivery_verifications_read on public.failed_delivery_verifications for select to authenticated using(unit_id='10000000-0000-0000-0000-000000000002' and private.has_any(unit_id,array['pr.returns','pr.routes.plan','pr.routes.live']));
create policy lost_jobs_read on public.lost_jobs for select to authenticated using(unit_id='10000000-0000-0000-0000-000000000002' and private.has_any(unit_id,array['jobs.view','pr.returns']));
revoke all on public.failed_delivery_verifications,public.lost_jobs from public,anon,authenticated;
grant select on public.failed_delivery_verifications,public.lost_jobs to authenticated;

create function private.register_failed_delivery() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.status='Failed' and (tg_op='INSERT' or old.status is distinct from 'Failed') and exists(select 1 from public.pick_return_routes where id=new.route_id and leg='Return') then
  insert into public.failed_delivery_verifications(stop_id,unit_id,route_id,job_id,driver_id) values(new.id,new.unit_id,new.route_id,new.job_id,coalesce(auth.uid(),(select operator_id from public.pick_return_routes where id=new.route_id))) on conflict(stop_id) do nothing;
 end if;
 return new;
end $$;
create trigger register_failed_delivery after insert or update of status on public.pick_return_stops for each row execute function private.register_failed_delivery();
-- Existing failed stops retain their route/evidence links and previous item checks.
insert into public.failed_delivery_verifications(stop_id,unit_id,route_id,job_id,driver_id,status)
select s.id,s.unit_id,s.route_id,s.job_id,r.operator_id,case when exists(select 1 from public.job_items i where i.job_id=s.job_id and i.stage<>'Cancelled') and not exists(select 1 from public.job_items i where i.job_id=s.job_id and i.stage<>'Cancelled' and not exists(select 1 from private.route_item_checks c where c.stop_id=s.id and c.item_id=i.id and c.kind='Returned')) then 'Verified' else 'Pending' end
from public.pick_return_stops s join public.pick_return_routes r on r.id=s.route_id where r.leg='Return' and s.status='Failed' and s.unit_id='10000000-0000-0000-0000-000000000002';

create function public.verify_failed_delivery(p_stop uuid,p_items uuid[]) returns void language plpgsql security definer set search_path='' as $$
declare v public.failed_delivery_verifications;
begin
 select * into v from public.failed_delivery_verifications where stop_id=p_stop for update;
 if v.unit_id is distinct from '10000000-0000-0000-0000-000000000002'::uuid or not private.has_block(v.unit_id,'pr.returns') then raise exception 'Shop verification permission required' using errcode='42501';end if;
 if v.status='Verified' then return;end if;
 if v.status<>'Pending' then raise exception 'This Job is in Lost';end if;
 perform public.verify_route_items(v.stop_id,'Returned',p_items);
 if exists(select 1 from public.job_items i where i.job_id=v.job_id and i.stage<>'Cancelled' and not exists(select 1 from private.route_item_checks c where c.stop_id=v.stop_id and c.item_id=i.id and c.kind='Returned')) then raise exception 'Verify every item before confirming shop arrival';end if;
 update public.failed_delivery_verifications set status='Verified',verified_at=now(),verified_by=auth.uid() where stop_id=v.stop_id;
 perform private.rbac_log('delivery.failed.verified',v.job_id,jsonb_build_object('stop_id',v.stop_id,'route_id',v.route_id));
end $$;
create function public.mark_failed_delivery_lost(p_stop uuid,p_checked uuid[],p_explanation text) returns uuid language plpgsql security definer set search_path='' as $$
declare v public.failed_delivery_verifications;r public.pick_return_routes;missing uuid[];lid uuid;
begin
 select * into v from public.failed_delivery_verifications where stop_id=p_stop for update;
 if v.unit_id is distinct from '10000000-0000-0000-0000-000000000002'::uuid or not private.has_block(v.unit_id,'pr.returns') then raise exception 'Shop verification permission required' using errcode='42501';end if;
 if v.status='Lost' then select id into lid from public.lost_jobs where job_id=v.job_id;return lid;end if;
 if v.status<>'Pending' then raise exception 'Shop arrival was already verified';end if;
 if length(trim(coalesce(p_explanation,'')))=0 then raise exception 'Explain what happened before marking a Job as lost';end if;
 if p_checked is null or exists(select 1 from unnest(p_checked) item where not exists(select 1 from public.job_items i where i.id=item and i.job_id=v.job_id and i.stage<>'Cancelled')) then raise exception 'Invalid item checklist';end if;
 select array_agg(id order by sequence) into missing from public.job_items where job_id=v.job_id and stage<>'Cancelled' and id<>all(p_checked);
 if cardinality(missing) is null then raise exception 'No missing items were identified';end if;
 select * into r from public.pick_return_routes where id=v.route_id for update;
 insert into public.lost_jobs(unit_id,job_id,stop_id,route_id,driver_id,driver_name,missing_item_ids,explanation,reported_by)
 values(v.unit_id,v.job_id,v.stop_id,v.route_id,coalesce(v.driver_id,r.operator_id),(select display_name from public.staff_access where user_id=coalesce(v.driver_id,r.operator_id) and unit_id=r.unit_id),missing,trim(p_explanation),auth.uid()) returning id into lid;
 update public.jobs set is_lost=true where id=v.job_id;
 update public.pick_return_stops set status='Cancelled' where job_id=v.job_id and status in ('Requested','Scheduled','En Route','Arrived');
 update public.failed_delivery_verifications set status='Lost',verified_at=now(),verified_by=auth.uid() where stop_id=v.stop_id;
 perform private.rbac_log('job.lost.reported',v.job_id,jsonb_build_object('loss_id',lid,'stop_id',v.stop_id,'missing_items',missing,'explanation',trim(p_explanation)));
 return lid;
end $$;
create function public.lost_job_list() returns jsonb language plpgsql stable security definer set search_path='' as $$
declare u uuid:='10000000-0000-0000-0000-000000000002';
begin
 if not private.has_any(u,array['jobs.view','pr.returns']) then raise exception 'Lost list permission required' using errcode='42501';end if;
 return coalesce((select jsonb_agg(jsonb_build_object('id',l.id,'job',j.code,'customer',c.name,'phone',c.phone,'driver',coalesce(nullif(l.driver_name,''),'Unassigned'),'driver_id',l.driver_id,'driver_email',(select email from auth.users where id=l.driver_id),'route_date',r.route_date,'explanation',l.explanation,'reported_at',l.reported_at,'items',(select jsonb_agg(jsonb_build_object('id',i.id,'article',i.article,'sequence',i.sequence)) from public.job_items i where i.id=any(l.missing_item_ids))) order by l.reported_at desc) from public.lost_jobs l join public.jobs j on j.id=l.job_id join public.pick_return_routes r on r.id=l.route_id left join public.commercial_flows f on f.id=j.flow_id left join public.customers c on c.id=f.customer_id where l.unit_id=u),'[]');
end $$;
revoke all on function private.register_failed_delivery() from public,anon,authenticated;
revoke all on function public.verify_failed_delivery(uuid,uuid[]),public.mark_failed_delivery_lost(uuid,uuid[],text),public.lost_job_list() from public,anon;
grant execute on function public.verify_failed_delivery(uuid,uuid[]),public.mark_failed_delivery_lost(uuid,uuid[],text),public.lost_job_list() to authenticated;

alter table public.unit_settings add column shop_pickup_blocks_enabled boolean not null default true;
create function private.pickup_queue_eligible(p_job uuid) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.pick_return_orders p join public.jobs j on j.id=p.job_id where p.job_id=p_job and not j.is_lost and j.status not in ('Cancelled','Completed','Closed') and p.service_method in ('Pickup Only','Pickup & Delivery') and p.pickup_status='Not Scheduled'
 and not exists(select 1 from public.pick_return_stops s join public.pick_return_routes r on r.id=s.route_id where s.job_id=j.id and r.leg='Pickup' and s.status in ('Requested','Scheduled','En Route','Arrived')))
$$;
create function public.pickup_queue_state() returns jsonb language plpgsql stable security definer set search_path='' as $$
declare u uuid:='10000000-0000-0000-0000-000000000002';
begin
 if not private.has_any(u,array['pr.routes.plan','pr.routes.live','pr.receiving','pr.reschedule']) then raise exception 'Pickup operations permission required' using errcode='42501';end if;
 return coalesce((select jsonb_agg(jsonb_build_object('job',p.job_id,'eligible',private.pickup_queue_eligible(p.job_id))) from public.pick_return_orders p where p.unit_id=u),'[]');
end $$;
create function public.pickup_block_availability(p_job uuid,p_from date) returns jsonb language plpgsql security definer set search_path='' as $$
declare u uuid;p public.pick_return_orders;d date;r public.pick_return_routes;n integer;result jsonb:='[]';days integer[];i integer;paid_at timestamptz;
begin
 select unit_id into u from public.jobs where id=p_job;
 if u is distinct from '10000000-0000-0000-0000-000000000002'::uuid or not private.has_block(u,'pr.routes.plan') then raise exception 'Route planning permission required' using errcode='42501';end if;
 if not private.pickup_queue_eligible(p_job) then raise exception 'This job is not awaiting Pickup scheduling';end if;
 select * into p from public.pick_return_orders where job_id=p_job;
 if p.fee_status<>'Confirmed' then raise exception 'Confirm the Pickup fee before scheduling';end if;
 select pickup_route_iso_weekdays into days from public.unit_settings where unit_id=u;
 select max(confirmed_at) into paid_at from public.payment_requests where job_id=p_job and status='Confirmed' and purpose in ('Pickup Fee','Logistics Fee','Logistics Full Prepayment');
 d:=greatest(p_from,(now() at time zone 'America/Denver')::date,(p.pickup_window_start at time zone 'America/Denver')::date);
 for i in 0..104 loop
  if extract(isodow from d)::integer=any(days) and (d+time '08:00') at time zone 'America/Denver'>greatest(now()+interval '24 hours',coalesce(paid_at,p.created_at)+interval '48 hours') then
   select * into r from public.pick_return_routes where unit_id=u and route_date=d and leg='Pickup';
   select count(*) into n from public.pick_return_stops where route_id=r.id and status<>'Cancelled';
   if r.id is null or (r.status not in ('Completed','Cancelled') and r.confirmed_at is null and r.started_at is null and r.departed_at is null and n<r.delivery_capacity) then
    result:=result||jsonb_build_array(jsonb_build_object('date',d,'blocks',jsonb_build_array(jsonb_build_object('id',r.id,'number',coalesce(r.block_number,1),'count',n,'capacity',coalesce(r.delivery_capacity,20)))));
   end if;
  end if;d:=d+1;
 end loop;return result;
end $$;
create function public.assign_pickup_block(p_job uuid,p_day date) returns uuid language plpgsql security definer set search_path='' as $$
declare u uuid;a jsonb;sid uuid;rid uuid;start_at timestamptz;
begin
 select unit_id into u from public.jobs where id=p_job;
 perform pg_advisory_xact_lock(hashtextextended(u::text||'Pickup',0));perform 1 from public.jobs where id=p_job for update;
 a:=public.pickup_block_availability(p_job,p_day);
 if not exists(select 1 from jsonb_array_elements(a) x where (x->>'date')::date=p_day) then raise exception 'This Pickup block is no longer available';end if;
 start_at:=(p_day+time '08:00') at time zone 'America/Denver';sid:=private.assign_route(p_job,'Pickup',start_at,start_at+interval '4 hours',start_at);
 select route_id into rid from public.pick_return_stops where id=sid;
 update public.pick_return_orders set pickup_missed_stop_id=null,pickup_miss_expires_at=null where job_id=p_job;
 if not (select manual_stop_order from public.pick_return_routes where id=rid) then perform private.order_pickup_block(rid);end if;
 perform private.rbac_log('pickup.block.assigned',rid,jsonb_build_object('job_id',p_job));return rid;
end $$;
create function private.order_pickup_block(p_route uuid,p_order uuid[] default null) returns void language plpgsql security definer set search_path='' as $$
declare ids uuid[];sid uuid;off integer;i integer:=0;
begin
 select coalesce(max(sequence),0)+1000 into off from public.pick_return_stops where route_id=p_route;
 if p_order is null then select array_agg(s.id order by p.pickup_window_start,j.created_at,s.id) into ids from public.pick_return_stops s join public.jobs j on j.id=s.job_id join public.pick_return_orders p on p.job_id=j.id where s.route_id=p_route and s.status<>'Cancelled';else ids:=p_order;end if;
 update public.pick_return_stops set sequence=sequence+off where route_id=p_route;
 foreach sid in array coalesce(ids,'{}'::uuid[]) loop i:=i+1;update public.pick_return_stops set sequence=i where id=sid and route_id=p_route;end loop;
 for sid in select id from public.pick_return_stops where route_id=p_route and status='Cancelled' order by sequence loop i:=i+1;update public.pick_return_stops set sequence=i where id=sid;end loop;
end $$;
-- Reuse the audited atomic edit implementation, with Pickup-specific queue fields and ordering.
do $patch$
declare d text;
begin
 d:=pg_get_functiondef('public.save_delivery_block(uuid,uuid,uuid[],uuid[],integer,text)'::regprocedure);
 d:=replace(d,'public.save_delivery_block','public.save_pickup_block');d:=replace(d,$text$r.leg<>'Return'$text$,$text$r.leg<>'Pickup'$text$);
 d:=replace(d,$text$set return_status='Delivery In Progress',return_window_start=null,return_window_end=null,return_eta=null$text$,$text$set pickup_status='Not Scheduled',pickup_window_start=null,pickup_window_end=null,pickup_eta=null$text$);
 d:=replace(d,'private.order_delivery_block','private.order_pickup_block');d:=replace(d,'delivery.block.saved','pickup.block.saved');d:=replace(d,'delivery.capacity.authorized','pickup.capacity.authorized');execute d;
 d:=pg_get_functiondef('private.delivery_block_capacity_guard()'::regprocedure);d:=replace(d,$text$r.leg<>'Return'$text$,$text$r.leg not in ('Return','Pickup')$text$);execute d;
 d:=pg_get_functiondef('public.delivery_block_drivers()'::regprocedure);d:=replace(d,$text$r.leg='Return'$text$,$text$r.leg in ('Return','Pickup')$text$);d:=replace(d,$text$'pr.returns','pr.reschedule'$text$,$text$'pr.returns','pr.receiving','pr.reschedule'$text$);execute d;
 d:=pg_get_functiondef('private.delivery_queue_eligible(uuid)'::regprocedure);d:=replace(d,$text$and j.status not in$text$,$text$and not j.is_lost and j.status not in$text$);execute d;
end $patch$;
revoke all on function private.pickup_queue_eligible(uuid),private.order_pickup_block(uuid,uuid[]) from public,anon,authenticated;
revoke all on function public.pickup_queue_state(),public.pickup_block_availability(uuid,date),public.assign_pickup_block(uuid,date),public.save_pickup_block(uuid,uuid,uuid[],uuid[],integer,text) from public,anon;
grant execute on function public.pickup_queue_state(),public.pickup_block_availability(uuid,date),public.assign_pickup_block(uuid,date),public.save_pickup_block(uuid,uuid,uuid[],uuid[],integer,text) to authenticated;

-- A documented loss is an explicit closure exception, not a fabricated arrival verification.
do $patch$
declare d text;
begin
 d:=pg_get_functiondef('public.confirm_pick_return_route(uuid)'::regprocedure);
 d:=replace(d,$old$s.status='Failed' and i.stage<>'Cancelled' and not exists$old$,$new$s.status='Failed' and not exists(select 1 from public.failed_delivery_verifications v where v.stop_id=s.id and v.status='Lost') and i.stage<>'Cancelled' and not exists$new$);
 if position('failed_delivery_verifications' in d)=0 then raise exception 'Unexpected route closure gate';end if;execute d;
 d:=pg_get_functiondef('private.assign_route(uuid,text,timestamptz,timestamptz,timestamptz)'::regprocedure);
 d:=replace(d,'if j.id is null then raise exception ''Job not found''; end if;','if j.id is null then raise exception ''Job not found''; end if; if j.is_lost then raise exception ''This Job is in Lost'';end if;');execute d;
end $patch$;
create function private.protect_lost_job() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if old.is_lost and (not new.is_lost or new.status is distinct from old.status or new.work_stage is distinct from old.work_stage) then raise exception 'Lost Jobs require Owner follow-up in Lost';end if;return new;
end $$;
create trigger protect_lost_job before update on public.jobs for each row execute function private.protect_lost_job();
create function private.protect_lost_item() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if exists(select 1 from public.jobs where id=new.job_id and is_lost) then raise exception 'This Job is in Lost';end if;return new;
end $$;
create trigger protect_lost_item before insert or update on public.job_items for each row execute function private.protect_lost_item();
revoke all on function private.protect_lost_job(),private.protect_lost_item() from public,anon,authenticated;

-- Shared Pickup ETAs allow the same 20-stop block capacity as Delivery.
do $patch$
declare d text;
begin
 d:=pg_get_functiondef('public.route_availability(uuid,text,date,text)'::regprocedure);
 d:=replace(d,'select max(p.confirmed_at) into fee_stamp', 'if p_leg=''Pickup'' and (select shop_pickup_blocks_enabled from public.unit_settings where unit_id=j.unit_id) then cap:=coalesce((select delivery_capacity from public.pick_return_routes where unit_id=j.unit_id and leg=''Pickup'' and route_date=d),20);end if; select max(p.confirmed_at) into fee_stamp');
 d:=replace(d,$text$case when p_leg='Pickup' then 1 else cap end$text$,$text$case when p_leg='Pickup' and not (select shop_pickup_blocks_enabled from public.unit_settings where unit_id=j.unit_id) then 1 else cap end$text$);execute d;
end $patch$;
notify pgrst,'reload schema';

create function public.status_job_on_hold(p_token text) returns boolean language plpgsql stable security definer set search_path='' as $$
declare j public.jobs;
begin j:=private.audit_status_job(p_token);if j.unit_id is distinct from '10000000-0000-0000-0000-000000000002'::uuid then raise exception 'ToolTag Job required';end if;return j.is_lost;end $$;
revoke all on function public.status_job_on_hold(text) from public;
grant execute on function public.status_job_on_hold(text) to anon,authenticated;

-- Each missed Pickup is a separate taxable service, charged at Pickup Only pricing.
create table public.pickup_attempt_fees (
 stop_id uuid primary key references public.pick_return_stops(id),unit_id uuid not null references public.business_units(id),job_id uuid not null references public.jobs(id),
 sale_id uuid not null unique references public.transactions(id),subtotal numeric(14,2) not null,tax_rate numeric(7,4) not null,tax_amount numeric(14,2) not null,amount numeric(14,2) not null,
 selected_date date,created_at timestamptz not null default now(),check(amount=subtotal+tax_amount)
);
alter table public.pickup_attempt_fees enable row level security;
create policy pickup_attempt_fees_read on public.pickup_attempt_fees for select to authenticated using(unit_id='10000000-0000-0000-0000-000000000002' and private.has_any(unit_id,array['pr.routes.plan','pr.receiving','pr.reschedule','payments.view','payments.record']));
revoke all on public.pickup_attempt_fees from public,anon,authenticated;grant select on public.pickup_attempt_fees to authenticated;
alter table public.payment_requests add column pickup_retry_stop_id uuid references public.pickup_attempt_fees(stop_id);
alter table public.logistics_payment_attempts add column pickup_retry_stop_id uuid references public.pickup_attempt_fees(stop_id);
alter table public.pick_return_orders add column pickup_miss_expires_at timestamptz;
do $patch$
declare d text;
begin
 select pg_get_constraintdef(oid) into d from pg_constraint where conrelid='public.payment_requests'::regclass and conname='payment_requests_purpose_check';
 alter table public.payment_requests drop constraint payment_requests_purpose_check;
 execute 'alter table public.payment_requests add constraint payment_requests_purpose_check CHECK ('||substring(d from 7)||' OR purpose=''Pickup Retry Fee'')';
end $patch$;
create or replace view public.job_commercial_totals with(security_invoker=true) as
select j.id,j.unit_id,coalesce(b.amount,0) base_amount,coalesce(e.amount,0)+coalesce(f.amount,0)+coalesce(p.amount,0) extensions_amount,
coalesce(b.amount,0)+coalesce(e.amount,0)+coalesce(f.amount,0)+coalesce(p.amount,0) grand_total,
coalesce(b.collected,0)+coalesce(e.collected,0)+coalesce(f.collected,0)+coalesce(p.collected,0) collected,
coalesce(b.refunded,0)+coalesce(e.refunded,0)+coalesce(f.refunded,0)+coalesce(p.refunded,0) refunded,
greatest(0,coalesce(b.amount,0)+coalesce(e.amount,0)+coalesce(f.amount,0)+coalesce(p.amount,0)-coalesce(b.collected,0)-coalesce(e.collected,0)-coalesce(f.collected,0)-coalesce(p.collected,0)) balance_due
from public.jobs j left join public.sale_balances b on b.job_id=j.id and b.transaction_status<>'Voided'
left join lateral(select sum(s.amount) amount,sum(s.collected) collected,sum(s.refunded) refunded from public.job_extensions x join public.sale_balances s on s.transaction_id=x.sale_id where x.job_id=j.id and x.status in('Approved','Completed') and s.transaction_status<>'Voided') e on true
left join lateral(select sum(s.amount) amount,sum(s.collected) collected,sum(s.refunded) refunded from public.delivery_attempt_fees x join public.sale_balances s on s.transaction_id=x.sale_id where x.job_id=j.id and s.transaction_status<>'Voided') f on true
left join lateral(select sum(s.amount) amount,sum(s.collected) collected,sum(s.refunded) refunded from public.pickup_attempt_fees x join public.sale_balances s on s.transaction_id=x.sale_id where x.job_id=j.id and s.transaction_status<>'Voided') p on true;

create function private.pickup_retry_paid(p_job uuid) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.pickup_attempt_fees f join public.pick_return_orders p on p.pickup_missed_stop_id=f.stop_id join public.sale_balances b on b.transaction_id=f.sale_id where f.job_id=p_job and b.balance_due=0 and b.transaction_status<>'Voided')
$$;
alter function public.pickup_miss_choice(uuid,text,text) rename to pickup_miss_choice_before_paid_retry;
create function public.pickup_miss_choice(p_job uuid,p_token text,p_choice text) returns jsonb language plpgsql security definer set search_path='' as $$
declare j public.jobs;p public.pick_return_orders;base numeric;rate numeric;snapshot jsonb;tid uuid;cid uuid;n integer;
begin
 j:=private.route_actor(p_job,p_token);if j.unit_id is distinct from '10000000-0000-0000-0000-000000000002'::uuid then raise exception 'ToolTag Job required';end if;
 if not (select shop_pickup_blocks_enabled from public.unit_settings where unit_id=j.unit_id) then return public.pickup_miss_choice_before_paid_retry(p_job,p_token,p_choice);end if;
 if not exists(select 1 from private.job_status_links where job_id=j.id and token_hash=encode(sha256(convert_to(p_token,'UTF8')),'hex')) then raise exception 'Status link unavailable';end if;
 select * into p from public.pick_return_orders where job_id=j.id for update;
 if p.pickup_status<>'Failed' or p.pickup_missed_stop_id is null or j.is_lost then raise exception 'There is no missed Pickup to resolve';end if;
 if p_choice='cancel' then return public.public_status_confirm_cancellation(p_token);end if;
 if p_choice<>'reschedule' then raise exception 'Choose reschedule or cancel';end if;
 if now()>=p.pickup_miss_expires_at then raise exception 'The Pickup response deadline has passed';end if;
 if exists(select 1 from public.pickup_attempt_fees where stop_id=p.pickup_missed_stop_id) then return jsonb_build_object('chosen',true);end if;
 base:=(private.logistics_option('pickup_only')->>'fee')::numeric;select tax_rate into rate from public.quotes where id=j.quote_id;snapshot:=private.tax_details(base,coalesce(rate,0));
 select customer_id into cid from public.commercial_flows where id=j.flow_id;select count(*)+2 into n from public.pickup_attempt_fees where job_id=j.id;
 insert into public.transactions(unit_id,type,amount,customer_id,description,reference) values(j.unit_id,'SALE',(snapshot->>'total')::numeric,cid,'Pickup retry · '||j.code,'PICKUP-RETRY:'||p.pickup_missed_stop_id) returning id into tid;
 insert into public.sales(transaction_id,unit_id,code,approved_items,tax_snapshot) values(tid,j.unit_id,j.code||'/PICKUP'||n,jsonb_build_array(jsonb_build_object('article','Pickup retry','quantity',1,'unit_price',base)),snapshot);
 insert into public.pickup_attempt_fees(stop_id,unit_id,job_id,sale_id,subtotal,tax_rate,tax_amount,amount) values(p.pickup_missed_stop_id,j.unit_id,j.id,tid,base,coalesce(rate,0),(snapshot->>'tax_amount')::numeric,(snapshot->>'total')::numeric);
 perform private.route_notice(j.id,'PAYMENT_DUE','pickup-retry-fee:'||p.pickup_missed_stop_id,'Your missed Pickup can be rescheduled after paying the Pickup Only fee again. The original Pickup fee is nonrefundable. After payment is confirmed, choose your new Pickup date in your status page.');
 return jsonb_build_object('chosen',true,'amount',snapshot->'total');
end $$;
revoke all on function public.pickup_miss_choice_before_paid_retry(uuid,text,text) from public,anon,authenticated;
revoke all on function public.pickup_miss_choice(uuid,text,text) from public;grant execute on function public.pickup_miss_choice(uuid,text,text) to anon,authenticated;
create function public.pickup_retry_context(p_job uuid,p_token text) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare j public.jobs;p public.pick_return_orders;f public.pickup_attempt_fees;st public.unit_settings;base numeric;rate numeric;
begin
 j:=private.route_actor(p_job,p_token);if j.unit_id is distinct from '10000000-0000-0000-0000-000000000002'::uuid then raise exception 'ToolTag Job required';end if;if not exists(select 1 from private.job_status_links where job_id=j.id and token_hash=encode(sha256(convert_to(p_token,'UTF8')),'hex')) then raise exception 'Status link unavailable';end if;
 select * into p from public.pick_return_orders where job_id=j.id;select * into f from public.pickup_attempt_fees where stop_id=p.pickup_missed_stop_id;select * into st from public.unit_settings where unit_id=j.unit_id;select tax_rate into rate from public.quotes where id=j.quote_id;base:=(private.logistics_option('pickup_only')->>'fee')::numeric;
 return jsonb_build_object('chosen',f.stop_id is not null,'paid',private.pickup_retry_paid(j.id),'amount',coalesce(f.amount,(private.tax_details(base,coalesce(rate,0))->>'total')::numeric),'date',f.selected_date,'expires_at',p.pickup_miss_expires_at,'zelle',st.zelle_email,'venmo',st.venmo_handle);
end $$;
create function public.submit_pickup_retry_payment(p_token text,p_method text,p_request uuid,p_path text default null) returns jsonb language plpgsql security definer set search_path='' as $$
declare j public.jobs;p public.pick_return_orders;f public.pickup_attempt_fees;due numeric;rid uuid;
begin
 j:=private.audit_status_job(p_token);if j.unit_id is distinct from '10000000-0000-0000-0000-000000000002'::uuid then raise exception 'ToolTag Job required';end if;select * into p from public.pick_return_orders where job_id=j.id for update;select * into f from public.pickup_attempt_fees where stop_id=p.pickup_missed_stop_id;
 if f.stop_id is null or p.pickup_status<>'Failed' or j.is_lost or now()>=p.pickup_miss_expires_at then raise exception 'Pickup retry payment unavailable';end if;
 if p_method not in('Zelle','Venmo') then raise exception 'Pay the retry electronically before scheduling';end if;
 if p_path is not null and p_path not like j.unit_id::text||'/'||p_request::text||'.%' then raise exception 'Invalid payment proof';end if;
 select balance_due into due from public.sale_balances where transaction_id=f.sale_id;if due<=0 then return jsonb_build_object('status','Confirmed');end if;
 select id into rid from public.payment_requests where job_id=j.id and pickup_retry_stop_id=f.stop_id and status in('Pending Verification','Confirmed');if rid is not null then return jsonb_build_object('status','Pending Verification','id',rid);end if;
 insert into public.payment_requests(request_key,unit_id,job_id,method,amount,purpose,proof_path,pickup_retry_stop_id) values(p_request,j.unit_id,j.id,p_method,due,'Pickup Retry Fee',p_path,f.stop_id) returning id into rid;
 perform private.route_notice(j.id,'PAYMENT_DUE','pickup-retry-proof:'||rid,'Your Pickup retry payment was submitted and is awaiting verification.');return jsonb_build_object('status','Pending Verification','id',rid);
end $$;
create function public.prepare_pickup_retry_card(p_token text,p_attempt uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare j public.jobs;p public.pick_return_orders;f public.pickup_attempt_fees;due numeric;existing uuid;
begin
 j:=private.audit_status_job(p_token);if j.unit_id is distinct from '10000000-0000-0000-0000-000000000002'::uuid then raise exception 'ToolTag Job required';end if;select * into p from public.pick_return_orders where job_id=j.id for update;select * into f from public.pickup_attempt_fees where stop_id=p.pickup_missed_stop_id;
 if f.stop_id is null or p.pickup_status<>'Failed' or j.is_lost or now()>=p.pickup_miss_expires_at then raise exception 'Pickup retry payment unavailable';end if;
 select balance_due into due from public.sale_balances where transaction_id=f.sale_id;if coalesce(due,0)<=0 then raise exception 'Retry fee is already paid';end if;
 select id into existing from public.logistics_payment_attempts where pickup_retry_stop_id=f.stop_id and status='pending' order by created_at limit 1;
 if existing is null then existing:=p_attempt;
 insert into public.logistics_payment_attempts(id,unit_id,quote_id,job_id,provider,method,payment_scope,amount,status,pickup_retry_stop_id) values(existing,j.unit_id,j.quote_id,j.id,'stripe','Card','full',due,'pending',f.stop_id);end if;
 return jsonb_build_object('attempt_id',existing,'job_id',j.id,'quote_id',j.quote_id,'job_code',j.code,'amount',due,'customer_email',private.job_customer_recipient(j.id));
end $$;
create function public.choose_pickup_retry_day(p_job uuid,p_token text,p_day date) returns void language plpgsql security definer set search_path='' as $$
declare j public.jobs;p public.pick_return_orders;a jsonb;
begin
 j:=private.route_actor(p_job,p_token);if j.unit_id is distinct from '10000000-0000-0000-0000-000000000002'::uuid then raise exception 'ToolTag Job required';end if;if not exists(select 1 from private.job_status_links where job_id=j.id and token_hash=encode(sha256(convert_to(p_token,'UTF8')),'hex')) then raise exception 'Status link unavailable';end if;
 select * into p from public.pick_return_orders where job_id=j.id for update;if p.pickup_status not in ('Failed','Not Scheduled') or not private.pickup_retry_paid(j.id) or j.is_lost then raise exception 'Confirm the retry payment before choosing a new date';end if;
 a:=public.route_availability(j.id,'Pickup',p_day,p_token);if (a->>'day')::date<>p_day then raise exception 'This Pickup day is no longer available';end if;
 update public.pickup_attempt_fees set selected_date=p_day where stop_id=p.pickup_missed_stop_id;
 update public.pick_return_orders set pickup_status='Not Scheduled',pickup_window_start=(p_day+time '08:00') at time zone 'America/Denver',pickup_window_end=(p_day+time '12:00') at time zone 'America/Denver',pickup_eta=null,pickup_miss_expires_at=null,updated_at=now() where job_id=j.id;
 perform private.route_notice(j.id,'PICKUP_RESCHEDULED','pickup-date-chosen:'||p.pickup_missed_stop_id||':'||p_day,'Your new Pickup date is selected. ToolTag will assign the route block from the shop. Your original Pickup fee is nonrefundable.');
end $$;

-- Account for retry invoices in existing tax/refund/payment abstractions.
do $patch$
declare f record;d text;
begin
 for f in select p.oid from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='private' and p.proname in('job_tax_details','job_refund_available','refund_original_method') loop
  d:=pg_get_functiondef(f.oid);d:=replace(d,'select sale_id from public.delivery_attempt_fees where job_id=p_job','select sale_id from public.delivery_attempt_fees where job_id=p_job union select sale_id from public.pickup_attempt_fees where job_id=p_job');execute d;
 end loop;
 d:=pg_get_functiondef('public.confirm_payment_request(uuid)'::regprocedure);
 d:=replace(d,') q'||chr(10)||'    order by sort_order,transaction_id', 'union all select 2000,s.transaction_id,s.balance_due,s.customer_id from public.pickup_attempt_fees pf join public.sale_balances s on s.transaction_id=pf.sale_id where pf.job_id=j.id and s.balance_due>0 and s.transaction_status<>''Voided'' ) q where r.purpose<>''Pickup Retry Fee'' or q.transaction_id=(select sale_id from public.pickup_attempt_fees where stop_id=r.pickup_retry_stop_id) order by sort_order,transaction_id');
 if position('public.pickup_attempt_fees pf' in d)=0 then raise exception 'Unexpected manual payment allocation';end if;execute d;
 d:=pg_get_functiondef('public.confirm_logistics_card_payment(uuid,text,numeric)'::regprocedure);
 d:=replace(d,') x'||chr(10)||'    order by sort_order,transaction_id', 'union all select 2000,s.transaction_id,s.balance_due,s.customer_id from public.pickup_attempt_fees pf join public.sale_balances s on s.transaction_id=pf.sale_id where pf.job_id=j.id and s.balance_due>0 and s.transaction_status<>''Voided'' ) x where attempt.pickup_retry_stop_id is null or x.transaction_id=(select sale_id from public.pickup_attempt_fees where stop_id=attempt.pickup_retry_stop_id) order by sort_order,transaction_id');
 d:=replace(d,'provider,provider_reference,payment_scope'||chr(10),'provider,provider_reference,payment_scope,pickup_retry_stop_id'||chr(10));
 d:=replace(d,'attempt.payment_scope'||chr(10)||'  )','attempt.payment_scope,attempt.pickup_retry_stop_id'||chr(10)||'  )');
 d:=replace(d,$text$when attempt.payment_scope='full' then$text$, $text$when attempt.pickup_retry_stop_id is not null then 'Pickup Retry Fee' when attempt.payment_scope='full' then$text$);
 if position('public.pickup_attempt_fees pf' in d)=0 then raise exception 'Unexpected card payment allocation';end if;execute d;
end $patch$;
create function private.pickup_miss_deadline() returns trigger language plpgsql security definer set search_path='' as $$
begin if new.status='Failed' and old.status is distinct from 'Failed' and exists(select 1 from public.pick_return_routes where id=new.route_id and leg='Pickup') then update public.pick_return_orders set pickup_miss_expires_at=now()+interval '15 days' where job_id=new.job_id;end if;return new;end $$;
create trigger pickup_miss_deadline after update of status on public.pick_return_stops for each row execute function private.pickup_miss_deadline();
revoke all on function private.pickup_retry_paid(uuid),private.pickup_miss_deadline() from public,anon,authenticated;
revoke all on function public.pickup_retry_context(uuid,text),public.submit_pickup_retry_payment(text,text,uuid,text),public.prepare_pickup_retry_card(text,uuid),public.choose_pickup_retry_day(uuid,text,date) from public;
grant execute on function public.pickup_retry_context(uuid,text),public.submit_pickup_retry_payment(text,text,uuid,text),public.prepare_pickup_retry_card(text,uuid),public.choose_pickup_retry_day(uuid,text,date) to anon,authenticated;

do $patch$
declare d text;
begin
 d:=pg_get_functiondef('private.assign_route(uuid,text,timestamptz,timestamptz,timestamptz)'::regprocedure);
 d:=replace(d,$old$if p_leg='Pickup' then$old$,$new$if p_leg='Pickup' then
 if pr.pickup_missed_stop_id is not null and (select shop_pickup_blocks_enabled from public.unit_settings where unit_id=j.unit_id) and not private.pickup_retry_paid(j.id) then raise exception 'Confirm the new Pickup fee before scheduling';end if;$new$);execute d;
 d:=pg_get_functiondef('private.sale_tax_snapshot()'::regprocedure);
 d:=replace(d,'if new.quote_id is not null then', 'if TG_TABLE_NAME=''sales'' then if new.unit_id=''10000000-0000-0000-0000-000000000002'' and new.tax_snapshot is not null and new.code like ''%/PICKUP%'' then return new;end if;end if; if new.quote_id is not null then');execute d;
 -- The latest retry confirmation, rather than the original fee, must meet the 48-hour cutoff.
 for d in select pg_get_functiondef(p.oid) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname in('public','private') and p.proname in('route_availability','pickup_block_availability','reconcile_pickups') loop
  execute replace(d,$old$('Pickup Fee','Logistics Fee','Logistics Full Prepayment')$old$,$new$('Pickup Fee','Logistics Fee','Logistics Full Prepayment','Pickup Retry Fee')$new$);
 end loop;
end $patch$;

alter table public.unit_settings add column pickup_miss_delivery_refund numeric(14,2) not null default 9.99 check(pickup_miss_delivery_refund>=0);
alter table public.pick_return_orders add column pickup_miss_resolved_at timestamptz;
alter function private.reconcile_pickups() rename to reconcile_pickups_before_retry_expiry;
create function private.reconcile_pickups() returns void language plpgsql security definer set search_path='' as $$
declare p public.pick_return_orders;j public.jobs;amount numeric;original text;loss boolean;
begin
 for p in select o.* from public.pick_return_orders o join public.jobs jj on jj.id=o.job_id join public.unit_settings st on st.unit_id=o.unit_id where o.unit_id='10000000-0000-0000-0000-000000000002' and st.shop_pickup_blocks_enabled and o.pickup_status='Failed' and o.pickup_miss_expires_at<=now() and o.pickup_miss_resolved_at is null and not jj.is_lost and jj.status not in('Cancelled','Completed','Closed') and o.service_method in ('Pickup Only','Pickup & Delivery') and not private.pickup_retry_paid(o.job_id) for update of o loop
  select * into j from public.jobs where id=p.job_id for update;
  update public.transactions t set status='Voided' from public.pickup_attempt_fees f join public.sale_balances b on b.transaction_id=f.sale_id where f.job_id=j.id and f.stop_id=p.pickup_missed_stop_id and f.sale_id=t.id and b.collected=0;
  perform public.public_status_confirm_cancellation(private.ensure_job_status_link(j.id));
  select case when p.service_method='Pickup & Delivery' then pickup_miss_delivery_refund else 0 end into amount from public.unit_settings where unit_id=j.unit_id;
  original:=private.refund_original_method(j.id);
  if amount>0 then
   insert into public.refund_requests(unit_id,job_id,amount,reason,original_method,method,source_kind,source_id,issue_event,issue_event_at,notes,requires_review)
   values(j.unit_id,j.id,amount,'Customer cancellation',original,case when original in('Zelle','Venmo','Card','Bank Transfer','Check') then original end,'Pickup expiry',p.pickup_missed_stop_id,'Pickup',(select completed_at from public.pick_return_stops where id=p.pickup_missed_stop_id),'No customer response within 15 calendar days after missed Pickup. Refund of the unused delivery portion; original Pickup fee is nonrefundable.',true)
   on conflict(source_kind,source_id) do nothing;
   perform private.route_notice(j.id,'REFUND_UPDATE','pickup-expiry-refund:'||p.pickup_missed_stop_id,'Your Pickup was not rescheduled within the response period and the Job was cancelled. A $'||to_char(amount,'FM999999990.00')||' refund of the unused delivery portion is pending staff processing. The original Pickup fee is nonrefundable.');
  end if;
  update public.pick_return_orders set pickup_miss_resolved_at=now() where job_id=j.id;
 end loop;
 perform private.reconcile_pickups_before_retry_expiry();
end $$;
revoke all on function private.reconcile_pickups() from public,anon,authenticated;
notify pgrst,'reload schema';

-- Do not let legacy customer scheduling skip the paid-retry shop queue.
do $patch$
declare d text;
begin
 d:=pg_get_functiondef('public.route_schedule(uuid,text,date,timestamptz,text)'::regprocedure);
 d:=replace(d,'perform private.route_actor(p_job,p_token);','perform private.route_actor(p_job,p_token); if p_leg=''Pickup'' and (select shop_pickup_blocks_enabled from public.unit_settings s join public.jobs j on j.unit_id=s.unit_id where j.id=p_job) and exists(select 1 from public.pick_return_orders where job_id=p_job and pickup_missed_stop_id is not null) then raise exception ''Choose the paid retry date in your status page; the shop will assign its block'';end if;');execute d;
 for d in select pg_get_functiondef(p.oid) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname like 'accept_review_with_logistics%' loop
  execute replace(d,'select timezone,max_pickup_stops_per_saturday','select timezone,case when shop_pickup_blocks_enabled then coalesce((select delivery_capacity from public.pick_return_routes rr where rr.unit_id=q.unit_id and rr.leg=''Pickup'' and rr.route_date=saturday),20) else max_pickup_stops_per_saturday end');
 end loop;
end $patch$;

-- New policy copy in generated notices only; never edit accepted Agreement text.
do $patch$
declare f record;d text;
begin
 for f in select p.oid from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname in('public','private') and p.prokind='f' and p.prosrc like '%pickup-missed:%' loop
  d:=pg_get_functiondef(f.oid);
  d:=replace(d,'Choose a free reschedule to the next available Pickup day or cancel in your status page.','A new Pickup requires paying the Pickup Only fee again, then choosing a new date in your status page. You may also cancel.');
  d:=replace(d,'Choose a free reschedule to the next available Saturday or cancel in your status page.','A new Pickup requires paying the Pickup Only fee again, then choosing a new date in your status page. You may also cancel.');
  execute d;
 end loop;
end $patch$;
notify pgrst,'reload schema';
