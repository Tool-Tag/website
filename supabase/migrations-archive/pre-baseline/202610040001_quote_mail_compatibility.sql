-- Narrow compatibility for production still on 005. Never drains historical queues.
-- The full mail-boundary migration can later replace this implementation.
do $migration$ begin
 if to_regprocedure('public.claim_mail_for_mode(uuid,text,text)') is null then
 execute $definition$
 create function public.claim_mail_for_mode(p_quote uuid,p_test_recipient text,p_mode text)
 returns jsonb language plpgsql security definer set search_path='' as $fn$
 declare n public.notifications; content jsonb;
 begin
  if p_quote is null then return null; end if;
  perform private.require_admin((select unit_id from public.quotes where id=p_quote));
  if p_mode not in ('live','test-delivery') or p_mode is null then return null; end if;
  for n in select x.* from public.notifications x where x.entity_id=p_quote
   and x.unit_id='10000000-0000-0000-0000-000000000002' and x.event='Quote Sent'
   and x.status='Pending Integration' and x.mail_claim is null and x.due_at<=now()
   and x.payload->>'resend'='true' and x.payload ? 'resend_requested_at'
   and coalesce(x.payload->>'test','false')<>'true'
   order by x.created_at for update skip locked loop
   content:=private.notification_mail(n);
   if content is null or nullif(content->>'recipient','') is null then continue; end if;
   if p_mode='test-delivery' and (nullif(p_test_recipient,'') is null or lower(content->>'recipient')<>lower(p_test_recipient)) then continue; end if;
   update public.notifications set status='Queued',mail_claim=gen_random_uuid(),mail_attempted_at=now() where id=n.id returning * into n;
   return to_jsonb(n)||content;
  end loop;
  return null;
 end $fn$;
 $definition$;
 end if;
end $migration$;
revoke all on function public.claim_mail_for_mode(uuid,text,text) from public,anon;
grant execute on function public.claim_mail_for_mode(uuid,text,text) to authenticated,service_role;
notify pgrst,'reload schema';
