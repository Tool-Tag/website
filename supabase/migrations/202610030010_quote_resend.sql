-- Explicit quote resend; serializes requests per quote and preserves original expiry.
create or replace function public.resend_quote(p_id uuid) returns text
language plpgsql security definer set search_path='' as $$
declare q public.quotes; previous public.notifications; destination text; token text; wait_seconds integer;
begin
 select * into q from public.quotes where id=p_id for update;
 if q.id is null then raise exception 'Cotización no encontrada'; end if;
 perform private.require_admin(q.unit_id);
 if q.status not in ('Sent','Viewed') or q.expires_at is null or q.expires_at<=now() then
  raise exception 'Solo puedes reenviar una cotización enviada y vigente. Crea una revisión si ya venció o fue aceptada';
 end if;
 select * into previous from public.notifications where entity_id=q.id and event='Quote Sent' order by created_at desc,id desc limit 1 for update;
 if previous.id is null then raise exception 'Primero envía la cotización'; end if;
 wait_seconds:=ceil(extract(epoch from (greatest(previous.created_at,previous.mail_attempted_at,(previous.payload->>'resend_requested_at')::timestamptz)+interval '90 seconds'-clock_timestamp())));
 if wait_seconds>0 then raise exception 'Espera % segundos para reenviar la cotización',wait_seconds; end if;
 if coalesce(previous.payload->>'test','false')='true' then raise exception 'No se reenvían notificaciones de prueba desde esta acción'; end if;
 if previous.status not in ('Sent','Pending Integration') or (previous.status='Pending Integration' and previous.mail_claim is not null) or exists(select 1 from public.notifications where entity_id=q.id and event='Quote Sent' and id<>previous.id and status in ('Queued','Pending Integration')) then
  raise exception 'El envío anterior requiere revisión antes de reenviar para evitar duplicados';
 end if;
 select d.recipient,d.token into destination,token from private.quote_delivery d where d.quote_id=q.id;
 if nullif(destination,'') is null or token is null or q.review_snapshot is null then raise exception 'Faltan los datos del envío original'; end if;
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
end $$;
revoke all on function public.resend_quote(uuid) from public,anon;
grant execute on function public.resend_quote(uuid) to authenticated;

notify pgrst, 'reload schema';
