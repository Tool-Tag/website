begin;
alter table public.lost_jobs add column replacement_ready_at timestamptz,add column fulfillment_choice text check(fulfillment_choice in ('Shop pickup','Free delivery'));
create table private.lost_payment_details(
 lost_id uuid primary key references public.lost_jobs(id),method text not null check(method in ('Zelle','Venmo','Bank Transfer','Card','Check')),
 encrypted_details text not null,submitted_at timestamptz not null default now()
);
alter table private.lost_payment_details enable row level security;
revoke all on private.lost_payment_details from public,anon,authenticated;
create table public.lost_replacement_deliveries(
 id uuid primary key default gen_random_uuid(),unit_id uuid not null references public.business_units(id),lost_id uuid not null unique references public.lost_jobs(id),job_id uuid not null references public.jobs(id),
 top_priority boolean not null default true check(top_priority),delivery_fee numeric(14,2) not null default 0 check(delivery_fee=0),
 address text not null check(length(trim(address)) between 5 and 500),item_ids uuid[] not null,
 status text not null default 'To Schedule' check(status in ('To Schedule','Scheduled','Delivered','Failed')),route_stop_id uuid unique references public.pick_return_stops(id),created_at timestamptz not null default now(),delivered_at timestamptz
);
alter table public.pick_return_stops add column lost_replacement_id uuid references public.lost_replacement_deliveries(id);
alter table public.lost_replacement_deliveries enable row level security;
revoke all on public.lost_replacement_deliveries from public,anon,authenticated;
grant select on public.lost_replacement_deliveries to authenticated;
create policy lost_replacement_delivery_read on public.lost_replacement_deliveries for select to authenticated using(
 unit_id='10000000-0000-0000-0000-000000000002' and private.staff_active(unit_id) and
 (private.has_any(unit_id,array['jobs.view','pr.routes.plan','pr.routes.live','pr.returns']) or exists(select 1 from public.pick_return_stops s where s.id=route_stop_id and private.route_visible(s.route_id))));

-- The customer's secure form creates the obligation, not the approval button.
do $$declare d text;start_at integer;end_at integer;begin
 d:=pg_get_functiondef('private.lost_staff_action(jsonb)'::regprocedure);
 start_at:=position('  if l.customer_choice=''Refund money'' then' in d);
 end_at:=position('  insert into public.notifications(unit_id,event,entity_id,recipient,dedupe_key,payload)' in substring(d,start_at));
 if start_at=0 or end_at=0 then raise exception 'Unexpected Lost refund creation block';end if;
 d:=substring(d,1,start_at-1)||E'  rid:=l.refund_id;\n'||substring(d,start_at+end_at-1);execute d;
end$$;
create function public.submit_lost_payment_details(p_token text,p_method text,p_encrypted text) returns uuid
language plpgsql security definer set search_path='' as $$declare l public.lost_jobs;original text;rid uuid;begin
 if coalesce(auth.role(),'')<>'service_role' then raise exception 'Server credentials required' using errcode='42501';end if;
 perform 1 from public.business_units where id='10000000-0000-0000-0000-000000000002' for update;
 perform public.public_lost_resolution(p_token,null);
 select x.* into l from public.lost_jobs x join private.lost_resolution_links t on t.lost_id=x.id where t.token_hash=encode(sha256(convert_to(p_token,'UTF8')),'hex') for update of x;
 if l.status<>'In Process' or l.customer_choice<>'Refund money' then raise exception 'This case is not awaiting refund details';end if;
 original:=private.refund_original_method(l.job_id);
 if p_method is null or p_method not in ('Zelle','Venmo','Bank Transfer','Card','Check') or (original in ('Zelle','Venmo','Bank Transfer','Card') and p_method<>original) or (p_method='Card' and original is distinct from 'Card') then raise exception 'Use the original electronic payment method, or choose an electronic method/Check for Cash';end if;
 if p_encrypted is null or p_encrypted !~ '^v1[.][A-Za-z0-9_-]+[.][A-Za-z0-9_-]+[.][A-Za-z0-9_-]+$' or length(p_encrypted)>10000 then raise exception 'Encrypted payment details required';end if;
 if exists(select 1 from private.lost_payment_details where lost_id=l.id) then return l.refund_id;end if;
 insert into private.lost_payment_details(lost_id,method,encrypted_details) values(l.id,p_method,p_encrypted);
 insert into public.refund_requests(unit_id,job_id,amount,reason,original_method,method,issue_event,issue_event_at,reported_at,source_kind,source_id,notes)
 values(l.unit_id,l.job_id,l.market_value,'Other',original,p_method,'Return',l.reported_at,l.reported_at,'Lost',l.id,'Lost item compensation at market value. Secure payment details on file. Lost ID: '||l.id)
 on conflict(source_kind,source_id) do update set source_id=excluded.source_id returning id into rid;
 update public.lost_jobs set refund_id=rid where id=l.id;
 return rid;
