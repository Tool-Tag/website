-- Restricted worker lookup and isolated TEST collections; no broad table grants.
create table private.stripe_test_settings (
 unit_id uuid primary key references public.business_units(id),
 account_id uuid not null references public.accounts(id)
);
alter table private.stripe_test_settings enable row level security;
revoke all on private.stripe_test_settings from public,anon,authenticated;
create function public.stripe_test_customer(p_job uuid) returns boolean
language plpgsql security definer set search_path='' as $$
begin
 if coalesce(auth.role(),'')<>'service_role' then raise exception 'Worker credentials required';end if;
 return exists(select 1 from public.jobs j join public.commercial_flows f on f.id=j.flow_id join public.customers c on c.id=f.customer_id where j.id=p_job and j.unit_id='10000000-0000-0000-0000-000000000002' and c.name like 'TEST-%');
end $$;
revoke all on function public.stripe_test_customer(uuid) from public,anon,authenticated;
grant execute on function public.stripe_test_customer(uuid) to service_role;
create function private.stripe_payment_account(p_unit uuid,p_job uuid,p_reference text) returns uuid
language plpgsql security definer set search_path='' as $$
declare account uuid;
begin
 if left(p_reference,8)='cs_test_' then
  if not public.stripe_test_customer(p_job) then raise exception 'Stripe TEST payments require a TEST- customer';end if;
  select a.id into account from private.stripe_test_settings s join public.accounts a on a.id=s.account_id join public.physical_accounts p on p.id=a.physical_account_id
  where s.unit_id=p_unit and a.unit_id=p_unit and a.active and a.name like 'TEST-%' and p.name like 'TEST-%';
  if account is null then raise exception 'Stripe TEST sandbox account is not configured';end if;
 else
  select payment_account_id into account from public.unit_settings where unit_id=p_unit;
 end if;
 return account;
end $$;
revoke all on function private.stripe_payment_account(uuid,uuid,text) from public;
CREATE OR REPLACE FUNCTION public.confirm_logistics_card_payment(p_attempt uuid, p_provider_reference text, p_amount numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  role_name text;
  attempt public.logistics_payment_attempts;
  j public.jobs;
  request_id uuid;
  purpose_value text;
  collection_account uuid;
  due numeric(14,2);
  remaining numeric(14,2);
  alloc numeric(14,2);
  paid numeric(14,2):=0;
  rec record;
  tid uuid;
  tids uuid[]:='{}';
begin
  role_name:=coalesce(
    nullif(current_setting('request.jwt.claims',true),'')::jsonb->>'role',
    current_setting('request.jwt.claim.role',true),
    ''
  );
  if role_name<>'service_role' then
    raise exception 'Server credentials required' using errcode='42501';
  end if;

  select * into attempt
  from public.logistics_payment_attempts
  where id=p_attempt
  for update;

  if attempt.id is null or attempt.provider<>'stripe' then
    raise exception 'Card payment attempt unavailable';
  end if;

  if attempt.status='paid_confirmed' then
    return jsonb_build_object(
      'status','paid_confirmed',
      'attempt_id',attempt.id,
      'payment_request_id',attempt.payment_request_id
    );
  end if;

  if attempt.status<>'pending'
     or attempt.provider_reference is distinct from p_provider_reference
     or round(attempt.amount,2)<>round(p_amount,2)
  then
    raise exception 'Card payment confirmation does not match the pending attempt';
  end if;

  select * into j from public.jobs where id=attempt.job_id for update;
  collection_account:=private.stripe_payment_account(attempt.unit_id,attempt.job_id,p_provider_reference);

  if collection_account is null then
    raise exception 'Payment account is not configured';
  end if;

  select balance_due into due
  from public.job_commercial_totals where id=j.id;

  if coalesce(due,0)<=0 then
    raise exception 'This Job is already paid in full';
  end if;

  purpose_value:=case
    when attempt.payment_scope='full' then 'Logistics Full Prepayment'
    else 'Logistics Fee'
  end;

  insert into public.payment_requests(
    request_key,unit_id,job_id,method,amount,status,purpose,
    provider,provider_reference,payment_scope
  )
  values(
    attempt.id,attempt.unit_id,attempt.job_id,'Card',attempt.amount,
    'Pending Verification',purpose_value,'stripe',p_provider_reference,
    attempt.payment_scope
  )
  returning id into request_id;

  remaining:=least(attempt.amount,due);

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
    ) x
    order by sort_order,transaction_id
  loop
    exit when remaining<=0;
    alloc:=least(remaining,rec.balance_due);

    insert into public.transactions(
      unit_id,account_id,type,transaction_date,amount,customer_id,
      description,payment_method,reference,created_by
    )
    values(
      attempt.unit_id,
      collection_account,
      'COLLECTION',
      (now() at time zone (
        select timezone from public.unit_settings where unit_id=attempt.unit_id
      ))::date,
      alloc,
      rec.customer_id,
      case
        when attempt.payment_scope='full'
        then 'Verified full prepayment · '||j.code
        else 'Verified logistics fee · '||j.code
      end,
      'Card',
      'STRIPE:'||p_provider_reference,
      null
    )
    returning id into tid;

    insert into public.collections(transaction_id,unit_id,sale_id)
    values(tid,attempt.unit_id,rec.transaction_id);

    tids:=array_append(tids,tid);
    paid:=paid+alloc;
    remaining:=remaining-alloc;
  end loop;

  if paid<=0 then raise exception 'No outstanding sale balance was available'; end if;

  update public.payment_requests
  set status='Confirmed',
      confirmed_at=now(),
      confirmed_amount=paid,
      transaction_ids=tids
  where id=request_id;

  update public.logistics_payment_attempts
  set status='paid_confirmed',
      confirmed_at=now(),
      payment_request_id=request_id
  where id=attempt.id;

  return jsonb_build_object(
    'status','paid_confirmed',
    'attempt_id',attempt.id,
    'payment_request_id',request_id,
    'confirmed_amount',paid
  );
end $function$
