"""Normalize only pg_dump transport wrappers and object order; preserve SQL text."""
from pathlib import Path
import argparse,re,difflib,hashlib,json
parser=argparse.ArgumentParser()
parser.add_argument('remote',type=Path);parser.add_argument('local',type=Path);parser.add_argument('--output',type=Path,required=True)
a=parser.parse_args();pattern=re.compile(r'^--\n-- Name: (.*?); Type: (.*?); Schema: (.*?); Owner: (.*?)\n--\n',re.M)
def canonical(p):
 text=p.read_bytes().decode('utf8');matches=list(pattern.finditer(text));out=[]
 for i,m in enumerate(matches):
  block=text[m.start():matches[i+1].start() if i+1<len(matches) else len(text)]
  block=re.sub(r'^\\(?:un)?restrict .*\n','',block,flags=re.M)
  block=re.sub(r'--\n-- PostgreSQL database dump complete\n--\n','',block)
  out.append((m.groups(),block.strip()))
 return '\n\n'.join(block for key,block in sorted(out))+'\n'
remote=canonical(a.remote);local=canonical(a.local)
diff=''.join(difflib.unified_diff(remote.splitlines(True),local.splitlines(True),fromfile='remote',tofile='local'))
a.output.write_text(diff)
print(json.dumps({'diff_bytes':len(diff),'remote_sha256':hashlib.sha256(remote.encode()).hexdigest(),'local_sha256':hashlib.sha256(local.encode()).hexdigest()}))
raise SystemExit(0 if not diff else 1)
