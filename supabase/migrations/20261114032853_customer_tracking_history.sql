begin;

-- The current status link is the only capability accepted by this reader.
create function public.customer_tracking_history(p_token text)
returns jsonb
language plpgsql stable security definer
set search_path = ''
as $$
declare
  j public.jobs;
  customer_email text;
begin
  j := private.audit_status_job(p_token);
  if not exists (
    select 1 from public.business_units u where u.id = j.unit_id and u.code = 'TOOLTAG'
  ) then
    raise exception 'Status link unavailable';
  end if;
  customer_email := nullif(lower(btrim(private.job_customer_recipient(j.id))), '');

  return jsonb_build_object(
    'pieces', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'sequence', i.sequence, 'name', i.article, 'stage', i.stage
      ) order by i.sequence), '[]'::jsonb)
      from public.job_items i
      where i.unit_id = j.unit_id and i.job_id = j.id
    ),
    'steps', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'label', h.label, 'at', h.at
      ) order by h.at, h.priority, h.label), '[]'::jsonb)
      from (
        select distinct a.created_at as at,
          case when a.field = 'status' then 1 else 0 end as priority,
          case a.new_value #>> '{}'
            when 'Preparing' then 'Preparation'
            when 'Delivered – Pending Customer Acceptance' then 'Delivered'
            else a.new_value #>> '{}'
          end as label
        from public.audit_log a
        where a.unit_id = j.unit_id and a.entity_id = j.id and a.entity = 'jobs'
          and a.old_value is distinct from a.new_value
          and (
            (a.field = 'work_stage' and a.new_value #>> '{}' in (
              'Received at Shop', 'Receiving Evidence', 'Preparing', 'Engraving',
              'Final Evidence', 'Final Details', 'Delivery In Progress', 'Issue Review',
              'Payment', 'Payment Verification'
            ))
            or (a.field = 'status' and a.new_value #>> '{}' in (
              'Authorized', 'Ready for Delivery', 'Delivered – Pending Customer Acceptance',
              'Completed', 'Cancelled'
            ))
          )
      ) h
    ),
    'updates', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'event', case when n.event = 'JOB_STATUS_UPDATE' then
          case split_part(n.dedupe_key, ':', 3)
            when 'engraving' then 'Engraving update'
            when 'final-details' then 'Final Details update'
            when 'in-process' then 'In Process update'
            when 'received-at-shop' then 'Received at Shop update'
            else 'Job status update'
          end
        else replace(n.event, '_', ' ') end, 'at', n.sent_at
      ) order by n.sent_at, n.id), '[]'::jsonb)
      from public.notifications n
      where n.unit_id = j.unit_id
        and n.status = 'Sent' and n.sent_at is not null
        and lower(btrim(n.recipient)) = customer_email
        and (
          n.entity_id in (j.id, j.quote_id)
          or exists (select 1 from public.job_receipts r where r.id = n.entity_id and r.job_id = j.id)
          or exists (select 1 from public.job_extensions e where e.id = n.entity_id and e.job_id = j.id)
          or exists (
            select 1 from public.sales s
            left join public.collections c on c.sale_id = s.transaction_id and c.unit_id = s.unit_id
            where s.unit_id = j.unit_id and s.job_id = j.id
              and n.entity_id in (s.transaction_id, c.transaction_id)
          )
        )
    )
  );
end;
$$;

revoke all on function public.customer_tracking_history(text) from public, anon, authenticated;
grant execute on function public.customer_tracking_history(text) to anon, authenticated;

commit;
