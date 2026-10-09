from pathlib import Path
import re,json,hashlib,collections
import argparse
parser=argparse.ArgumentParser(description="Partition exact pg_dump blocks; never reconstruct DDL")
parser.add_argument("--dump-dir",type=Path,required=True)
parser.add_argument("--repository",type=Path,default=Path.cwd())
args=parser.parse_args();root=args.dump_dir;repo=args.repository
pat=re.compile(r'^--\n-- Name: (.*?); Type: (.*?); Schema: (.*?); Owner: (.*?)\n--\n',re.M)
def split(path):
 s=path.read_bytes().decode('utf8');matches=list(pat.finditer(s));return s[:matches[0].start()],[(m.groups(),s[m.start():matches[i+1].start() if i+1<len(matches) else len(s)]) for i,m in enumerate(matches)]
header,blocks=split(root/'remote-schema-app.sql');fullheader,full=split(root/'remote-schema-full.sql')
# Client restrict commands and completion footer are dump transport wrappers, not DDL.
def clean(s):return re.sub(r'^\\(?:un)?restrict .*\n','',s,flags=re.M)
header=clean(header)
core={'business_units','memberships','unit_settings','audit_log','mutation_requests','annual_sequences','agreement_sequences'}
finance={'accounts','physical_accounts','categories','transactions','expenses','assets','vendors','owner_transactions','reimbursements','inter_unit_transfers','mileage','monthly_closes','sales','sale_versions','collections','refunds','payment_requests','job_receipts','commercial_flows'}
commercial={'customers','quotes','quote_items','policies','agreements','accepted_documents','accepted_document_status','accepted_pdf_artifacts','job_extensions','jobs','extension_links','delivery_scopes','public_links','job_review_links'}
integrations={'notifications','quote_delivery','customer_mail_activation','job_mail_links'}
fncore={'can_access','can_view_physical','unit','require_admin','require_worker','audit_change','idempotency_key','next_code','actor','touch_updated_at','is_admin','request_context','request_hash','claim_mutation','finish_mutation'}
post={'CONSTRAINT','FK CONSTRAINT','INDEX','TRIGGER','POLICY','ROW SECURITY','ACL','DEFAULT ACL','VIEW','MATERIALIZED VIEW','RULE','EVENT TRIGGER'}
names=['core','finance','commercial','operations','integrations','security_bootstrap'];out={n:[] for n in names};manifest=[]
for i,(meta,block) in enumerate(blocks):
 name,typ,schema,owner=meta
 if (typ=='SCHEMA' and name=='public') or (typ=='COMMENT' and name=='SCHEMA public'):
  manifest.append({'source':'remote-schema-app.sql','ordinal':i,'name':name,'type':typ,'schema':schema,'domain':'managed_public_schema','sha256':hashlib.sha256(clean(block).encode()).hexdigest()});continue
 base=name.split('(')[0].split(' ')[0]
 if typ in post:domain='security_bootstrap'
 elif typ=='SCHEMA' or typ in {'TYPE','DOMAIN','SEQUENCE'} or base in core or base in fncore:domain='core'
 elif base in integrations or (typ=='FUNCTION' and re.search(r'mail|notification|send_quote|resend_quote|delivery_event',base)):domain='integrations'
 elif base in finance or (typ=='FUNCTION' and re.search(r'movement|finance|asset|expense|physical|monthly|reimburse|collection|payment|refund|mileage|receipt|account',base) and not re.search(r'pickup|return|cancellation',base)):domain='finance'
 elif base in commercial or (typ=='FUNCTION' and re.search(r'quote|customer|agreement|accepted|extension|commercial|pricing|priced|paint|engraving_charge|logo',base) and not re.search(r'get_tagged|request',base)):domain='commercial'
 else:domain='operations'
 # Dump comments on a schema follow the schema; table comments retain classification.
 if typ=='COMMENT' and name.startswith('SCHEMA '):domain='core'
 b=clean(block);out[domain].append(b);manifest.append({'source':'remote-schema-app.sql','ordinal':i,'name':name,'type':typ,'schema':schema,'domain':domain,'sha256':hashlib.sha256(b.encode()).hexdigest()})
# Storage policies are application-managed but omitted by a public/private schema filter.
for i,(meta,block) in enumerate(full):
 name,typ,schema,owner=meta
 if schema=='storage' and typ=='POLICY':
  b=clean(block);out['security_bootstrap'].append(b);manifest.append({'source':'remote-schema-full.sql','ordinal':i,'name':name,'type':typ,'schema':schema,'domain':'security_bootstrap','sha256':hashlib.sha256(b.encode()).hexdigest()})
# All bootstrap SQL is exact pg_dump --data-only output, not handwritten INSERTs.
out['security_bootstrap'].append(clean((root/'remote-bootstrap.sql').read_bytes().decode('utf8')))
dest=repo/'supabase/baseline-stage1-candidates';dest.mkdir(parents=True,exist_ok=True)
for i,n in enumerate(names):
 (dest/f'{i+1:02}_baseline_{n}.sql').write_text(header+''.join(out[n]))
# Supabase-owned prerequisites: use exact dump blocks; do not fabricate managed tables/auth helpers.
platform=[]
for meta,block in full:
 name,typ,schema,owner=meta
 if schema in {'auth','storage'} and typ!='POLICY':platform.append(clean(block))
 elif typ=='SCHEMA' and name in {'auth','storage','extensions','vault'}:platform.append(clean(block))
 elif schema=='-' and name in {'SCHEMA auth','SCHEMA storage','SCHEMA extensions','SCHEMA vault'}:platform.append(clean(block))
 elif typ=='EXTENSION' and name in {'pgcrypto','uuid-ossp','pg_stat_statements','supabase_vault'}:platform.append(clean(block))
(root/'platform-prerequisites.sql').write_text(clean(fullheader)+''.join(platform))
(dest/'manifest.json').write_text(json.dumps({'source_files':{p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in [root/'remote-schema-app.sql',root/'remote-schema-full.sql',root/'remote-bootstrap.sql']},'blocks':manifest,'counts':dict(collections.Counter(x['domain'] for x in manifest))},indent=2)+'\n')
assert len({(x['source'],x['ordinal']) for x in manifest}) == len(manifest)
assert sum(x['source']=='remote-schema-app.sql' for x in manifest) == len(blocks)
print('All',len(blocks),'application dump blocks accounted for exactly once;',len(manifest)-len(blocks),'Storage policy blocks added.')
print('Counts:',dict(collections.Counter(x['domain'] for x in manifest)))
