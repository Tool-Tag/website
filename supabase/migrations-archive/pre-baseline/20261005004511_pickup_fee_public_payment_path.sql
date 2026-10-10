
create or replace function private.create_pick_return_order_from_agreement()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
declare
  fee numeric(14,2);
  token text;
  recipient text;
begin
  select sum(quantity*unit_price)
  into fee
  from public.quote_items
  where quote_id=new.quote_id
    and pricing->>'kind'='pickup_service_fee';

  if coalesce(fee,0)<=0 then
    return new;
  end if;

  insert into public.pick_return_orders(
    job_id,unit_id,fee_amount,fee_status,scheduler_enabled,
    terms_version,terms_snapshot
  )
  values(
    new.job_id,new.unit_id,fee,'Required',false,
    coalesce(new.commercial_snapshot->'policy'->>'version','2.0'),
    new.content_snapshot
  )
  on conflict(job_id) do nothing;

  select l.token into token
  from private.pickup_payment_links l
  where l.job_id=new.job_id and l.expires_at>now();

  if token is null then
    token:=gen_random_uuid()::text||gen_random_uuid()::text;
    insert into private.pickup_payment_links(job_id,token,token_hash,expires_at)
    values(
      new.job_id,
      token,
      encode(sha256(convert_to(token,'UTF8')),'hex'),
      now()+interval '90 days'
    )
    on conflict(job_id) do update
      set token=excluded.token,
          token_hash=excluded.token_hash,
          expires_at=excluded.expires_at,
          created_at=now();
  end if;

  recipient:=coalesce(new.accepted_email,private.job_customer_recipient(new.job_id));

  insert into public.notifications(
    unit_id,event,entity_id,recipient,dedupe_key,payload
  )
  values(
    new.unit_id,
    'PICKUP_FEE_REQUIRED',
    new.job_id,
    recipient,
    'pickup-fee-required:'||new.job_id,
    jsonb_build_object(
      'template','notification',
      'subject','Pickup fee required — '||(
        select code from public.jobs where id=new.job_id
      ),
      'text','Your $'||to_char(fee,'FM999999990.00')||
             ' Pickup & Return fee must be paid and confirmed before Pickup can be scheduled.',
      'action_path','/pickup/'||token||'/payment',
      'live_eligible',true
    )
  )
  on conflict do nothing;

  return new;
end $$;
