begin;
alter table public.support_messages add column message_kind text not null default 'Conversation' check(message_kind in ('Conversation','Acknowledgment'));
alter table public.support_messages add column is_automatic boolean not null default false;
create table public.support_acknowledgments (
 inbound_id uuid primary key references public.support_messages(id),outbound_id uuid unique not null default gen_random_uuid(),
 conversation_id uuid not null references public.support_conversations(id),body text not null,
 status text not null default 'Queued' check(status in ('Queued','Sending','Sent','Failed','Unknown','Cancelled')),created_at timestamptz not null default now()
);
alter table public.support_acknowledgments enable row level security;
revoke all on public.support_acknowledgments from public,anon,authenticated;
grant select on public.support_acknowledgments to authenticated,service_role;
create policy support_ack_read on public.support_acknowledgments for select to authenticated using(exists(select 1 from public.support_conversations c where c.id=conversation_id and private.has_block(c.unit_id,'support.inbox')));
create function private.enqueue_support_ack() returns trigger language plpgsql security definer set search_path='' as $$declare c public.support_conversations;name text;body text;begin
 if new.direction<>'Inbound' or new.is_automatic then return new;end if;
 select * into c from public.support_conversations where id=new.conversation_id;
 if c.unit_id<>'10000000-0000-0000-0000-000000000002' or (c.channel<>'Email' and new.gmail_message_id is null) then return new;end if;
 if c.mailbox='support' and c.case_code is null then update public.support_conversations set case_code=private.next_support_code() where id=c.id returning * into c;end if;
 select nullif(trim(customers.name),'') into name from public.customers where id=c.customer_id and unit_id=c.unit_id;
 if c.mailbox='support' then body:='Hi '||coalesce(name,'there')||', we''ve received your inquiry and it will be reviewed within 1-2 days. Your case number is #'||c.case_code||'. Thank you for your patience.';
 else body:='Hi '||coalesce(name,'there')||', we''ve received your message and we''ll get back to you as soon as possible. Thank you for reaching out.';end if;
 insert into public.support_acknowledgments(inbound_id,conversation_id,body) values(new.id,c.id,body) on conflict(inbound_id) do nothing;return new;
end$$;
create trigger enqueue_support_ack after insert on public.support_messages for each row execute function private.enqueue_support_ack();
create function public.support_claim_ack() returns jsonb language plpgsql security definer set search_path='' as $$declare a public.support_acknowledgments;c public.support_conversations;m public.support_messages;subject text;begin
 perform private.require_support_worker();
 -- Do not send stale queued acknowledgments after an actual staff response/closure.
 update public.support_acknowledgments q set status='Cancelled' from public.support_conversations conv,public.support_messages inbound
 where q.status='Queued' and conv.id=q.conversation_id and inbound.id=q.inbound_id and (conv.status='Closed' or exists(select 1 from public.support_messages human where human.conversation_id=conv.id and human.direction='Outbound' and human.message_kind<>'Acknowledgment' and human.delivery_status='Sent' and human.sent_at>=inbound.sent_at));
 select * into a from public.support_acknowledgments where status='Queued' order by created_at,inbound_id for update skip locked limit 1;if a.inbound_id is null then return null;end if;
 select * into c from public.support_conversations where id=a.conversation_id;select * into m from public.support_messages where id=a.inbound_id;
 subject:=(case when c.mailbox='support' then '['||c.case_code||'] Re: ' else 'Re: ' end)||regexp_replace(c.subject,'^(Re: *)+','','i');
 insert into public.support_messages(id,conversation_id,rfc_message_id,gmail_thread_id,direction,sender_email,subject,body,delivery_status,message_kind,is_automatic)
 values(a.outbound_id,c.id,'<'||a.outbound_id||'@tooltag.martinlab.studio>',m.gmail_thread_id,'Outbound',c.mailbox,subject,a.body,'Sending','Acknowledgment',true);
 update public.support_acknowledgments set status='Sending' where inbound_id=a.inbound_id;
 return jsonb_build_object('automatic',true,'id',a.outbound_id,'mailbox',c.mailbox,'to',c.sender_email,'subject',subject,'body',a.body,'message_id','<'||a.outbound_id||'@tooltag.martinlab.studio>','thread_id',m.gmail_thread_id,'in_reply_to',m.rfc_message_id,'references',trim(m.references_header||' '||m.rfc_message_id));
