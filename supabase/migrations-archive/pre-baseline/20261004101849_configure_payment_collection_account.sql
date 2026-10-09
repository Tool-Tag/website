
alter table public.unit_settings
  add column if not exists payment_account_id uuid;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname='unit_settings_payment_account_fkey'
      and conrelid='public.unit_settings'::regclass
  ) then
    alter table public.unit_settings
      add constraint unit_settings_payment_account_fkey
      foreign key(payment_account_id,unit_id)
      references public.accounts(id,unit_id);
  end if;
end $$;

update public.unit_settings u
set payment_account_id=a.id
from public.accounts a
where u.unit_id=a.unit_id
  and a.name='ToolTag Operating Account'
  and a.active=true
  and u.payment_account_id is null;

create or replace function public.confirm_payment_request(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  r public.payment_requests;
  j public.jobs;
  remaining numeric(14,2);
  due numeric(14,2);
  alloc numeric(14,2);
  paid numeric(14,2):=0;
  rec record;
  tid uuid;
  tids uuid[]:='{}';
  collection_account uuid;
begin
  select * into r
  from public.payment_requests
  where id=p_id
  for update;

  if r.id is null then
    raise exception 'Payment request not found';
  end if;

  perform private.require_admin(r.unit_id);

  if r.status='Confirmed' then
    return jsonb_build_object(
      'id',r.id,
      'status',r.status,
      'confirmed_amount',r.confirmed_amount,
      'transaction_ids',r.transaction_ids
    );
  end if;

  if r.status<>'Pending Verification' then
    raise exception 'Payment request is not pending verification';
  end if;

  select payment_account_id
  into collection_account
  from public.unit_settings
  where unit_id=r.unit_id;

  if collection_account is null then
    raise exception 'Payment account is not configured';
  end if;

  select * into j
  from public.jobs
  where id=r.job_id
  for update;

  select balance_due into due
  from public.job_commercial_totals
  where id=j.id;

  if coalesce(due,0)<=0 then
    raise exception 'This job is already paid in full';
  end if;

  remaining:=least(r.amount,due);

  for rec in
    select *
    from (
      select 0 as sort_order,s.transaction_id,s.balance_due,s.customer_id
      from public.sale_balances s
      where s.job_id=j.id
        and s.transaction_status<>'Voided'
        and s.balance_due>0

      union all

      select x.sequence as sort_order,s.transaction_id,s.balance_due,s.customer_id
      from public.job_extensions x
      join public.sale_balances s on s.transaction_id=x.sale_id
      where x.job_id=j.id
        and x.status in ('Approved','Completed')
        and s.transaction_status<>'Voided'
        and s.balance_due>0
    ) q
    order by sort_order,transaction_id
  loop
    exit when remaining<=0;

    alloc:=least(remaining,rec.balance_due);

    insert into public.transactions(
      unit_id,
      account_id,
      type,
      transaction_date,
      amount,
      customer_id,
      description,
      payment_method,
      reference,
      created_by
    )
    values(
      r.unit_id,
      collection_account,
      'COLLECTION',
      (now() at time zone (
        select timezone
        from public.unit_settings
        where unit_id=r.unit_id
      ))::date,
      alloc,
      rec.customer_id,
      'Verified customer payment · '||j.code,
      r.method,
      'PAYREQ:'||r.id,
      auth.uid()
    )
    returning id into tid;

    insert into public.collections(transaction_id,unit_id,sale_id)
    values(tid,r.unit_id,rec.transaction_id);

    tids:=array_append(tids,tid);
    paid:=paid+alloc;
    remaining:=remaining-alloc;
  end loop;

  if paid<=0 then
    raise exception 'No outstanding sale balance was available';
  end if;

  update public.payment_requests
  set status='Confirmed',
      confirmed_at=now(),
      confirmed_by=auth.uid(),
      confirmed_amount=paid,
      transaction_ids=tids
  where id=r.id
  returning * into r;

  perform public.generate_job_receipt(j.id);

  return jsonb_build_object(
    'id',r.id,
    'status',r.status,
    'confirmed_amount',r.confirmed_amount,
    'transaction_ids',r.transaction_ids
  );
end $$;

revoke all on function public.confirm_payment_request(uuid) from public,anon;
grant execute on function public.confirm_payment_request(uuid) to authenticated;
