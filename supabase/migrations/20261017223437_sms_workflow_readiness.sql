begin;
-- Resolve the same commercial flow for all notification entity types. No historical replay.
create function private.notification_sms_flow(n public.notifications) returns uuid
language sql stable security definer set search_path='' as $$
 select f.flow_id from (
  select j.flow_id from public.jobs j where j.id=n.entity_id and j.unit_id=n.unit_id
  union all select q.flow_id from public.quotes q where q.id=n.entity_id and q.unit_id=n.unit_id
  union all select j.flow_id from public.sales s join public.jobs j on j.id=s.job_id where s.transaction_id=n.entity_id and s.unit_id=n.unit_id
  union all select j.flow_id from public.collections c join public.sales s on s.transaction_id=c.sale_id join public.jobs j on j.id=s.job_id where c.transaction_id=n.entity_id and c.unit_id=n.unit_id
  union all select j.flow_id from public.job_receipts r join public.jobs j on j.id=r.job_id where r.id=n.entity_id and r.unit_id=n.unit_id
  union all select j.flow_id from public.job_extensions x join public.jobs j on j.id=x.job_id where x.id=n.entity_id and x.unit_id=n.unit_id
  union all select j.flow_id from public.refund_requests r join public.jobs j on j.id=r.job_id where r.id=n.entity_id and r.unit_id=n.unit_id
  union all select j.flow_id from public.payment_requests r join public.jobs j on j.id=r.job_id where r.id=n.entity_id and r.unit_id=n.unit_id
  union all select q.flow_id from private.get_tagged_receipts r join public.quotes q on q.id=r.quote_id where r.id=n.entity_id and q.unit_id=n.unit_id
 ) f where n.unit_id='10000000-0000-0000-0000-000000000002' limit 1
$$;
revoke all on function private.notification_sms_flow(public.notifications) from public,anon,authenticated;
do $$declare d text;old text;begin
 d:=pg_get_functiondef('private.enqueue_sms()'::regprocedure);
 old:='select flow_id into fid from public.jobs where id=new.entity_id;'||chr(10)||' if fid is null then select flow_id into fid from public.quotes where id=new.entity_id;end if;';
 if position(old in d)=0 then raise exception 'Unexpected SMS flow resolver';end if;
 d:=replace(d,old,'fid:=private.notification_sms_flow(new);');
 if position('''SHOP_PICKUP''' in d)=0 then raise exception 'Unexpected SMS event allowlist';end if;
 d:=replace(d,'''SHOP_PICKUP''','''SHOP_PICKUP'',''QUOTE_REVISION'',''REVISION_REQUIRES_ACCEPTANCE'',''JOB_READY_FOR_DELIVERY'',''REFUND_UPDATE'',''CUSTOMER_REPORTED_ISSUE'',''FINAL_COMPLETION'',''ADMINISTRATIVE_COMPLETION'',''REQUEST_REJECTED'',''GET_TAGGED_RECEIVED''');
 execute d;
end$$;
-- Request notifications with an established Quote keep their existing Request tracking link.
alter function public.sms_message_context(uuid) rename to sms_message_context_before_workflow_readiness;
revoke all on function public.sms_message_context_before_workflow_readiness(uuid) from public,anon,authenticated,service_role;
create function public.sms_message_context(p_notification uuid) returns jsonb
language plpgsql security definer set search_path='' as $$declare n public.notifications;r private.get_tagged_receipts;token text;begin
 if coalesce(auth.role(),'')<>'service_role' then raise exception 'Worker credentials required';end if;
 select * into n from public.notifications where id=p_notification and unit_id='10000000-0000-0000-0000-000000000002';
 if n.event in ('REQUEST_REJECTED','GET_TAGGED_RECEIVED') then
  select * into r from private.get_tagged_receipts where id=n.entity_id;
  select l.token into token from private.request_status_links l where l.request_id=r.id;
  if token is null then return null;end if;
  return jsonb_build_object('job_code',r.reference,'action_path','/status/'||token);
 end if;
 return public.sms_message_context_before_workflow_readiness(p_notification);
end$$;
revoke all on function public.sms_message_context(uuid) from public,anon,authenticated;
grant execute on function public.sms_message_context(uuid) to service_role;
notify pgrst,'reload schema';
commit;
