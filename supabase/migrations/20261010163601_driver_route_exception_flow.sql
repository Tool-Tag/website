-- Route interruptions never count as customer misses.
create table public.route_incidents (
 id uuid primary key default gen_random_uuid(), unit_id uuid not null references public.business_units(id), route_id uuid not null unique references public.pick_return_routes(id),
 status text not null default 'Open' check(status in ('Open','Continued','Rescheduled','NoDriver')), reported_at timestamptz not null default now(), deadline timestamptz not null default now()+interval '15 minutes', resolved_at timestamptz
);
create table public.route_incident_jobs (
 incident_id uuid not null references public.route_incidents(id),unit_id uuid not null references public.business_units(id),job_id uuid not null references public.jobs(id),stop_id uuid not null references public.pick_return_stops(id),choice text not null default 'Wait' check(choice in ('Wait','Reschedule','Shop')), primary key(incident_id,job_id)
);
create table public.route_compensations (
 id uuid primary key default gen_random_uuid(),unit_id uuid not null references public.business_units(id),incident_id uuid not null references public.route_incidents(id),job_id uuid not null references public.jobs(id),
 amount numeric(14,2) not null check(amount in (5,10)), paid_amount numeric(14,2) not null default 0 check(paid_amount>=0), original_id uuid references public.transactions(id), method text,
 status text not null default 'Pending' check(status in ('Pending','Processing','ManualRequired','ReviewRequired','Completed')), provider_reference text,claim_token uuid,claim_until timestamptz, claim_amount numeric(14,2),error text,unique(incident_id,job_id)
);
create table private.route_refund_parts (
 compensation_id uuid not null references public.route_compensations(id),offset_amount numeric(14,2) not null,amount numeric(14,2) not null,provider_id text,transaction_id uuid references public.transactions(id),primary key(compensation_id,offset_amount)
);
alter table public.route_incidents enable row level security;
alter table public.route_incident_jobs enable row level security;
alter table public.route_compensations enable row level security;
alter table private.route_refund_parts enable row level security;
create policy route_incidents_staff on public.route_incidents for select to authenticated using(exists(select 1 from public.memberships m where m.unit_id=route_incidents.unit_id and m.user_id=auth.uid() and m.role='admin'));
create policy route_incident_jobs_staff on public.route_incident_jobs for select to authenticated using(exists(select 1 from public.memberships m where m.unit_id=route_incident_jobs.unit_id and m.user_id=auth.uid() and m.role='admin'));
create policy route_compensations_staff on public.route_compensations for select to authenticated using(exists(select 1 from public.memberships m where m.unit_id=route_compensations.unit_id and m.user_id=auth.uid() and m.role='admin'));
grant select on public.route_incidents,public.route_incident_jobs,public.route_compensations to authenticated;
revoke all on private.route_refund_parts from public,anon,authenticated;

create function private.queue_route_compensation(p_incident uuid,p_job uuid,p_amount numeric) returns void language plpgsql security definer set search_path='' as $$
declare j public.jobs;t public.transactions;available numeric;
begin
 select * into j from public.jobs where id=p_job for update;
 select c.* into t from public.collections cc join public.transactions c on c.id=cc.transaction_id join public.sales s on s.transaction_id=cc.sale_id where s.job_id=j.id and c.status<>'Voided' and c.amount>=p_amount order by c.created_at desc limit 1;
 select coalesce(sum(x.amount),0) into available from public.refunds rf join public.transactions x on x.id=rf.transaction_id where rf.original_id=t.id and x.status<>'Voided';
 insert into public.route_compensations(unit_id,incident_id,job_id,amount,original_id,method,provider_reference,status,error)
 values(j.unit_id,p_incident,j.id,p_amount,t.id,t.payment_method,case when t.reference like 'STRIPE:%' then substr(t.reference,8) end,
 case when t.id is null or t.amount-available<p_amount then 'ReviewRequired' when t.payment_method='Card' and t.reference like 'STRIPE:%' then 'Pending' else 'ManualRequired' end,
 case when t.id is null or t.amount-available<p_amount then 'No sufficient refundable collection; do not fabricate a refund' when t.payment_method<>'Card' then 'This payment method has no connected automatic refund transport' end)
 on conflict(incident_id,job_id) do update set amount=greatest(route_compensations.amount,excluded.amount),status=case when route_compensations.status='Completed' and excluded.amount>route_compensations.paid_amount then case when route_compensations.method='Card' then 'Pending' else 'ManualRequired' end else route_compensations.status end;