end$$;
revoke all on function public.submit_lost_payment_details(text,text,text) from public,anon,authenticated;
grant execute on function public.submit_lost_payment_details(text,text,text) to service_role;
create function private.lost_refund_payment_details(p_refund uuid) returns text language plpgsql stable security definer set search_path='' as $$declare r public.refund_requests;begin
 select * into r from public.refund_requests where id=p_refund;
 if r.unit_id is distinct from '10000000-0000-0000-0000-000000000002'::uuid or not private.has_block(r.unit_id,'payments.refund') then raise exception 'Refund permission required' using errcode='42501';end if;
 return (select encrypted_details from private.lost_payment_details where lost_id=r.source_id and r.source_kind='Lost');
end$$;
create function public.lost_refund_payment_details(p_refund uuid) returns text language sql stable security invoker set search_path='' as $$select private.lost_refund_payment_details(p_refund)$$;
revoke all on function private.lost_refund_payment_details(uuid),public.lost_refund_payment_details(uuid) from public,anon;
grant execute on function private.lost_refund_payment_details(uuid),public.lost_refund_payment_details(uuid) to authenticated;

alter function public.public_lost_resolution(text,text) rename to public_lost_resolution_before_fulfillment;
revoke all on function public.public_lost_resolution_before_fulfillment(text,text) from public,anon,authenticated;
create function public.public_lost_resolution(p_token text,p_choice text default null) returns jsonb language plpgsql security definer set search_path='' as $$declare result jsonb;l public.lost_jobs;begin
 result:=public.public_lost_resolution_before_fulfillment(p_token,p_choice);
 select x.* into l from public.lost_jobs x join private.lost_resolution_links t on t.lost_id=x.id where t.token_hash=encode(sha256(convert_to(p_token,'UTF8')),'hex');
 return result||jsonb_build_object('lost_id',l.id,'ready_at',l.replacement_ready_at,'fulfillment_choice',l.fulfillment_choice,'payment_details_submitted',exists(select 1 from private.lost_payment_details where lost_id=l.id),
 'original_method',private.refund_original_method(l.job_id),'address',(select coalesce(nullif(c.address,''),nullif(q.delivery_address,''),nullif(c.company_address,''),'') from public.jobs j join public.commercial_flows f on f.id=j.flow_id join public.customers c on c.id=f.customer_id left join public.quote_logistics q on q.quote_id=j.quote_id where j.id=l.job_id),
 'delivery',(select jsonb_build_object('status',d.status,'fee',d.delivery_fee,'top_priority',d.top_priority,'route_date',r.route_date,'eta',s.eta) from public.lost_replacement_deliveries d left join public.pick_return_stops s on s.id=d.route_stop_id left join public.pick_return_routes r on r.id=s.route_id where d.lost_id=l.id));
end$$;
revoke all on function public.public_lost_resolution(text,text) from public;
grant execute on function public.public_lost_resolution(text,text) to anon,authenticated,service_role;
create function public.choose_lost_replacement_fulfillment(p_token text,p_choice text,p_address text default null) returns jsonb
language plpgsql security definer set search_path='' as $$declare l public.lost_jobs;address text;begin
 perform public.public_lost_resolution(p_token,null);
 select x.* into l from public.lost_jobs x join private.lost_resolution_links t on t.lost_id=x.id where t.token_hash=encode(sha256(convert_to(p_token,'UTF8')),'hex') for update of x;
 if l.customer_choice<>'Replace Item' or l.replacement_ready_at is null or l.status<>'History' then raise exception 'Your replacement is not ready yet';end if;
 if p_choice is null or p_choice not in ('Shop pickup','Free delivery') then raise exception 'Choose shop pickup or free delivery';end if;
 if l.fulfillment_choice is not null then
  if l.fulfillment_choice<>p_choice then raise exception 'Your choice is already recorded. Contact ToolTag to request a change';end if;
  return public.public_lost_resolution(p_token,null);
 end if;
 if p_choice='Free delivery' then
  address:=trim(coalesce(p_address,''));if length(address) not between 5 and 500 then raise exception 'Enter a complete delivery address';end if;
  insert into public.lost_replacement_deliveries(unit_id,lost_id,job_id,address,item_ids) values(l.unit_id,l.id,l.job_id,address,l.missing_item_ids) on conflict(lost_id) do nothing;
 end if;
 update public.lost_jobs set fulfillment_choice=p_choice where id=l.id;
 return public.public_lost_resolution(p_token,null);
