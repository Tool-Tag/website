-- Forward-only Lost resolution. No historical notifications or payments are replayed.
begin;
alter table public.lost_jobs
 add column status text not null default 'New' check(status in ('New','In Process','History')),
 add column market_value numeric(14,2) check(market_value>0),
 add column notified_at timestamptz,
 add column customer_choice text check(customer_choice in ('Replace Item','Refund money')),
 add column responded_at timestamptz,
 add column approved_at timestamptz,
 add column approved_by uuid references auth.users(id),
 add column refund_id uuid unique references public.refund_requests(id),
 add column finalized_at timestamptz,
 add column finalized_by uuid references auth.users(id),
 add column resolution_notes text;
create table private.lost_resolution_links(
 lost_id uuid primary key references public.lost_jobs(id), token_hash text not null unique,
 expires_at timestamptz not null
);
alter table private.lost_resolution_links enable row level security;
revoke all on private.lost_resolution_links from public,anon,authenticated;

create function private.lost_staff_action(p jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare l public.lost_jobs; token text;recipient text;rid uuid;v numeric;action text:=p->>'action';begin
 perform 1 from public.business_units where id='10000000-0000-0000-0000-000000000002' for update;
 select * into l from public.lost_jobs where id=(p->>'id')::uuid for update;
 if l.id is null or l.unit_id<>'10000000-0000-0000-0000-000000000002' or not private.has_any(l.unit_id,array['jobs.manage','pr.returns']) then raise exception 'Lost management permission required' using errcode='42501';end if;
 if action='notify' then
  if l.status<>'New' then return jsonb_build_object('ok',true,'status',l.status);end if;
  v:=coalesce(nullif(p->>'market_value','')::numeric,l.market_value);
  if v is null or v<=0 or v<>round(v,2) or v>999999999999.99 then raise exception 'Enter the total market value of the missing items, with at most two decimals';end if;
  recipient:=private.job_customer_recipient(l.job_id);
  if nullif(trim(recipient),'') is null then raise exception 'The Job has no customer email';end if;
  token:=replace(gen_random_uuid()::text||gen_random_uuid()::text,'-','');
  insert into private.lost_resolution_links values(l.id,encode(sha256(convert_to(token,'UTF8')),'hex'),now()+interval '90 days');
  update public.lost_jobs set market_value=v,status='In Process',notified_at=now() where id=l.id;
  insert into public.notifications(unit_id,event,entity_id,recipient,dedupe_key,payload)
  values(l.unit_id,'LOST_RESOLUTION',l.job_id,recipient,'lost-resolution:'||l.id,jsonb_build_object(
   'template','notification','live_eligible',true,'lost_id',l.id,'subject','We are sorry — missing items for '||(select code from public.jobs where id=l.job_id),
   'text','We are very sorry that your items were reported missing while in ToolTag care. We understand how important your tools are and apologize for the inconvenience. The total market value recorded for the missing items is $'||to_char(v,'FM999999999990.00')||'. Please use the secure link to choose replacement of the missing items or a monetary refund at that market value. Our team will review your choice and coordinate the resolution with you.',
   'action_path','/lost/'||token)) on conflict(dedupe_key) do nothing;
 elsif action='approve' then
  if not private.refund_approver() then raise exception 'Only Owner or Manager can approve a Lost resolution' using errcode='42501';end if;
  if l.status<>'In Process' or l.customer_choice is null then raise exception 'Waiting for customer response';end if;
  if l.approved_at is not null then return jsonb_build_object('ok',true,'refund_id',l.refund_id);end if;
  if l.customer_choice='Refund money' then
   insert into public.refund_requests(unit_id,job_id,amount,reason,original_method,method,issue_event,issue_event_at,reported_at,source_kind,source_id,notes)
   values(l.unit_id,l.job_id,l.market_value,'Other',private.refund_original_method(l.job_id),
    case when private.refund_original_method(l.job_id) in ('Zelle','Venmo','Card','Bank Transfer','Check') then private.refund_original_method(l.job_id) end,
    'Return',l.reported_at,l.reported_at,'Lost',l.id,'Lost item compensation at market value. Not limited to service payments. Lost ID: '||l.id)
   on conflict(source_kind,source_id) do update set source_id=excluded.source_id returning id into rid;
  end if;
  update public.lost_jobs set approved_at=now(),approved_by=auth.uid(),refund_id=rid where id=l.id;
 elsif action='finalize' then
  if l.status='History' then return jsonb_build_object('ok',true,'status','History');end if;
  if l.status<>'In Process' or l.approved_at is null then raise exception 'Approve the customer choice before finalizing';end if;
  if nullif(trim(p->>'notes'),'') is null or length(p->>'notes')>5000 then raise exception 'Record the resolution details (up to 5000 characters)';end if;
  if l.customer_choice='Refund money' and not exists(select 1 from public.refund_requests where id=l.refund_id and source_kind='Lost' and source_id=l.id and status='Completed') then raise exception 'Complete the linked Refund, including receipt confirmation, before finalizing Lost';end if;
  update public.lost_jobs set status='History',finalized_at=now(),finalized_by=auth.uid(),resolution_notes=trim(p->>'notes') where id=l.id;
 else raise exception 'Invalid Lost action';end if;
 perform private.rbac_log('lost.'||action,l.id,jsonb_build_object('job_id',l.job_id,'market_value',coalesce(v,l.market_value),'choice',l.customer_choice));
 return jsonb_build_object('ok',true,'refund_id',rid);
end$$;
create function public.lost_staff_action(p jsonb) returns jsonb language sql security invoker set search_path='' as $$select private.lost_staff_action(p)$$;
revoke all on function private.lost_staff_action(jsonb),public.lost_staff_action(jsonb) from public,anon;
grant execute on function private.lost_staff_action(jsonb),public.lost_staff_action(jsonb) to authenticated;

-- Public capability endpoint: only a high-entropy, unexpired token can read/respond.
-- Exposes no driver, staff, phone, email or internal explanation to anonymous users.
create function public.public_lost_resolution(p_token text,p_choice text default null) returns jsonb
language plpgsql security definer set search_path='' as $$
declare l public.lost_jobs;begin
 if p_token is null or p_token !~ '^[a-f0-9]{64}$' then raise exception 'Lost resolution link unavailable';end if;
 select x.* into l from public.lost_jobs x join private.lost_resolution_links t on t.lost_id=x.id
 where t.token_hash=encode(sha256(convert_to(p_token,'UTF8')),'hex') and t.expires_at>now() and x.unit_id='10000000-0000-0000-0000-000000000002' for update of x;
 if l.id is null then raise exception 'Lost resolution link unavailable';end if;
 if p_choice is not null then
  if p_choice not in ('Replace Item','Refund money') then raise exception 'Choose Replace Item or Refund money';end if;
  if l.customer_choice is not null then
   if l.customer_choice<>p_choice then raise exception 'Your choice is already recorded. Contact ToolTag to request a change';end if;
  else
   if l.status<>'In Process' or l.approved_at is not null then raise exception 'This case is no longer accepting choices';end if;
   update public.lost_jobs set customer_choice=p_choice,responded_at=now() where id=l.id returning * into l;
  end if;
 end if;
 return jsonb_build_object('job_code',(select code from public.jobs where id=l.job_id),'market_value',l.market_value,'choice',l.customer_choice,'responded_at',l.responded_at,'status',l.status,'approved',l.approved_at is not null,
 'items',(select coalesce(jsonb_agg(jsonb_build_object('article',i.article,'sequence',i.sequence) order by i.sequence),'[]') from public.job_items i where i.job_id=l.job_id and i.id=any(l.missing_item_ids)));
end$$;
revoke all on function public.public_lost_resolution(text,text) from public;
grant execute on function public.public_lost_resolution(text,text) to anon,authenticated;

create function public.mark_failed_delivery_lost_v2(p_stop uuid,p_checked uuid[],p_explanation text,p_market_value numeric) returns uuid
language plpgsql security definer set search_path='' as $$declare lid uuid;begin
 if p_market_value is null or p_market_value<=0 or p_market_value<>round(p_market_value,2) or p_market_value>999999999999.99 then raise exception 'Enter the missing items market value with at most two decimals';end if;
 lid:=public.mark_failed_delivery_lost(p_stop,p_checked,p_explanation);
 -- Repeated reports never overwrite an existing value or a notified snapshot.
 update public.lost_jobs set market_value=p_market_value where lost_jobs.id=lid and status='New' and market_value is null;
 return lid;
end$$;
revoke all on function public.mark_failed_delivery_lost_v2(uuid,uuid[],text,numeric) from public,anon;
grant execute on function public.mark_failed_delivery_lost_v2(uuid,uuid[],text,numeric) to authenticated;

-- Extend existing, scoped list; do not grant write access to the table.
do $$declare d text;begin
 d:=pg_get_functiondef('public.lost_job_list()'::regprocedure);
 if position('''id'',l.id' in d)=0 then raise exception 'Unexpected Lost list definition';end if;
 d:=replace(d,'''id'',l.id','''status'',l.status,''market_value'',l.market_value,''customer_choice'',l.customer_choice,''responded_at'',l.responded_at,''notified_at'',l.notified_at,''approved_at'',l.approved_at,''refund_id'',l.refund_id,''refund_status'',(select status from public.refund_requests where id=l.refund_id),''finalized_at'',l.finalized_at,''resolution_notes'',l.resolution_notes,''id'',l.id');
 execute d;
end$$;

-- Lost compensation is an expense, not a reversal of a customer's service payment.
insert into public.categories(unit_id,name,kind)
select '10000000-0000-0000-0000-000000000002','Lost Item Compensation','expense'
where not exists(select 1 from public.categories where unit_id='10000000-0000-0000-0000-000000000002' and name='Lost Item Compensation' and kind='expense');
do $$declare d text;signature text;start_at integer;end_at integer;begin
 -- Lost obligations must not consume ordinary service-refund reservations.
 foreach signature in array array['public.create_refund_request(jsonb)','public.refund_job_choices()','public.refund_request_action_before_lifecycle(jsonb)'] loop
  d:=pg_get_functiondef(signature::regprocedure);
  d:=replace(d,'from public.refund_requests where job_id=j.id and status','from public.refund_requests where source_kind<>''Lost'' and job_id=j.id and status');
  d:=replace(d,'from public.refund_requests r where r.job_id=j.id and r.status','from public.refund_requests r where r.source_kind<>''Lost'' and r.job_id=j.id and r.status');
  if signature='public.refund_request_action_before_lifecycle(jsonb)' then
   start_at:=position(' remaining:=r.amount-r.processed_amount;' in d);
   end_at:=position(' snap:=jsonb_build_object(' in d);
   if start_at=0 or end_at<=start_at then raise exception 'Unexpected refund issuance definition';end if;
   d:=substring(d,1,start_at-1)||$special$
 if r.source_kind='Lost' then
  if not exists(select 1 from public.lost_jobs l where l.id=r.source_id and l.refund_id=r.id and l.unit_id=r.unit_id and l.job_id=j.id and l.customer_choice='Refund money' and l.approved_at is not null and l.market_value=r.amount) then raise exception 'Invalid Lost compensation snapshot';end if;
  remaining:=r.amount-r.processed_amount;
  if remaining<=0 then raise exception 'Compensation already issued';end if;
  insert into public.transactions(unit_id,account_id,type,transaction_date,amount,category_id,customer_id,description,payment_method,reference,created_by)
  values(r.unit_id,v_account,'EXPENSE',(now() at time zone 'America/Denver')::date,remaining,
   (select id from public.categories where unit_id=r.unit_id and name='Lost Item Compensation' and kind='expense' limit 1),
   (select customer_id from public.commercial_flows where id=j.flow_id),'Lost item compensation · '||j.code,v_method,v_reference,auth.uid()) returning id into tid;
  insert into public.expenses(transaction_id,unit_id,paid_by) values(tid,r.unit_id,'Business');
  ids:=array_append(ids,tid);
 else
$special$||substring(d,start_at,end_at-start_at)||E'\n end if;\n'||substring(d,end_at);
  end if;
  execute d;
 end loop;
end$$;

-- Include Lost SMS in the existing consent-gated queue, accounting and mode checks.
do $$declare d text;begin
 d:=pg_get_functiondef('private.enqueue_sms()'::regprocedure);
 if position('''SHOP_PICKUP''' in d)=0 then raise exception 'Unexpected SMS event allowlist';end if;
 d:=replace(d,'''SHOP_PICKUP''','''SHOP_PICKUP'',''LOST_RESOLUTION''');execute d;
end$$;
alter function public.sms_message_context(uuid) rename to sms_message_context_before_lost;
revoke all on function public.sms_message_context_before_lost(uuid) from public,anon,authenticated,service_role;
create function public.sms_message_context(p_notification uuid) returns jsonb language plpgsql security definer set search_path='' as $$declare n public.notifications;j public.jobs;begin
 if coalesce(auth.role(),'')<>'service_role' then raise exception 'Worker credentials required';end if;
 select x.* into n from public.notifications x join private.sms_deliveries d on d.notification_id=x.id where x.id=p_notification and x.unit_id='10000000-0000-0000-0000-000000000002';
 if n.event='LOST_RESOLUTION' then
  select * into j from public.jobs where id=n.entity_id and unit_id=n.unit_id;
  if j.id is null then return null;end if;
  return jsonb_build_object('job_code',j.code,'action_path',n.payload->>'action_path');
 end if;
 return public.sms_message_context_before_lost(p_notification);
end$$;
revoke all on function public.sms_message_context(uuid) from public,anon,authenticated;
grant execute on function public.sms_message_context(uuid) to service_role;
-- Closed Lost resolutions no longer contribute urgent red counters.
do $$declare d text;begin
 d:=pg_get_functiondef('public.urgent_login_attention()'::regprocedure);
 if position('where j.unit_id=u and j.is_lost and' in d)>0 then d:=replace(d,'where j.unit_id=u and j.is_lost and','where j.unit_id=u and j.is_lost and l.status<>''History'' and');execute d;end if;
end$$;
notify pgrst,'reload schema';
commit;
