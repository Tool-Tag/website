
create or replace function public.public_status_cancellation_assessment(p_token text)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  j public.jobs;
begin
  select x.* into j
  from public.jobs x
  join private.job_status_links l on l.job_id=x.id
  where l.token_hash=encode(sha256(convert_to(p_token,'UTF8')),'hex');

  if j.id is null then raise exception 'Status link unavailable'; end if;

  return jsonb_build_object(
    'job_code',j.code,'status',j.status,'work_stage',j.work_stage,
    'progress',private.job_item_progress(j.id),
    'assessment',private.cancellation_assessment(j.id),
    'pickup_return',(
      select to_jsonb(pr)-'unit_id'-'terms_snapshot'
      from public.pick_return_orders pr where pr.job_id=j.id
    )
  );
end $$;

revoke all on function public.public_status_cancellation_assessment(text) from public;
grant execute on function public.public_status_cancellation_assessment(text) to anon,authenticated;

create or replace function public.public_status_confirm_cancellation(p_token text)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  j public.jobs;
  rid uuid;
  r public.cancellation_requests;
begin
  select x.* into j
  from public.jobs x
  join private.job_status_links l on l.job_id=x.id
  where l.token_hash=encode(sha256(convert_to(p_token,'UTF8')),'hex')
  for update of x;

  if j.id is null then raise exception 'Status link unavailable'; end if;
  if j.status in ('Completed','Cancelled') then
    raise exception 'This Job can no longer be cancelled';
  end if;

  rid:=private.insert_cancellation_request(j.id);
  perform private.apply_pending_cancellation(j.id);
  select * into r from public.cancellation_requests where id=rid;

  insert into public.notifications(
    unit_id,event,entity_id,recipient,dedupe_key,payload
  )
  values(
    j.unit_id,'JOB_CANCELLED_BY_CUSTOMER',r.id,
    private.job_customer_recipient(j.id),'job-cancelled:'||r.id,
    jsonb_build_object(
      'template','notification',
      'subject','Cancellation confirmed — '||j.code,
      'text',
        'Your cancellation for '||j.code||' has been confirmed.'||
        case when r.refund_eligible_amount>0
          then ' Eligible refund: $'||to_char(r.refund_eligible_amount,'FM999999990.00')||
               '. Approved refunds are generally processed within 5–7 business days.'
          else ''
        end||
        case when r.amount_due>0
          then ' Outstanding amount due: $'||to_char(r.amount_due,'FM999999990.00')||'.'
          else ''
        end,
      'live_eligible',true
    )
  )
  on conflict do nothing;

  return jsonb_build_object(
    'request_id',r.id,'cancelled',true,'refund_status',r.refund_status,
    'assessment',r.assessment,
    'refund_eligible_amount',r.refund_eligible_amount,'amount_due',r.amount_due
  );
end $$;

revoke all on function public.public_status_confirm_cancellation(text) from public;
grant execute on function public.public_status_confirm_cancellation(text) to anon,authenticated;
