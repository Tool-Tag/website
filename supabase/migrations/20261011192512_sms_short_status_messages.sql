-- Resolve existing customer links for the SMS worker only; email payloads unchanged.
create function public.sms_message_context(p_notification uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare f uuid;j public.jobs;q public.quotes;t text;
begin
 if coalesce(auth.role(),'')<>'service_role' then raise exception 'Worker credentials required';end if;
 select d.flow_id into f from private.sms_deliveries d join public.notifications n on n.id=d.notification_id
 where n.id=p_notification and n.unit_id='10000000-0000-0000-0000-000000000002';
 if f is null then return null;end if;
 select * into j from public.jobs where flow_id=f and unit_id='10000000-0000-0000-0000-000000000002';
 if j.id is not null then
  t:=private.ensure_job_status_link(j.id);
  return jsonb_build_object('job_code',j.code,'stage',coalesce(j.customer_stage,j.work_stage,j.status),'action_path','/status/'||t);
 end if;
 select * into q from public.quotes where flow_id=f and unit_id='10000000-0000-0000-0000-000000000002' order by revision desc limit 1;
 select d.token into t from private.quote_delivery d join private.public_links l on l.quote_id=d.quote_id and l.token_hash=encode(sha256(convert_to(d.token,'UTF8')),'hex') where d.quote_id=q.id and l.expires_at>now();
 if q.id is null or t is null then return null;end if;
 return jsonb_build_object('job_code',q.code,'stage',q.status,'action_path','/review/'||t);
end $$;
revoke all on function public.sms_message_context(uuid) from public,anon,authenticated;
grant execute on function public.sms_message_context(uuid) to service_role;