end$$;
revoke all on function public.choose_lost_replacement_fulfillment(text,text,text) from public;
grant execute on function public.choose_lost_replacement_fulfillment(text,text,text) to anon,authenticated;

create function private.lost_fulfillment_event() returns trigger language plpgsql security definer set search_path='' as $$declare path text;begin
 if TG_TABLE_NAME='lost_jobs' then
  if new.status='History' and old.status is distinct from 'History' and new.customer_choice='Replace Item' then
   update public.lost_jobs set replacement_ready_at=now() where id=new.id;
   update private.lost_resolution_links set expires_at=now()+interval '90 days' where lost_id=new.id;
   select payload->>'action_path' into path from public.notifications where dedupe_key='lost-resolution:'||new.id;
   insert into public.notifications(unit_id,event,entity_id,recipient,dedupe_key,payload) values(new.unit_id,'LOST_REPLACEMENT_READY',new.job_id,private.job_customer_recipient(new.job_id),'lost-ready:'||new.id,
   jsonb_build_object('template','notification','live_eligible',true,'subject','Your replacement is ready at the shop','text','Your replacement is ready at the ToolTag shop. Use the secure link to choose shop pickup or free priority delivery. If you choose delivery, confirm your address. ToolTag will assign the next available block; no date selection is required.','action_path',path));
  end if;
 elsif new.source_kind='Lost' and new.status='Issued' and old.status is distinct from 'Issued' then
  update public.lost_jobs set status='History',finalized_at=now(),finalized_by=auth.uid(),resolution_notes='Market-value refund issued through standard Refunds. Customer receipt confirmation continues in Refunds.' where id=new.source_id and refund_id=new.id and status='In Process' and approved_at is not null;
 end if;
 return new;
end$$;
revoke all on function private.lost_fulfillment_event() from public,anon,authenticated;
create trigger lost_replacement_ready after update of status on public.lost_jobs for each row execute function private.lost_fulfillment_event();
create trigger lost_refund_processed after update of status on public.refund_requests for each row execute function private.lost_fulfillment_event();

-- Scheduler creates no charge/sale and never reopens the lost Job.
create function private.schedule_lost_replacement(p_delivery uuid) returns uuid language plpgsql security definer set search_path='' as $$
declare d public.lost_replacement_deliveries;r public.pick_return_routes;day date;start_at timestamptz;sid uuid;seq integer;i integer;weekdays integer[];begin
 perform pg_advisory_xact_lock(hashtextextended('tooltag-lost-priority-delivery',0));
 select * into d from public.lost_replacement_deliveries where id=p_delivery for update;
 if d.id is null or d.status<>'To Schedule' then return d.route_stop_id;end if;
 select return_route_iso_weekdays into weekdays from public.unit_settings where unit_id=d.unit_id;
 day:=(now() at time zone 'America/Denver')::date;
 for i in 0..365 loop
  start_at:=(day+time '14:00') at time zone 'America/Denver';
  if extract(isodow from day)::integer=any(weekdays) and start_at>now()+interval '1 hour' then
   insert into public.pick_return_routes(unit_id,leg,route_date) values(d.unit_id,'Return',day) on conflict(unit_id,route_date,leg) do nothing;
   select * into r from public.pick_return_routes where unit_id=d.unit_id and route_date=day and leg='Return' for update;
   if (r.operator_id is null or private.driver_loss_eligible(r.operator_id)) and r.confirmed_at is null and r.departed_at is null and r.started_at is null and r.status not in ('Completed','Cancelled') and (select count(*) from public.pick_return_stops where route_id=r.id and status<>'Cancelled')<r.delivery_capacity and not exists(select 1 from public.pick_return_stops where route_id=r.id and job_id=d.job_id) then
    select coalesce(max(sequence),0)+1 into seq from public.pick_return_stops where route_id=r.id;
    insert into public.pick_return_stops(unit_id,route_id,job_id,sequence,status,window_start,window_end,eta,address,lost_replacement_id) values(d.unit_id,r.id,d.job_id,seq,'Scheduled',start_at,start_at+interval '4 hours',start_at,d.address,d.id) returning id into sid;
    update public.lost_replacement_deliveries set status='Scheduled',route_stop_id=sid where id=d.id;
    perform private.order_delivery_block(r.id);
    return sid;
   end if;
  end if;day:=day+1;
 end loop;
 return null;
