
create or replace function public.public_submit_payment_request(
  p_token text,
  p_request uuid,
  p_method text,
  p_proof_path text default null
) returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  j public.jobs;
  due numeric(14,2);
  existing public.payment_requests;
  rid uuid;
  zelle text;
  venmo text;
begin
  select x.* into j
  from public.jobs x
  join private.public_links l on l.job_id=x.id
  where l.token_hash=encode(sha256(convert_to(p_token,'UTF8')),'hex')
    and l.expires_at>now()
  for update of x;

  if j.id is null then raise exception 'Invalid or expired link'; end if;

  if not exists(select 1 from public.delivery_acknowledgments where job_id=j.id) then
    raise exception 'Confirm delivery before choosing payment';
  end if;

  select * into existing
  from public.payment_requests
  where request_key=p_request;

  if existing.id is not null then
    return jsonb_build_object(
      'id',existing.id,
      'status',existing.status,
      'method',existing.method,
      'amount',existing.amount
    );
  end if;

  if exists(
    select 1
    from public.payment_requests
    where job_id=j.id and status='Pending Verification'
  ) then
    raise exception 'A payment is already awaiting verification';
  end if;

  select balance_due into due
  from public.job_commercial_totals
  where id=j.id;

  if coalesce(due,0)<=0 then
    raise exception 'This job is already paid in full';
  end if;

  if p_method not in ('Cash','Zelle','Venmo') then
    raise exception 'Choose Cash, Zelle or Venmo';
  end if;

  select zelle_email,venmo_handle
  into zelle,venmo
  from public.unit_settings
  where unit_id=j.unit_id;

  if p_method='Zelle' and nullif(trim(zelle),'') is null then
    raise exception 'Zelle is not configured yet';
  end if;

  if p_method='Venmo' and nullif(trim(venmo),'') is null then
    raise exception 'Venmo is not configured yet';
  end if;

  if p_method in ('Zelle','Venmo') then
    if nullif(trim(p_proof_path),'') is null then
      raise exception 'Upload payment proof for Zelle or Venmo';
    end if;

    if p_proof_path not like j.unit_id::text||'/%'
       or not exists(
         select 1
         from storage.objects o
         where o.bucket_id='payment-proofs'
           and o.name=p_proof_path
       )
    then
      raise exception 'Payment proof was not found';
    end if;
  end if;

  insert into public.payment_requests(
    request_key,unit_id,job_id,method,amount,proof_path
  )
  values(p_request,j.unit_id,j.id,p_method,due,p_proof_path)
  returning id into rid;

  insert into public.notifications(
    unit_id,event,entity_id,recipient,dedupe_key,payload
  )
  values(
    j.unit_id,
    'PAYMENT_SUBMITTED',
    rid,
    'payments@tooltag.martinlab.studio',
    'payment-request:'||rid,
    jsonb_build_object(
      'template','notification',
      'subject','Pago hecho — '||j.code||' — '||p_method,
      'text',
        'Job: '||j.code
        ||E'\nAmount: $'||to_char(due,'FM999999990.00')
        ||E'\nPayment method: '||p_method
        ||E'\nStatus: Pending Verification'
        ||case
            when p_method in ('Zelle','Venmo') then E'\nPayment proof: Uploaded'
            else ''
          end,
      'live_eligible',true
    )
  )
  on conflict do nothing;

  return jsonb_build_object(
    'id',rid,
    'status','Pending Verification',
    'method',p_method,
    'amount',due
  );
end $$;

revoke all on function public.public_submit_payment_request(text,uuid,text,text) from public;
grant execute on function public.public_submit_payment_request(text,uuid,text,text)
to anon,authenticated;
