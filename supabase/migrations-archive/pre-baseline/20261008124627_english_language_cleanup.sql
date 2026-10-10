
create or replace function private.priced_scope(p_items jsonb)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  result jsonb:='[]';
  item_json jsonb;
  mark_json jsonb;
  qty integer;
  cnt integer;
  extra numeric;
  paint numeric;
  base numeric;
  idx integer:=0;
  logos integer;
begin
  if jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)=0 then
    raise exception 'Add at least one item';
  end if;

  for item_json in select value from jsonb_array_elements(p_items) loop
    qty:=(item_json->>'quantity')::integer;
    base:=(item_json->>'unit_price')::numeric;

    if qty is null or qty<1 or qty>10000 or base is null or base<0 or base<>round(base,2)
       or nullif(trim(item_json->>'article'),'') is null then
      raise exception 'Invalid quantity, article or base price';
    end if;

    if coalesce(item_json->>'engraving_type','') not in ('Fee','Text','Image / Logo') then
      raise exception 'Invalid engraving type';
    end if;

    cnt:=case
      when item_json->>'engraving_type'='Fee' then 0
      else jsonb_array_length(coalesce(item_json->'marks','[]'))
    end;

    if item_json->>'engraving_type'<>'Fee' and cnt<1 then
      raise exception 'Add engraving details';
    end if;

    paint:=0;

    for mark_json in
      select value from jsonb_array_elements(coalesce(item_json->'marks','[]'))
    loop
      if item_json->>'engraving_type'='Fee' then exit; end if;

      if nullif(trim(mark_json->>'location'),'') is null
         or coalesce(mark_json->>'type','') not in ('Text','Image / Logo') then
        raise exception 'Engraving location and type required';
      end if;

      if mark_json->>'type'='Text' and nullif(trim(mark_json->>'text'),'') is null then
        raise exception 'Engraving text required';
      end if;

      if mark_json->>'type'='Image / Logo' and coalesce(mark_json->>'url','') !~ '^https?://' then
        raise exception 'Image link required';
      end if;

      if coalesce((mark_json->>'paint_fill')::boolean,false) then
        if coalesce(mark_json->'paint_details'->>'mode','') not in ('single','multiple')
           or (mark_json->'paint_details'->>'mode'='single'
               and nullif(trim(mark_json->'paint_details'->>'color'),'') is null)
           or (mark_json->'paint_details'->>'mode'='multiple'
               and nullif(trim(mark_json->'paint_details'->>'instructions'),'') is null) then
          raise exception 'Paint instructions required';
        end if;
        paint:=2;
      end if;
    end loop;

    extra:=greatest(cnt-1,0)*5;

    result:=result||jsonb_build_array(
      item_json||jsonb_build_object(
        'unit_price',base,
        'sort_order',idx,
        'adaptation_fee',false,
        'paint_fee',false,
        'additional_engraving_fee',false,
        'pricing',jsonb_build_object(
          'version',1,
          'engraving_count',cnt,
          'base_unit_price',base,
          'additional_engraving_unit_charge',extra,
          'additional_engraving_charge',extra*qty,
          'paint_unit_charge',paint,
          'paint_charge',paint*qty,
          'line_total',qty*(base+extra+paint)
        )
      )
    );
    idx:=idx+1;

    if extra>0 then
      result:=result||jsonb_build_array(
        jsonb_build_object(
          'article','Additional engravings · '||(item_json->>'article'),
          'quantity',qty*greatest(cnt-1,0),
          'unit_price',5,
          'engraving_type','Fee',
          'notes','First engraving included; $5 per additional engraving per item.',
          'sort_order',idx,
          'additional_engraving_fee',true
        )
      );
      idx:=idx+1;
    end if;

    if paint>0 then
      result:=result||jsonb_build_array(
        jsonb_build_object(
          'article','Paint fill · '||(item_json->>'article'),
          'quantity',qty,
          'unit_price',2,
          'engraving_type','Fee',
          'notes','$2 per painted item, regardless of the number of paint-filled engravings.',
          'sort_order',idx,
          'paint_fee',true
        )
      );
      idx:=idx+1;
    end if;
  end loop;

  select count(distinct trim(mark_elem->>'url'))
  into logos
  from jsonb_array_elements(p_items) as item_elem
  cross join lateral jsonb_array_elements(coalesce(item_elem->'marks','[]')) as mark_elem
  where item_elem->>'engraving_type'<>'Fee'
    and mark_elem->>'type'='Image / Logo';

  if logos>0 then
    result:=result||jsonb_build_array(
      jsonb_build_object(
        'article','Falcon image / logo adaptation',
        'quantity',logos,
        'unit_price',3,
        'engraving_type','Fee',
        'notes','$3 per unique design.',
        'adaptation_fee',true,
        'sort_order',idx
      )
    );
  end if;

  return result;
