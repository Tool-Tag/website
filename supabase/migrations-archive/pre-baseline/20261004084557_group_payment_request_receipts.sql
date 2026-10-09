
create or replace function public.generate_job_receipt(p_job uuid)
returns uuid
language plpgsql
security definer
set search_path=''
as $$
declare
  j public.jobs;
  snap jsonb;
  rid uuid;
  fingerprint text;
  recipient text;
begin
  select * into j from public.jobs where id=p_job for update;
  perform private.require_admin(j.unit_id);

  snap:=private.job_portal_snapshot(j.id)-'evidence'-'status';

  snap:=snap||jsonb_build_object(
    'payments',
    coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'id',p.payment_key,
          'date',p.transaction_date,
          'amount',p.amount,
          'method',p.payment_method,
          'reference',p.customer_reference
        )
        order by p.transaction_date,p.first_created_at
      )
      from (
        select
          case
            when coalesce(t.reference,'') like 'PAYREQ:%' then t.reference
            else t.id::text
          end as payment_key,
          min(t.transaction_date) as transaction_date,
          min(t.created_at) as first_created_at,
          sum(t.amount) as amount,
          max(t.payment_method) as payment_method,
          case
            when bool_or(coalesce(t.reference,'') like 'PAYREQ:%') then null
            else max(t.reference)
          end as customer_reference
        from public.collections c
        join public.transactions t on t.id=c.transaction_id
        where t.status<>'Voided'
          and c.sale_id in (
            select transaction_id from public.sales where job_id=j.id
            union
            select sale_id from public.job_extensions
            where job_id=j.id and accepted_at is not null
          )
        group by case
          when coalesce(t.reference,'') like 'PAYREQ:%' then t.reference
          else t.id::text
        end
      ) p
    ),'[]'::jsonb),
    'paid_in_full',
    coalesce(
      (snap->'totals'->>'balance_due')::numeric=0
      and (snap->'totals'->>'refunded')::numeric=0,
      false
    ),
    'paid_in_full_date',
    case
      when (snap->'totals'->>'balance_due')::numeric=0
       and (snap->'totals'->>'refunded')::numeric=0
      then (
        select max(t.transaction_date)
        from public.collections c
        join public.transactions t on t.id=c.transaction_id
        where t.status<>'Voided'
          and c.sale_id in (
            select transaction_id from public.sales where job_id=j.id
            union
            select sale_id from public.job_extensions
            where job_id=j.id and accepted_at is not null
          )
      )
    end
  );

  fingerprint:=encode(sha256(convert_to(snap::text,'UTF8')),'hex');

  insert into public.job_receipts(unit_id,job_id,snapshot,snapshot_sha256)
  values(j.unit_id,j.id,snap,fingerprint)
  on conflict(job_id,snapshot_sha256) do nothing
  returning id into rid;

  if rid is null then
    select id into rid
    from public.job_receipts
    where job_id=j.id and snapshot_sha256=fingerprint;
    return rid;
  end if;

  select coalesce(d.customer_recipient_email,a.commercial_snapshot->>'customer_email')
  into recipient
  from public.agreements a
  left join public.accepted_documents d on d.agreement_id=a.id
  where a.quote_id=j.quote_id;

  insert into public.notifications(unit_id,event,entity_id,recipient,dedupe_key,payload)
  values(
    j.unit_id,
    'FINAL_PAID_RECEIPT',
    rid,
    recipient,
    'job-receipt:'||rid,
    jsonb_build_object('template','job_receipt','receipt_id',rid)
  );

  return rid;
end $$;
