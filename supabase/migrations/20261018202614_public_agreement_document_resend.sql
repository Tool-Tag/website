begin;
-- A status bearer may request only its own immutable accepted agreement,
-- only to the recipient frozen at acceptance. No customer-supplied email address.
create function public.request_agreement_document_copy(p_token text,p_document uuid,p_request uuid) returns uuid
language plpgsql security definer set search_path='' as $$
declare jid uuid;d public.accepted_documents;existing uuid;recipient text;event_id uuid;begin
 select job_id into jid from private.job_status_links where token_hash=encode(sha256(convert_to(p_token,'UTF8')),'hex');
 if jid is null then raise exception 'Status link unavailable';end if;
 select a.* into d from public.documents doc join public.accepted_documents a on a.id=doc.accepted_document_id
 where doc.id=p_document and doc.job_id=jid and a.job_id=jid and doc.unit_id='10000000-0000-0000-0000-000000000002' and doc.type='Accepted Agreement' and doc.visibility='customer' and doc.status<>'Archived' for update of a;
 if d.id is null then raise exception 'Accepted agreement unavailable';end if;
 if p_request is null then raise exception 'Request identifier required';end if;
 select id into existing from public.notifications where dedupe_key='agreement-resend:'||d.id||':'||p_request;
 if existing is not null then return existing;end if;
 if not exists(select 1 from public.accepted_document_status where document_id=d.id and pdf_status='Ready') or not exists(select 1 from private.accepted_pdf_artifacts where document_id=d.id) then raise exception 'Your accepted agreement PDF is not available yet. Please contact ToolTag.';end if;
 if exists(select 1 from public.notifications where payload->>'document_id'=d.id::text and event='AGREEMENT_DOCUMENT_RESENT' and (status in ('Pending Integration','Queued') or mail_error='GMAIL_DELIVERY_UNKNOWN')) then raise exception 'The previous delivery is awaiting confirmation. Please contact ToolTag before resending.';end if;
 if exists(select 1 from public.notifications where payload->>'document_id'=d.id::text and event='AGREEMENT_DOCUMENT_RESENT' and created_at>now()-interval '90 seconds') then raise exception 'Please wait 90 seconds before requesting another copy.';end if;
 if (select count(*) from public.notifications where payload->>'document_id'=d.id::text and event='AGREEMENT_DOCUMENT_RESENT' and created_at>now()-interval '1 day')>=10 then raise exception 'The daily resend limit was reached. Please contact ToolTag.';end if;
 recipient:=coalesce(nullif(d.customer_recipient_email,''),d.snapshot->>'customer_email');
 if nullif(recipient,'') is null then raise exception 'Accepted recipient unavailable. Please contact ToolTag.';end if;
 insert into public.notifications(unit_id,event,entity_id,recipient,dedupe_key,payload)
 values(d.unit_id,'AGREEMENT_DOCUMENT_RESENT',d.quote_id,recipient,'agreement-resend:'||d.id||':'||p_request,
 jsonb_build_object('template','notification','document_id',d.id,'accepted_agreement_attachment',true,'subject','Your accepted ToolTag Agreement — '||d.acceptance_folio,'text','As requested, your accepted ToolTag Quote and Agreement is attached for your records. This is the unchanged document recorded when you accepted your quote.','live_eligible',true)) returning id into event_id;
 -- Explicit customer request is eligible even for an acceptance predating live mail.
 update public.notifications set delivery_phase='production' where id=event_id;
 return event_id;
end$$;
revoke all on function public.request_agreement_document_copy(text,uuid,uuid) from public;
grant execute on function public.request_agreement_document_copy(text,uuid,uuid) to anon,authenticated;
notify pgrst,'reload schema';
commit;