end$$;
revoke all on function private.schedule_lost_replacement(uuid) from public,anon,authenticated;
create function public.schedule_lost_replacement(p_delivery uuid) returns uuid language plpgsql security definer set search_path='' as $$begin
 if not private.has_block('10000000-0000-0000-0000-000000000002','pr.routes.plan') or not exists(select 1 from public.lost_replacement_deliveries where id=p_delivery and unit_id='10000000-0000-0000-0000-000000000002') then raise exception 'Route planning permission required';end if;
 return private.schedule_lost_replacement(p_delivery);
end$$;
revoke all on function public.schedule_lost_replacement(uuid) from public,anon;
grant execute on function public.schedule_lost_replacement(uuid) to authenticated;
create function private.reconcile_lost_replacements() returns void language plpgsql security definer set search_path='' as $$declare id uuid;begin
 for id in select d.id from public.lost_replacement_deliveries d where d.status='To Schedule' order by d.created_at for update skip locked loop perform private.schedule_lost_replacement(id);end loop;
end$$;
revoke all on function private.reconcile_lost_replacements() from public,anon,authenticated;
-- Existing scheduled worker handles automatic assignment after the visible To Schedule queue.
do $$declare d text;begin
 d:=pg_get_functiondef('public.run_scheduled_tasks()'::regprocedure);if position('perform private.audit_cutoff_reminders();' in d)=0 then raise exception 'Unexpected worker entry point';end if;d:=replace(d,'perform private.audit_cutoff_reminders();','perform private.reconcile_lost_replacements(); perform private.audit_cutoff_reminders();');execute d;
 d:=pg_get_functiondef('private.order_delivery_block(uuid,uuid[])'::regprocedure);
 if position('order by p.production_ready_at,j.created_at,s.id' in d)=0 then raise exception 'Unexpected block ordering';end if;
 d:=replace(d,'order by p.production_ready_at,j.created_at,s.id','order by (s.lost_replacement_id is not null) desc,p.production_ready_at,j.created_at,s.id');execute d;
 d:=pg_get_functiondef('private.enqueue_sms()'::regprocedure);d:=replace(d,'''LOST_RESOLUTION''','''LOST_RESOLUTION'',''LOST_REPLACEMENT_READY'',''LOST_REPLACEMENT_UPDATE''');execute d;
 d:=pg_get_functiondef('public.sms_message_context(uuid)'::regprocedure);d:=replace(d,'n.event=''LOST_RESOLUTION''','n.event in (''LOST_RESOLUTION'',''LOST_REPLACEMENT_READY'',''LOST_REPLACEMENT_UPDATE'')');execute d;
 d:=pg_get_functiondef('public.lost_job_list()'::regprocedure);d:=replace(d,'''id'',l.id','''replacement_ready_at'',l.replacement_ready_at,''fulfillment_choice'',l.fulfillment_choice,''payment_details_submitted'',exists(select 1 from private.lost_payment_details where lost_id=l.id),''id'',l.id');execute d;
end$$;

-- Dedicated free-replacement stop transitions never mutate original work/payment state.
alter function public.return_driver_action(uuid,text,boolean) rename to return_driver_action_before_lost_fulfillment;
revoke all on function public.return_driver_action_before_lost_fulfillment(uuid,text,boolean) from public,anon,authenticated;
create function public.return_driver_action(p_stop uuid,p_action text,p_present boolean default false) returns jsonb language plpgsql security definer set search_path='' as $$
declare s public.pick_return_stops;r public.pick_return_routes;begin
 select * into s from public.pick_return_stops where id=p_stop for update;
 if s.lost_replacement_id is null then return public.return_driver_action_before_lost_fulfillment(p_stop,p_action,p_present);end if;
 select * into r from public.pick_return_routes where id=s.route_id for update;perform private.require_route(r.id);
 if r.leg<>'Return' or r.departed_at is null or r.confirmed_at is not null or exists(select 1 from public.route_incidents where route_id=r.id and status='Open') then raise exception 'Start an available route before continuing';end if;
 if p_action='delivered' and s.status='Completed' then return jsonb_build_object('ok',true);end if;
 if p_action='en-route' and s.status='Scheduled' then update public.pick_return_stops set status='En Route' where id=s.id;
 elsif p_action='arrived' and s.status='En Route' then
  update public.pick_return_stops set status='Arrived',arrived_at=now(),return_wait_until=now()+interval '5 minutes' where id=s.id;
 elsif p_action='customer-coming' and s.status='Arrived' then update public.pick_return_stops set return_customer_coming_at=now(),return_wait_until=null where id=s.id;
 elsif p_action='delivered' and s.status='Arrived' and p_present then
  if not exists(select 1 from public.documents where pick_return_stop_id=s.id and job_id=s.job_id and type='Delivery Evidence' and status='Available' and storage_status='stored') then raise exception 'Upload delivery evidence before confirming delivery';end if;
  update public.pick_return_stops set status='Completed',completed_at=now(),customer_present_at=now() where id=s.id;
  update public.lost_replacement_deliveries set status='Delivered',delivered_at=now() where id=s.lost_replacement_id;
 elsif p_action='not-home' and s.status='Arrived' and s.return_wait_until<=now() and s.return_customer_coming_at is null then
  update public.pick_return_stops set status='Failed',completed_at=now() where id=s.id;
  update public.lost_replacement_deliveries set status='Failed' where id=s.lost_replacement_id;
 else raise exception 'Invalid replacement delivery action or customer presence required';end if;
 if p_action in ('en-route','arrived','delivered','not-home') then
  insert into public.notifications(unit_id,event,entity_id,recipient,dedupe_key,payload) values(s.unit_id,'LOST_REPLACEMENT_UPDATE',s.job_id,private.job_customer_recipient(s.job_id),'lost-replacement:'||s.id||':'||p_action,jsonb_build_object('template','notification','live_eligible',true,'subject','Replacement delivery update','action_path',(select payload->>'action_path' from public.notifications where dedupe_key='lost-resolution:'||(select lost_id from public.lost_replacement_deliveries where id=s.lost_replacement_id)),'text',case p_action when 'en-route' then 'ToolTag is on the way with your free replacement.' when 'arrived' then 'Your driver has arrived with your replacement. Please come to the door.' when 'delivered' then 'Your replacement was handed over. Thank you for your patience.' else 'We could not hand over your replacement. Nothing was left at the door. ToolTag will coordinate the next steps.' end)) on conflict do nothing;
 end if;
 return jsonb_build_object('ok',true);
end$$;
revoke all on function public.return_driver_action(uuid,text,boolean) from public,anon;
grant execute on function public.return_driver_action(uuid,text,boolean) to authenticated;

-- Reuse route load/return gates, restricted to the actual replacement manifest.
create function private.replacement_manifest_item(p_stop uuid,p_item uuid) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.pick_return_stops s where s.id=p_stop and (s.lost_replacement_id is null or exists(select 1 from public.lost_replacement_deliveries d where d.id=s.lost_replacement_id and p_item=any(d.item_ids))))
$$;
revoke all on function private.replacement_manifest_item(uuid,uuid) from public,anon,authenticated;
do $patch$declare d text;begin
 d:=pg_get_functiondef('public.route_item_checklist(uuid,text)'::regprocedure);
 if position('i.job_id=j.id and i.stage' in d)=0 then raise exception 'Unexpected route checklist';end if;
 d:=replace(d,'i.job_id=j.id and i.stage','i.job_id=j.id and private.replacement_manifest_item(s.id,i.id) and i.stage');execute d;
 d:=pg_get_functiondef('public.verify_route_items(uuid,text,uuid[])'::regprocedure);
 if position('id=x and job_id=s.job_id' in d)=0 then raise exception 'Unexpected item verification';end if;
 d:=replace(d,'id=x and job_id=s.job_id','id=x and private.replacement_manifest_item(s.id,x) and job_id=s.job_id');execute d;
 d:=pg_get_functiondef('public.depart_driver_route(uuid)'::regprocedure);
 d:=replace(d,$str$and (j.status='Cancelled'$str$,$str$and ss.lost_replacement_id is null and (j.status='Cancelled'$str$);
 d:=replace(d,$str$and i.stage<>'Cancelled' and not exists$str$,$str$and private.replacement_manifest_item(ss.id,i.id) and i.stage<>'Cancelled' and not exists$str$);
 d:=replace(d,$str$and ((b.balance_due>0$str$,$str$and ss.lost_replacement_id is null and ((b.balance_due>0$str$);
 if position('perform private.route_notice(s.job_id,case when r.leg=' in d)=0 then raise exception 'Unexpected departure notification';end if;
 d:=replace(d,'perform private.route_notice(s.job_id,case when r.leg=','if s.lost_replacement_id is null then perform private.route_notice(s.job_id,case when r.leg=');
 d:=replace(d,'counted:=counted+1;',$notice$
 else
 insert into public.notifications(unit_id,event,entity_id,recipient,dedupe_key,payload)
 values(s.unit_id,'LOST_REPLACEMENT_UPDATE',s.job_id,private.job_customer_recipient(s.job_id),'lost-replacement-departed:'||s.id,
 jsonb_build_object('template','notification','live_eligible',true,'subject','Your replacement is on its way','text','ToolTag has left the shop with your free replacement. Follow the secure link for delivery updates.',
 'action_path',(select payload->>'action_path' from public.notifications where dedupe_key='lost-resolution:'||(select lost_id from public.lost_replacement_deliveries where id=s.lost_replacement_id)))) on conflict do nothing;
 end if;
 counted:=counted+1;$notice$);
 execute d;
 d:=pg_get_functiondef('public.confirm_pick_return_route(uuid)'::regprocedure);
 d:=replace(d,$str$and i.stage<>'Cancelled' and not exists$str$,$str$and private.replacement_manifest_item(s.id,i.id) and i.stage<>'Cancelled' and not exists$str$);execute d;
 d:=pg_get_functiondef('private.register_failed_delivery()'::regprocedure);
 d:=replace(d,$str$if new.status='Failed'$str$,$str$if new.lost_replacement_id is null and new.status='Failed'$str$);execute d;
 -- Priority stays above ordinary stops even after a manual reorder.
 d:=pg_get_functiondef('private.order_delivery_block(uuid,uuid[])'::regprocedure);
 d:=replace(d,'else ids:=p_order;end if;','else select array_agg(x.id order by (s.lost_replacement_id is not null) desc,x.ordinality) into ids from unnest(p_order) with ordinality x(id,ordinality) join public.pick_return_stops s on s.id=x.id and s.route_id=p_route;end if;');execute d;
end $patch$;
create function private.requeue_removed_replacement() returns trigger language plpgsql security definer set search_path='' as $$begin
 if new.status='Cancelled' and old.status is distinct from 'Cancelled' and new.lost_replacement_id is not null then
  update public.lost_replacement_deliveries set status='To Schedule',route_stop_id=null where id=new.lost_replacement_id and status='Scheduled';
 end if;return new;
end$$;
revoke all on function private.requeue_removed_replacement() from public,anon,authenticated;
create trigger requeue_removed_replacement after update of status on public.pick_return_stops for each row execute function private.requeue_removed_replacement();

-- Original delivery reconciliation must not move or charge the independent free replacement.
do $$declare d text;begin
 d:=pg_get_functiondef('private.reconcile_delivery(uuid)'::regprocedure);
 d:=regexp_replace(d,'\mbegin\M',E'begin if exists(select 1 from public.jobs where id=p_job and is_lost) then return;end if;','i');execute d;
 d:=pg_get_functiondef('public.save_delivery_block(uuid,uuid,uuid[],uuid[],integer,text)'::regprocedure);
 d:=replace(d,'where job_id=jid;', 'where job_id=jid and not exists(select 1 from public.pick_return_stops where id=sid and lost_replacement_id is not null);');execute d;
end$$;

create function private.require_lost_refund_instructions() returns trigger language plpgsql security definer set search_path='' as $$begin
 if new.source_kind='Lost' and new.status='Issued' and old.status is distinct from 'Issued' and not exists(select 1 from private.lost_payment_details p where p.lost_id=new.source_id and p.method=new.method) then raise exception 'Issue the Lost refund using the customer-submitted payment method';end if;
 return new;
end$$;
revoke all on function private.require_lost_refund_instructions() from public,anon,authenticated;
create trigger require_lost_refund_instructions before update of status on public.refund_requests for each row execute function private.require_lost_refund_instructions();
notify pgrst,'reload schema';
commit;
