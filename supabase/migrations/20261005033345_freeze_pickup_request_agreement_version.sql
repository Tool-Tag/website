create or replace function private.create_get_tagged_draft(p_receipt uuid,p_customer uuid)
returns uuid
language plpgsql
security definer
set search_path=''
as $$
declare
  u constant uuid:='10000000-0000-0000-0000-000000000002';
  y integer;
  seq integer;
  fid uuid;
  qid uuid;
  r private.get_tagged_receipts;
  policy uuid;
  requested_version integer;
begin
  select * into r
  from private.get_tagged_receipts
  where id=p_receipt
  for update;

  if r.quote_id is not null then
    return r.quote_id;
  end if;

  if not exists(
    select 1 from public.customers
    where id=p_customer and unit_id=u
  ) then
    raise exception 'Customer not found';
  end if;

  if private.get_tagged_is_pickup(r.details) then
    requested_version:=nullif(
      r.details->'service'->>'agreement_version',''
    )::integer;

    if requested_version is null then
      raise exception 'Pickup Agreement version is missing';
    end if;

    select p.id into policy
    from public.policies p
    where p.unit_id=u
      and p.version=requested_version
      and p.published_at is not null
    limit 1;

    if policy is null then
      raise exception 'Pickup Agreement version is unavailable';
    end if;
  end if;

  y:=extract(year from now() at time zone (
    select timezone from public.unit_settings where unit_id=u
  ));

  insert into private.annual_sequences(year,value)
  values(y,1)
  on conflict(year) do update
    set value=private.annual_sequences.value+1
  returning value into seq;

  insert into public.commercial_flows(unit_id,customer_id,year,sequence)
  values(u,p_customer,y,seq)
  returning id into fid;

  insert into public.quotes(
    unit_id,flow_id,code,notes,source,intake_details,policy_id
  )
  values(
    u,
    fid,
    'TT-Q-'||y||'-'||lpad(seq::text,5,'0'),
    r.details->>'notes',
    'public_get_tagged',
    r.details-'quote_items',
    policy
  )
  returning id into qid;

  perform private.store_get_tagged_items(
    qid,
    private.get_tagged_scope(r.details->'quote_items')
  );

  perform private.ensure_pickup_fee_item(qid);

  update private.get_tagged_receipts
  set quote_id=qid,customer_id=p_customer
  where id=p_receipt;

  return qid;
end $$;
