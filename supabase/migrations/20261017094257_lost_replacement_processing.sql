begin;
alter table public.lost_jobs add column replacement_at_shop_at timestamptz,
 add column replacement_at_shop_by uuid references auth.users(id),
 add column replacement_expense_id uuid unique references public.transactions(id);
-- Extend only the guarded workflow introduced in the preceding migration.
do $$declare d text;begin
 d:=pg_get_functiondef('private.lost_staff_action(jsonb)'::regprocedure);
 if position('  update public.lost_jobs set approved_at=' in d)=0 or position(' elsif action=''finalize'' then' in d)=0 then raise exception 'Unexpected Lost action definition';end if;
 d:=replace(d,'  update public.lost_jobs set approved_at=', $notify$
  insert into public.notifications(unit_id,event,entity_id,recipient,dedupe_key,payload)
  values(l.unit_id,case when l.customer_choice='Replace Item' then 'LOST_REPLACEMENT_APPROVED' else 'LOST_REFUND_APPROVED' end,l.job_id,private.job_customer_recipient(l.job_id),'lost-approved:'||l.id,
   jsonb_build_object('template','notification','live_eligible',true,'lost_id',l.id,'subject','We are working on your Lost resolution',
    'text',case when l.customer_choice='Replace Item' then 'We are now working on replacing your missing items.' else 'We are now working on your market-value refund.' end||' Please allow 5–7 business days for processing. Thank you for your patience while we make this right.',
    'action_path','/status/'||private.ensure_job_status_link(l.job_id))) on conflict(dedupe_key) do nothing;
  update public.lost_jobs set approved_at=$notify$);
 d:=replace(d,' elsif action=''finalize'' then', $confirm$
 elsif action='confirm-replacement' then
  if l.status<>'In Process' or l.approved_at is null or l.customer_choice<>'Replace Item' then raise exception 'Approve the replacement before confirming shop arrival';end if;
  update public.lost_jobs set replacement_at_shop_at=coalesce(replacement_at_shop_at,now()),replacement_at_shop_by=coalesce(replacement_at_shop_by,auth.uid()) where id=l.id;
 elsif action='finalize' then
  if l.customer_choice='Replace Item' and (l.replacement_at_shop_at is null or not exists(select 1 from public.transactions t join public.expenses e on e.transaction_id=t.id where t.id=l.replacement_expense_id and t.unit_id=l.unit_id and t.type='EXPENSE' and t.status='Active')) then raise exception 'Confirm replacement at shop and record its Finance expense before finalizing';end if;
$confirm$);
 execute d;
 d:=pg_get_functiondef('public.lost_job_list()'::regprocedure);
 if position('''status'',l.status' in d)=0 then raise exception 'Unexpected Lost list definition';end if;
 d:=replace(d,'''status'',l.status','''replacement_at_shop_at'',l.replacement_at_shop_at,''replacement_expense_id'',l.replacement_expense_id,''status'',l.status');execute d;
 d:=pg_get_functiondef('private.enqueue_sms()'::regprocedure);
 if position('''LOST_RESOLUTION''' in d)=0 then raise exception 'Unexpected SMS allowlist';end if;
 d:=replace(d,'''LOST_RESOLUTION''','''LOST_RESOLUTION'',''LOST_REPLACEMENT_APPROVED'',''LOST_REFUND_APPROVED''');execute d;
end$$;

-- Same Finance recorder and permissions; the Lost link and shop gate are atomic.
create function private.record_lost_replacement_expense(p jsonb) returns uuid
language plpgsql security definer set search_path='' as $$
declare l public.lost_jobs;tid uuid;payload jsonb;begin
 perform 1 from public.business_units where id='10000000-0000-0000-0000-000000000002' for update;
 select * into l from public.lost_jobs where id=(p->>'lost_id')::uuid for update;
 if l.id is null or l.unit_id<>'10000000-0000-0000-0000-000000000002' or not private.is_owner(l.unit_id) then raise exception 'Finance expense recording requires Owner access' using errcode='42501';end if;
 if l.status<>'In Process' or l.approved_at is null or l.customer_choice<>'Replace Item' or l.replacement_at_shop_at is null then raise exception 'Confirm the approved replacement is at the shop first';end if;
 payload:=(p-'lost_id')||jsonb_build_object('unit_id',l.unit_id,'type','EXPENSE','request_id',l.id,'customer_id',(select customer_id from public.commercial_flows f join public.jobs j on j.flow_id=f.id where j.id=l.job_id));
 tid:=public.record_movement(payload);
 if not exists(select 1 from public.transactions t join public.expenses e on e.transaction_id=t.id where t.id=tid and t.unit_id=l.unit_id and t.type='EXPENSE' and t.status='Active') then raise exception 'Invalid replacement expense';end if;
 if l.replacement_expense_id is not null and l.replacement_expense_id<>tid then raise exception 'A replacement expense is already linked';end if;
 update public.lost_jobs set replacement_expense_id=tid where id=l.id;
 perform private.rbac_log('lost.replacement.expense',l.id,jsonb_build_object('transaction_id',tid));
 return tid;
end$$;
create function public.record_lost_replacement_expense(p jsonb) returns uuid language sql security invoker set search_path='' as $$select private.record_lost_replacement_expense(p)$$;
revoke all on function private.record_lost_replacement_expense(jsonb),public.record_lost_replacement_expense(jsonb) from public,anon;
grant execute on function private.record_lost_replacement_expense(jsonb),public.record_lost_replacement_expense(jsonb) to authenticated;
notify pgrst,'reload schema';
commit;