end$$;
create function private.track_support_ack_result() returns trigger language plpgsql security definer set search_path='' as $$begin
 if new.message_kind='Acknowledgment' then update public.support_acknowledgments set status=new.delivery_status where outbound_id=new.id and new.delivery_status in ('Sent','Failed','Unknown');end if;return new;
end$$;
create trigger track_support_ack_result after update of delivery_status on public.support_messages for each row execute function private.track_support_ack_result();
-- Acknowledgments are receipts, never human responses or closure confirmations.
do $$declare definition text;begin
 select pg_get_functiondef('public.support_ingest(jsonb)'::regprocedure) into definition;
 definition:=replace(definition,'sender_email,subject,body,sent_at)','sender_email,subject,body,sent_at,is_automatic)');
 definition:=replace(definition,$match$(p->>'sent_at')::timestamptz);$match$,$replacement$(p->>'sent_at')::timestamptz,coalesce((p->>'automatic')::boolean,false));$replacement$);execute definition;
 select pg_get_functiondef('public.support_finish_reply(uuid,text,text,text,text)'::regprocedure) into definition;
 definition:=replace(definition,'update public.support_conversations set status=''Open'',closed_at=null,updated_at=now() where id=c.id;', 'update public.support_conversations set status=case when m.message_kind=''Acknowledgment'' then status else ''Open'' end,closed_at=case when m.message_kind=''Acknowledgment'' then closed_at else null end,updated_at=now() where id=c.id;');execute definition;
 select pg_get_functiondef('private.support_response_to_job()'::regprocedure) into definition;
 definition:=replace(definition,'if new.direction=''Outbound''','if new.message_kind<>''Acknowledgment'' and new.direction=''Outbound''');execute definition;
 select pg_get_functiondef('public.urgent_login_attention()'::regprocedure) into definition;
 definition:=replace(definition,'o.delivery_status=''Sent''','o.delivery_status=''Sent'' and o.message_kind<>''Acknowledgment''');execute definition;
 select pg_get_functiondef('public.support_cases()'::regprocedure) into definition;
 definition:=replace(definition,'direction=''Outbound'' and delivery_status=''Sent''','direction=''Outbound'' and delivery_status=''Sent'' and message_kind<>''Acknowledgment''');execute definition;
 select pg_get_functiondef('public.support_prepare_reply(uuid,uuid,text)'::regprocedure) into definition;
 definition:=replace(definition,$match$delivery_status in ('Sending','Unknown')$match$,$replacement$delivery_status in ('Sending','Unknown') and message_kind<>'Acknowledgment'$replacement$);execute definition;
 select pg_get_functiondef('public.support_close(uuid)'::regprocedure) into definition;
 definition:=replace(definition,$match$delivery_status in ('Sending','Unknown')$match$,$replacement$delivery_status in ('Sending','Unknown') and message_kind<>'Acknowledgment'$replacement$);execute definition;
 select pg_get_functiondef('public.support_resolve_protocol(uuid,uuid)'::regprocedure) into definition;
 definition:=replace(definition,'direction=''Outbound'' and delivery_status=''Sent''','direction=''Outbound'' and delivery_status=''Sent'' and message_kind<>''Acknowledgment''');execute definition;
end$$;
revoke all on function private.enqueue_support_ack(),private.track_support_ack_result() from public,anon,authenticated;
revoke all on function public.support_claim_ack() from public,anon,authenticated;
grant execute on function public.support_claim_ack() to service_role;
commit;
