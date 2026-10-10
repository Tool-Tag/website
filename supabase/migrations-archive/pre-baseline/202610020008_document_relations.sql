alter table public.agreements add unique(id,unit_id);
alter table public.documents add constraint document_agreement_same_unit foreign key(agreement_id,unit_id) references public.agreements(id,unit_id);