end $$;
revoke all on function private.queue_route_compensation(uuid,uuid,numeric) from public;

create function public.report_driver_incident(p_route uuid) returns uuid language plpgsql security definer set search_path='' as $$
declare r public.pick_return_routes;i public.route_incidents;s public.pick_return_stops;
begin
 select * into r from public.pick_return_routes where id=p_route for update;
 if r.id is null or not exists(select 1 from public.business_units where id=r.unit_id and code='TOOLTAG') then raise exception 'Route unavailable';end if;perform private.require_admin(r.unit_id);
 select * into i from public.route_incidents where route_id=r.id;
 if i.id is not null then return i.id;end if;
 if r.status in ('Cancelled','Completed') or r.confirmed_at is not null then raise exception 'Route is closed';end if;
 if not exists(select 1 from public.pick_return_stops where route_id=r.id and status in ('Scheduled','En Route','Arrived')) then raise exception 'No remaining confirmed stops';end if;
 insert into public.route_incidents(unit_id,route_id) values(r.unit_id,r.id) returning * into i;
 for s in select * from public.pick_return_stops where route_id=r.id and status in ('Scheduled','En Route','Arrived') order by sequence loop
  insert into public.route_incident_jobs(incident_id,unit_id,job_id,stop_id) values(i.id,r.unit_id,s.job_id,s.id);
  perform private.route_notice(s.job_id,'ROUTE_INTERRUPTED','route-incident:'||i.id||':'||s.job_id,'We are sorry: our driver is unable to continue right now. ToolTag will confirm within 15 minutes whether a replacement can continue or your service moves to the next available '||case when r.leg='Pickup' then 'Saturday' else 'Sunday' end||'. If a replacement is available, you may wait approximately one hour with a $5 refund, or reschedule. If no driver is available, a $10 refund is due; '||case when r.leg='Pickup' then 'Pickup will be rescheduled free of charge. You do not need to bring your pieces to the shop.' else 'you may collect your items at the shop for free.' end||' Refunds go back to your original payment method when its provider supports automatic refunds; otherwise ToolTag must issue the payment. Follow your status page.');
 end loop;
 return i.id;
end $$;
revoke all on function public.report_driver_incident(uuid) from public;
grant execute on function public.report_driver_incident(uuid) to authenticated;

create function private.reschedule_incident_job(p_incident uuid,p_job uuid) returns void language plpgsql security definer set search_path='' as $$
declare r public.pick_return_routes;a jsonb;
begin
 select rr.* into r from public.pick_return_routes rr join public.route_incidents i on i.route_id=rr.id where i.id=p_incident;
 update public.pick_return_stops set status='Cancelled' where job_id=p_job and route_id=r.id and status in ('Scheduled','En Route','Arrived');
 a:=public.route_availability(p_job,r.leg,greatest(r.route_date+1,(now() at time zone 'America/Denver')::date),private.ensure_job_status_link(p_job));
 perform private.assign_route(p_job,r.leg,(a->>'window_start')::timestamptz,(a->>'window_end')::timestamptz,(a->'slots'->0->>'eta')::timestamptz);
 update public.route_incident_jobs set choice='Reschedule' where incident_id=p_incident and job_id=p_job;
 perform private.queue_route_compensation(p_incident,p_job,10);
 perform private.route_notice(p_job,'ROUTE_RESCHEDULED','incident-reschedule:'||p_incident||':'||p_job,'We are sorry for the interruption. Your service is rescheduled to '||to_char((a->>'window_start')::timestamptz at time zone 'America/Denver','FMDay, FMMonth DD')||' at no extra charge. A $10 refund is due. Check your status page for refund progress.');
end $$;
revoke all on function private.reschedule_incident_job(uuid,uuid) from public;