end
$function$;

create or replace function public.public_submit_payment_request(
  p_token text,
  p_request uuid,
  p_method text,
  p_proof_path text default null::text
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
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
      'subject','Payment Submitted — '||j.code||' — '||p_method,
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
end
$function$;

create or replace function public.resend_quote(p_id uuid)
returns text
language plpgsql
security definer
set search_path to ''
as $function$
declare q public.quotes; previous public.notifications; destination text; token text; wait_seconds integer;
begin
 select * into q from public.quotes where id=p_id for update;
 if q.id is null then raise exception 'Quote not found'; end if;
 perform private.require_admin(q.unit_id);
 if q.status not in ('Sent','Viewed') or q.expires_at is null or q.expires_at<=now() then
  raise exception 'Only a sent, active Quote can be resent. Create a revision if it expired or was accepted';
 end if;
 select * into previous from public.notifications where entity_id=q.id and event='Quote Sent' order by created_at desc,id desc limit 1 for update;
 if previous.id is null then raise exception 'Send the Quote first'; end if;
 wait_seconds:=ceil(extract(epoch from (greatest(previous.created_at,previous.mail_attempted_at,(previous.payload->>'resend_requested_at')::timestamptz)+interval '90 seconds'-clock_timestamp())));
 if wait_seconds>0 then raise exception 'Wait % seconds before resending the Quote',wait_seconds; end if;
 if coalesce(previous.payload->>'test','false')='true' then raise exception 'Test notifications cannot be resent from this action'; end if;
 if previous.status not in ('Sent','Pending Integration') or (previous.status='Pending Integration' and previous.mail_claim is not null) or exists(select 1 from public.notifications where entity_id=q.id and event='Quote Sent' and id<>previous.id and status in ('Queued','Pending Integration')) then
  raise exception 'The previous send requires review before resending to avoid duplicates';
 end if;
 select d.recipient,d.token into destination,token from private.quote_delivery d where d.quote_id=q.id;
 if nullif(destination,'') is null or token is null or q.review_snapshot is null then raise exception 'Original send data is incomplete'; end if;
 if previous.status='Pending Integration' then
  update public.notifications set recipient=destination,payload=payload||jsonb_build_object('resend_requested_at',clock_timestamp(),'resend',true,'live_eligible',true) where id=previous.id;
 else
  insert into public.notifications(unit_id,event,entity_id,dedupe_key,recipient,payload)
  values(q.unit_id,'Quote Sent',q.id,'quote-resend:'||q.id||':'||gen_random_uuid(),destination,
   jsonb_build_object('template','quote','snapshot',q.review_snapshot,'live_eligible',true,'resend',true,'resend_requested_at',clock_timestamp(),'previous_notification_id',previous.id));
 end if;
 insert into public.audit_log(unit_id,actor_id,entity,entity_id,field,new_value)
 values(q.unit_id,auth.uid(),'quotes',q.id,'quote_resend_requested',jsonb_build_object('recipient',destination,'requested_at',now(),'previous_notification_id',previous.id));
 return token;
end
$function$;

create or replace function public.send_quote_to(p_id uuid, p_recipient text, p_regenerate boolean default false)
returns text
language plpgsql
security definer
set search_path to ''
as $function$
declare q public.quotes; c public.customers; destination text:=trim(p_recipient); token text; snap jsonb; prior text;
begin
 select * into q from public.quotes where id=p_id for update;
 perform private.require_admin(q.unit_id);
 select x.* into c from public.customers x join public.commercial_flows f on f.customer_id=x.id where f.id=q.flow_id and x.unit_id=q.unit_id;
 select d.recipient into prior from private.quote_delivery d where d.quote_id=p_id;
 if nullif(destination,'') is null or destination !~* '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$' or
 not (lower(destination)=lower(coalesce(prior,'')) or lower(destination)=lower(coalesce(trim(c.email),'')) or lower(destination)=lower(coalesce(trim(c.company_email),''))) then
   raise exception 'Select the registered personal or company email for this customer';
 end if;
 perform 1 from public.notifications where entity_id=q.id and event in ('Quote Sent','Quote expiration reminder') order by id for update;
 if exists(select 1 from public.notifications where entity_id=q.id and event in ('Quote Sent','Quote expiration reminder') and status='Queued') then
   raise exception 'A send is already in progress. Wait before changing the recipient';
 end if;
 select d.recipient into prior from private.quote_delivery d where d.quote_id=p_id;
 if prior is not null and lower(prior)<>lower(destination) then raise exception 'The recipient for this revision is locked. Create a revision to change it'; end if;
 token:=private.send_review(p_id,p_regenerate);
 select recipient into prior from private.quote_delivery where quote_id=p_id;
 update private.quote_delivery set recipient=destination where quote_id=p_id;
 update public.notifications set recipient=destination where entity_id=p_id and event in ('Quote Sent','Quote expiration reminder') and status='Pending Integration';
 select review_snapshot into snap from public.quotes where id=p_id;
 if exists(select 1 from public.notifications where entity_id=p_id and event='Quote Sent' and status='Sent') and
 not exists(select 1 from public.notifications where entity_id=p_id and event='Quote Sent' and lower(recipient)=lower(destination) and status in ('Sent','Queued','Pending Integration')) then
   insert into public.notifications(unit_id,event,entity_id,dedupe_key,recipient,payload)
   values(q.unit_id,'Quote Sent',q.id,'quote:'||q.id||':recipient:'||encode(sha256(convert_to(lower(destination),'UTF8')),'hex'),destination,jsonb_build_object('template','quote','snapshot',snap)) on conflict do nothing;
 end if;
 if prior is distinct from destination then
   insert into public.audit_log(unit_id,actor_id,entity,entity_id,field,old_value,new_value)
   values(q.unit_id,auth.uid(),'quotes',q.id,'mail_recipient',to_jsonb(prior),to_jsonb(destination));
 end if;
 return token;
end
$function$;

update public.quote_items i
set article = case
  when i.article like 'Grabados adicionales · %' then regexp_replace(i.article,'^Grabados adicionales · ','Additional engravings · ')
  when i.article like 'Pintura · %' then regexp_replace(i.article,'^Pintura · ','Paint fill · ')
  when i.article='Adaptación de imagen / logo para Falcon' then 'Falcon image / logo adaptation'
  else i.article
end,
notes = case
  when i.notes='Primer grabado incluido; $5 por grabado adicional y pieza.' then 'First engraving included; $5 per additional engraving per item.'
  when i.notes='$2 por pieza coloreada, independientemente del número de grabados con pintura.' then '$2 per painted item, regardless of the number of paint-filled engravings.'
  when i.notes='$3 por diseño diferente.' then '$3 per unique design.'
  else i.notes
end
from public.quotes q
where i.quote_id=q.id
  and q.status='Draft'
  and q.sent_at is null
  and (
    i.article like 'Grabados adicionales · %'
    or i.article like 'Pintura · %'
    or i.article='Adaptación de imagen / logo para Falcon'
    or i.notes in (
      'Primer grabado incluido; $5 por grabado adicional y pieza.',
      '$2 por pieza coloreada, independientemente del número de grabados con pintura.',
      '$3 por diseño diferente.'
    )
  );
