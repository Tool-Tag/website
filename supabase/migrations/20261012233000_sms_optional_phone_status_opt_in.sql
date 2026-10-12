-- Forward-only: optional intake phone, audited status opt-in, welcome-first queue.
begin;
alter table private.sms_consents add column granted_at timestamptz;
update private.sms_consents set granted_at=updated_at where granted;
-- Preserve the existing intake, rate limiting, deduplication and matching logic.
do $$declare d text;begin
 select pg_get_functiondef('public.submit_get_tagged_v2(uuid,text,jsonb)'::regprocedure) into d;
 if position('or length(private.get_tagged_phone(contact->>''phone'')) not between 7 and 15' in d)=0 then raise exception 'Unexpected intake phone validation';end if;
 d:=replace(d,'or length(private.get_tagged_phone(contact->>''phone'')) not between 7 and 15','or (nullif(trim(contact->>''phone''),'''') is not null and length(private.get_tagged_phone(contact->>''phone'')) not between 7 and 15)');
 d:=replace(d,'or private.get_tagged_phone(c.phone)=private.get_tagged_phone(contact->>''phone'')','or (nullif(private.get_tagged_phone(contact->>''phone''),'''') is not null and private.get_tagged_phone(c.phone)=private.get_tagged_phone(contact->>''phone''))');
 execute d;
end$$;
create or replace function public.set_sms_consent(p_token text,p_scope text,p_phone text,p_granted boolean) returns void
language plpgsql security definer set search_path='' as $$
declare f public.commercial_flows;c private.sms_consents;changed boolean;event_id uuid;nid uuid;jid uuid;
 disclosure text:='By checking, you consent to receive delivery updates and shipping notifications from ToolTag, a DBA of Bandits of the Framing LLC. Message frequency may vary. Message and data rates may apply. Reply HELP for help or STOP to opt-out.'||E'\nBy checking, I accept Terms of Service & Privacy Policy.\nTerms: https://tooltag.martinlab.studio/terms\nPrivacy: https://tooltag.martinlab.studio/privacy';
begin
 f:=private.sms_flow(p_token,p_scope);
 perform 1 from public.commercial_flows where id=f.id for update;
 if p_granted is null then raise exception 'Explicit consent is required';end if;
 if p_granted and (p_phone is null or p_phone !~ '^\+[1-9][0-9]{7,14}$') then raise exception 'Enter a valid mobile number';end if;
 select * into c from private.sms_consents where flow_id=f.id for update;
 changed:=p_granted and (not coalesce(c.granted,false) or c.phone is distinct from p_phone);
 if not p_granted and coalesce(c.phone,'')<>'' then
  update private.sms_consents set granted=false,updated_at=now() where phone=c.phone and unit_id=f.unit_id;
  insert into private.sms_consent_events(flow_id,phone,granted,source,disclosure) select flow_id,phone,false,p_scope,disclosure from private.sms_consents where phone=c.phone and unit_id=f.unit_id;
 end if;
 insert into private.sms_consents(flow_id,unit_id,customer_id,phone,granted,granted_at)
 values(f.id,f.unit_id,f.customer_id,case when p_granted then p_phone else coalesce(c.phone,'') end,p_granted,case when changed then now() else c.granted_at end)
 on conflict(flow_id) do update set phone=excluded.phone,granted=excluded.granted,granted_at=excluded.granted_at,updated_at=now();
 if changed or not p_granted then
 insert into private.sms_consent_events(flow_id,phone,granted,source,disclosure) values(f.id,case when p_granted then p_phone else coalesce(c.phone,'') end,p_granted,p_scope,disclosure) returning id into event_id;
 end if;
 if changed then
 -- Never repurpose or replay historical deliveries after a grant/number change.
 update private.sms_deliveries set status='Skipped',reason='BEFORE_OPT_IN',finished_at=now() where flow_id=f.id and status='Pending';
 if p_scope='status' then
 select id into jid from public.jobs where flow_id=f.id;
 insert into public.notifications(unit_id,event,entity_id,dedupe_key,payload)
 values(f.unit_id,'SMS_WELCOME',jid,'sms-welcome:'||event_id,jsonb_build_object('sms_only',true)) returning id into nid;
 -- SMS-only event has no email template/recipient and is not dispatched as email.
 insert into private.sms_deliveries(notification_id,flow_id,status,expires_at) values(nid,f.id,'Pending',now()+interval '30 days');
 end if;
 end if;
end$$;
-- Keep existing claim safety (STOP, activation, expiry, TEST number, uncertain sends).
do $$declare d text;begin
 select pg_get_functiondef('public.claim_sms()'::regprocedure) into d;
 if position('when d.expires_at<=now()' in d)=0 then raise exception 'Unexpected SMS claim definition';end if;
 d:=replace(d,'when d.created_at<s.activated_at then ''BEFORE_ACTIVATION''','when d.created_at<s.activated_at and n.event<>''SMS_WELCOME'' then ''BEFORE_ACTIVATION''');
 d:=replace(d,'when d.expires_at<=now()', 'when c.granted_at is not null and n.created_at<c.granted_at then ''BEFORE_OPT_IN'' when d.expires_at<=now()');
 -- A welcome must be accepted by SNS before any subsequent status SMS is sent.
 d:=replace(d,'select * into c from private.sms_consents where flow_id=d.flow_id;', 'select * into c from private.sms_consents where flow_id=d.flow_id; if n.event<>''SMS_WELCOME'' and exists(select 1 from private.sms_deliveries w join public.notifications wn on wn.id=w.notification_id where w.flow_id=d.flow_id and wn.event=''SMS_WELCOME'' and wn.created_at>=coalesce(c.granted_at,''-infinity''::timestamptz) and w.status<>''Sent'') then continue;end if;');
 execute d;
end$$;
-- Explicit intake grants are audited by the existing trigger; timestamp new grants.
create function private.sms_grant_timestamp() returns trigger language plpgsql set search_path='' as $$begin
 if TG_OP='UPDATE' and new.granted and old.granted and new.phone is not distinct from old.phone then new.granted_at:=old.granted_at;
 elsif new.granted then new.granted_at:=coalesce(new.granted_at,now());end if;
 return new;
end$$;
revoke all on function private.sms_grant_timestamp() from public,anon,authenticated;
create trigger sms_grant_timestamp before insert or update on private.sms_consents for each row execute function private.sms_grant_timestamp();
revoke all on function public.set_sms_consent(text,text,text,boolean) from public;
grant execute on function public.set_sms_consent(text,text,text,boolean) to anon,authenticated;
notify pgrst,'reload schema';
commit;