create function private.resolve_driver_incident(p_incident uuid,p_outcome text) returns void language plpgsql security definer set search_path='' as $$
declare i public.route_incidents;r public.pick_return_routes;x public.route_incident_jobs;
begin
 select * into i from public.route_incidents where id=p_incident for update;
 if i.id is null then raise exception 'Incident unavailable';end if;
 if i.status<>'Open' then return;end if;
 if p_outcome not in ('Continued','Rescheduled','NoDriver') then raise exception 'Choose a route outcome';end if;
 select * into r from public.pick_return_routes where id=i.route_id for update;
 update public.route_incidents set status=p_outcome,resolved_at=now() where id=i.id;
 for x in select * from public.route_incident_jobs where incident_id=i.id order by job_id loop
  if exists(select 1 from public.jobs where id=x.job_id and status='Cancelled') then update public.pick_return_stops set status='Cancelled' where id=x.stop_id and status in ('Scheduled','En Route','Arrived');continue;end if;
  if not exists(select 1 from public.pick_return_stops where id=x.stop_id and status in ('Scheduled','En Route','Arrived')) then continue;end if;
  if p_outcome='Continued' and x.choice='Wait' then
   perform private.queue_route_compensation(i.id,x.job_id,5);
   perform private.route_notice(x.job_id,'ROUTE_CONTINUING','incident-continue:'||i.id||':'||x.job_id,'A replacement driver is available. We expect an approximately one-hour delay. A $5 refund is due to your original payment method. You can still choose the next available route day in your status page.');
  elsif p_outcome='NoDriver' and r.leg='Return' then
   update public.pick_return_stops set status='Cancelled' where id=x.stop_id;
   update public.pick_return_orders set delivery_payment_status='Shop Pickup',return_status='Delivery In Progress',return_window_start=null,return_window_end=null,return_eta=null,return_reservation_stop_id=null,return_reservation_expires_at=null where job_id=x.job_id;
   update public.route_incident_jobs set choice='Shop' where incident_id=i.id and job_id=x.job_id;
   perform private.queue_route_compensation(i.id,x.job_id,10);
   perform private.route_notice(x.job_id,'ROUTE_NO_DRIVER','incident-shop:'||i.id||':'||x.job_id,'We are sorry: no replacement driver is available. A $10 refund is due. Your items remain at the shop for free pickup when instructed; nothing was left unattended.');
  else perform private.reschedule_incident_job(i.id,x.job_id);end if;
 end loop;
end $$;
revoke all on function private.resolve_driver_incident(uuid,text) from public;

create function public.resolve_driver_incident(p_incident uuid,p_outcome text) returns jsonb language plpgsql security definer set search_path='' as $$
declare i public.route_incidents;
begin
 select * into i from public.route_incidents where id=p_incident;perform private.require_admin(i.unit_id);
 if i.status='Open' and now()>=i.deadline then perform private.resolve_driver_incident(i.id,'Rescheduled');return jsonb_build_object('expired',true);end if;
 perform private.resolve_driver_incident(i.id,p_outcome);return jsonb_build_object('ok',true);
end $$;
revoke all on function public.resolve_driver_incident(uuid,text) from public;
grant execute on function public.resolve_driver_incident(uuid,text) to authenticated;

create function private.reconcile_driver_exceptions() returns void language plpgsql security definer set search_path='' as $$
declare i record;
begin
 for i in select id from public.route_incidents where status='Open' and deadline<=now() and unit_id in (select id from public.business_units where code='TOOLTAG') order by deadline loop perform private.resolve_driver_incident(i.id,'Rescheduled');end loop;
end $$;
revoke all on function private.reconcile_driver_exceptions() from public;

create function private.driver_incident_gate() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.status is distinct from old.status and new.status in ('En Route','Arrived','Completed') and exists(select 1 from public.route_incidents i join public.route_incident_jobs x on x.incident_id=i.id where i.route_id=new.route_id and x.stop_id=new.id and i.status='Open') then raise exception 'Route paused: ToolTag must confirm replacement or rescheduling';end if;
 return new;
end $$;
revoke all on function private.driver_incident_gate() from public;
create trigger driver_incident_gate before update on public.pick_return_stops for each row execute function private.driver_incident_gate();

