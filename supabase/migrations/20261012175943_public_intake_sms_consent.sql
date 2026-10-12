-- Forward-only: explicit SMS consent at intake/quote creation and customer lookup.
-- No replay of notifications, no seed of consent, no Agreement/policy text edits.
begin;
create function private.record_web_sms_consent(p_flow uuid,p_sms jsonb,p_source text) returns void language plpgsql security definer set search_path='' as $$
declare f public.commercial_flows;disclosure text;
begin
 if (p_sms->'granted') is distinct from 'true'::jsonb then return;end if;
 if coalesce(p_sms->>'phone','') !~ '^\+[1-9][0-9]{7,14}$' or coalesce(p_sms->>'privacy_url','') !~ '^https://' or coalesce(p_sms->>'terms_url','') !~ '^https://' or nullif(trim(p_sms->>'disclosure'),'') is null then raise exception 'SMS consent requires mobile number, disclosure and published policy links';end if;
 select * into f from public.commercial_flows where id=p_flow and unit_id=(select id from public.business_units where code='TOOLTAG');
 if f.id is null then raise exception 'ToolTag consent flow unavailable';end if;
 disclosure:=(p_sms->>'disclosure')||E'\nPrivacy Policy: '||(p_sms->>'privacy_url')||E'\nTerms: '||(p_sms->>'terms_url');
 insert into private.sms_consents(flow_id,unit_id,customer_id,phone,granted) values(f.id,f.unit_id,f.customer_id,p_sms->>'phone',true)
 on conflict(flow_id) do update set phone=excluded.phone,granted=true,updated_at=now() where p_source='cancellation-lookup' and (not sms_consents.granted or sms_consents.phone is distinct from excluded.phone);
 if found then insert into private.sms_consent_events(flow_id,phone,granted,source,disclosure) values(f.id,p_sms->>'phone',true,p_source,disclosure);end if;
end$$;
create function private.intake_sms_consent() returns trigger language plpgsql security definer set search_path='' as $$declare fid uuid;begin
 if new.quote_id is null or (TG_OP='UPDATE' and new.quote_id is not distinct from old.quote_id) then return new;end if;
 select flow_id into fid from public.quotes where id=new.quote_id;
 perform private.record_web_sms_consent(fid,new.details->'sms','get-tagged');return new;
end$$;
create trigger get_tagged_sms_consent after insert or update of quote_id on private.get_tagged_receipts for each row execute function private.intake_sms_consent();
create function public.request_cancellation_access_with_sms(p_network text,p_name text,p_email text,p_phone text,p_sms jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb;cid uuid;fid uuid;digits text;
begin
 if coalesce(auth.role(),'')<>'service_role' then raise exception 'Server credentials required' using errcode='42501';end if;
 digits:=regexp_replace(p_phone,'[^0-9]','','g');if length(digits)=10 then digits:='1'||digits;end if;
 if p_sms->>'phone' is distinct from '+'||digits then raise exception 'SMS consent must use the entered customer phone';end if;
 result:=public.request_cancellation_access(p_network,p_name,p_email,p_phone);
 if coalesce((result->>'matched')::boolean,false) then
 select id into cid from public.customers where unit_id=(select id from public.business_units where code='TOOLTAG') and lower(trim(name))=lower(trim(p_name)) and lower(trim(email))=lower(trim(p_email)) and private.get_tagged_phone(phone)=private.get_tagged_phone(p_phone) order by created_at desc limit 1;
 for fid in select f.id from public.commercial_flows f where f.customer_id=cid and f.unit_id=(select id from public.business_units where code='TOOLTAG') and (exists(select 1 from public.quotes q where q.flow_id=f.id and q.status in ('Draft','Sent','Viewed','Agreement Pending','Accepted')) or exists(select 1 from public.jobs j where j.flow_id=f.id and j.status<>'Cancelled' and j.work_stage<>'Closed')) loop
 perform private.record_web_sms_consent(fid,p_sms,'cancellation-lookup');
 end loop;
 end if;
 return result;
end$$;
revoke all on function private.record_web_sms_consent(uuid,jsonb,text),private.intake_sms_consent() from public,anon,authenticated;
revoke all on function public.request_cancellation_access_with_sms(text,text,text,text,jsonb) from public,anon,authenticated;
grant execute on function public.request_cancellation_access_with_sms(text,text,text,text,jsonb) to service_role;
commit;
