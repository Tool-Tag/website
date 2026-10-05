
create or replace function public.public_job_status(p_token text)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  j public.jobs;
  customer_name text;
  prog jsonb;
  pr jsonb;
begin
  select x.* into j
  from public.jobs x
  join private.job_status_links l on l.job_id=x.id
  where l.token_hash=encode(sha256(convert_to(p_token,'UTF8')),'hex');

  if j.id is null then raise exception 'Status link unavailable'; end if;

  select c.name into customer_name
  from public.commercial_flows f
  join public.customers c on c.id=f.customer_id
  where f.id=j.flow_id;

  prog:=private.job_item_progress(j.id);

  select to_jsonb(x)-'unit_id'-'terms_snapshot'
  into pr
  from public.pick_return_orders x
  where x.job_id=j.id;

  return jsonb_build_object(
    'code',j.code,
    'customer_name',customer_name,
    'stage',j.customer_stage,
    'job_status',j.status,
    'work_stage',j.work_stage,
    'updated_at',j.updated_at,
    'items_total',coalesce((prog->>'total')::integer,0),
    'items_completed',coalesce((prog->>'finished')::integer,0),
    'items_started',coalesce((prog->>'started')::integer,0),
    'item_progress',prog,
    'pickup_return',pr,
    'cancelled',j.status='Cancelled',
    'steps',jsonb_build_array(
      'In Process',
      'Engraving',
      'Final Details',
      'Completed'
    )
  );
end $$;