create function public.driver_incident_context(p_job uuid,p_token text) returns jsonb language plpgsql security definer set search_path='' as $$
declare j public.jobs;i public.route_incidents;x public.route_incident_jobs;refund public.route_compensations;
begin
 j:=private.route_actor(p_job,p_token);
 if not exists(select 1 from private.job_status_links where job_id=j.id and token_hash=encode(sha256(convert_to(coalesce(p_token,''),'UTF8')),'hex')) then raise exception 'Status link unavailable';end if;
 select ii.* into i from public.route_incidents ii join public.route_incident_jobs xx on xx.incident_id=ii.id where xx.job_id=j.id order by ii.reported_at desc limit 1;
 if i.id is null then return null;end if;
 if i.status='Open' and i.deadline<=now() then perform private.resolve_driver_incident(i.id,'Rescheduled');select * into i from public.route_incidents where id=i.id;end if;
 select * into x from public.route_incident_jobs where incident_id=i.id and job_id=j.id;
 select * into refund from public.route_compensations where incident_id=i.id and job_id=j.id;
 return jsonb_build_object('id',i.id,'status',i.status,'deadline',i.deadline,'choice',x.choice,'leg',(select leg from public.pick_return_routes where id=i.route_id),'refund_amount',refund.amount,'refunded_amount',refund.paid_amount,'refund_status',refund.status);
end $$;
revoke all on function public.driver_incident_context(uuid,text) from public;
grant execute on function public.driver_incident_context(uuid,text) to anon,authenticated;

create function public.driver_incident_choice(p_job uuid,p_token text,p_choice text) returns void language plpgsql security definer set search_path='' as $$
declare j public.jobs;i public.route_incidents;
begin
 perform public.driver_incident_context(p_job,p_token);
 j:=private.route_actor(p_job,p_token);
 select ii.* into i from public.route_incidents ii join public.route_incident_jobs x on x.incident_id=ii.id where x.job_id=j.id order by ii.reported_at desc limit 1 for update of ii;
 if i.id is null or i.status not in ('Open','Continued') then raise exception 'This route decision is already resolved';end if;
 if p_choice not in ('Wait','Reschedule') then raise exception 'Choose wait or reschedule';end if;
 if exists(select 1 from public.route_incident_jobs where incident_id=i.id and job_id=j.id and choice='Reschedule') then return;end if;
 if not exists(select 1 from public.route_incident_jobs x join public.pick_return_stops s on s.id=x.stop_id where x.incident_id=i.id and x.job_id=j.id and s.status in ('Scheduled','En Route','Arrived')) then raise exception 'This stop is already resolved';end if;
 update public.route_incident_jobs set choice=p_choice where incident_id=i.id and job_id=j.id;
 if i.status='Continued' and p_choice='Reschedule' then perform private.reschedule_incident_job(i.id,j.id);end if;
end $$;
revoke all on function public.driver_incident_choice(uuid,text,text) from public;
grant execute on function public.driver_incident_choice(uuid,text,text) to anon,authenticated;

create function public.claim_route_refunds() returns jsonb language plpgsql security definer set search_path='' as $$
declare c public.route_compensations;items jsonb:='[]';available numeric;t public.transactions;claim uuid;part_amount numeric;
begin
 if coalesce(auth.role(),'')<>'service_role' then raise exception 'Worker credentials required';end if;
 for c in select * from public.route_compensations where method='Card' and original_id is not null and paid_amount<amount and status in ('Pending','Processing') and (claim_until is null or claim_until<=now()) order by id limit 10 for update skip locked loop
  select * into t from public.transactions where id=c.original_id for update;
  select t.amount-coalesce(sum(rt.amount),0) into available from public.refunds rf join public.transactions rt on rt.id=rf.transaction_id where rf.original_id=t.id and rt.status<>'Voided';
  select amount into part_amount from private.route_refund_parts where compensation_id=c.id and offset_amount=c.paid_amount;
  part_amount:=coalesce(part_amount,c.amount-c.paid_amount);
  if available<part_amount then update public.route_compensations set status='ReviewRequired',error='Refund exceeds available original payment' where id=c.id;continue;end if;
  claim:=gen_random_uuid();
  update public.route_compensations set status='Processing',claim_token=claim,claim_until=now()+interval '5 minutes',claim_amount=part_amount where id=c.id;
  insert into private.route_refund_parts(compensation_id,offset_amount,amount) values(c.id,c.paid_amount,part_amount) on conflict do nothing;
  items:=items||jsonb_build_array(jsonb_build_object('id',c.id,'claim',claim,'offset',c.paid_amount,'amount',(select amount from private.route_refund_parts where compensation_id=c.id and offset_amount=c.paid_amount),'session',c.provider_reference));
 end loop;
 return items;
end $$;
revoke all on function public.claim_route_refunds() from public;
grant execute on function public.claim_route_refunds() to service_role;

create function private.record_route_refund(p_id uuid,p_amount numeric,p_method text,p_reference text) returns uuid language plpgsql security definer set search_path='' as $$
declare c public.route_compensations;t public.transactions;refund_id uuid;available numeric;
begin
 select * into c from public.route_compensations where id=p_id for update;
 select * into t from public.transactions where id=c.original_id for update;
 if t.id is null or t.status='Voided' then raise exception 'Original payment unavailable';end if;
 select t.amount-coalesce(sum(rt.amount),0) into available from public.refunds rf join public.transactions rt on rt.id=rf.transaction_id where rf.original_id=t.id and rt.status<>'Voided';
 if p_amount<=0 or p_amount>available or p_amount>c.amount-c.paid_amount then raise exception 'Invalid refundable amount';end if;
 insert into public.transactions(unit_id,account_id,type,transaction_date,amount,customer_id,description,payment_method,reference,created_by)
 values(c.unit_id,t.account_id,'REFUND',(now() at time zone 'America/Denver')::date,p_amount,t.customer_id,'Driver route interruption refund',p_method,p_reference,auth.uid()) returning id into refund_id;
 insert into public.refunds(transaction_id,unit_id,original_id,subtype,override_reason) values(refund_id,c.unit_id,t.id,'Customer Refund','Route incident '||c.incident_id);
 update public.route_compensations set paid_amount=paid_amount+p_amount,status=case when paid_amount+p_amount>=amount then 'Completed' when method='Card' then 'Pending' else 'ManualRequired' end,claim_token=null,claim_until=null,error=null where id=c.id;
 perform private.route_notice(c.job_id,'REFUND_UPDATE','route-refund:'||c.id||':'||refund_id,'ToolTag issued a $'||to_char(p_amount,'FM999990.00')||' refund to your original payment method for the route interruption. Your provider may take time to post it.');
 return refund_id;
end $$;
revoke all on function private.record_route_refund(uuid,numeric,text,text) from public;

create function public.finish_route_refund(p_id uuid,p_claim uuid,p_provider_id text,p_state text) returns void language plpgsql security definer set search_path='' as $$
declare c public.route_compensations;part private.route_refund_parts;recorded_refund uuid;
begin
 if coalesce(auth.role(),'')<>'service_role' then raise exception 'Worker credentials required';end if;
 select * into c from public.route_compensations where id=p_id for update;
 if c.claim_token is distinct from p_claim then raise exception 'Refund claim unavailable';end if;
 select * into part from private.route_refund_parts where compensation_id=c.id and offset_amount=c.paid_amount;
 if part.amount is null then raise exception 'Refund part unavailable';end if;
 update private.route_refund_parts set provider_id=p_provider_id where compensation_id=c.id and offset_amount=c.paid_amount;
 if p_state='succeeded' then
  recorded_refund:=private.record_route_refund(c.id,part.amount,'Card',p_provider_id);
  update private.route_refund_parts set transaction_id=recorded_refund where compensation_id=c.id and offset_amount=part.offset_amount;
 else
  update public.route_compensations set status=case when p_state in ('failed','canceled','requires_action') then 'ReviewRequired' else 'Processing' end,error=case when p_state='pending' then 'Provider refund is pending' else 'Automatic refund requires review; not marked paid' end,claim_token=null,claim_until=now()+interval '5 minutes' where id=c.id;
 end if;
end $$;
revoke all on function public.finish_route_refund(uuid,uuid,text,text) from public;
grant execute on function public.finish_route_refund(uuid,uuid,text,text) to service_role;

create function public.confirm_route_refund(p_id uuid,p_reference text) returns void language plpgsql security definer set search_path='' as $$
declare c public.route_compensations;
begin
 select * into c from public.route_compensations where id=p_id for update;perform private.require_admin(c.unit_id);
 if c.status='Completed' then return;end if;
 if c.status<>'ManualRequired' or c.method is null or nullif(trim(p_reference),'') is null then raise exception 'Record proof/reference of the actual original-method refund';end if;
 perform private.record_route_refund(c.id,c.amount-c.paid_amount,c.method,p_reference);
end $$;
revoke all on function public.confirm_route_refund(uuid,text) from public;
grant execute on function public.confirm_route_refund(uuid,text) to authenticated;

CREATE OR REPLACE FUNCTION public.run_scheduled_tasks() RETURNS void
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

