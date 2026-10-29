import base64,json,os,urllib.request,urllib.error,wave,array,subprocess
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor
import argparse
parser=argparse.ArgumentParser(description="生成可选的离线三语配音，默认复用现有文件")
parser.add_argument('--languages', default='en,zh', help='逗号分隔：en,zh,ja；日语 A 已选定，默认不重生成')
parser.add_argument('--force', action='store_true', help='明确替换已存在的配音文件')
args=parser.parse_args()
key=os.environ.get('FISH_AUDIO_API_KEY')
if not key:raise SystemExit('请在当前终端通过安全来源设置 FISH_AUDIO_API_KEY；运行 App 不需要此变量')
ROOT=Path(__file__).resolve().parent.parent
root=ROOT/'Assets/Voices'
cache=ROOT/'build/voice-generation'
cache.mkdir(parents=True,exist_ok=True)
items=[('en','Nooo~ no touching!','English, with a stretched melodic first Nooo, followed by a short bouncy no touching!'),('zh','不可以嘛～，不可以！','Mandarin Chinese, with a cute drawn-out first 不可以嘛, followed by a short bouncy 不可以!'),('ja','だぁ〜めぇ〜……だめっ！','Japanese, with a stretched melodic first dame, followed by a short bouncy dame!')]
items=[item for item in items if item[0] in args.languages.split(',')]
def generate(item):
 lang,text,direction=item
 if not args.force and all((root/f'{lang}-{n}.wav').exists() for n in 'abc'):return {'language':lang,'cached':True}
 payload={'instruction':'An original bright cute expressive young adult female anime-style voice speaking natural '+direction+'. Playful mock-scolding with a smiling, lively intonation, not angry. Natural human-like timing, no robotic announcement cadence, no chipmunk effect or breathy whisper. First phrase gently rises and is stretched, with a short pause before the second phrase. Only speak the reference text, no extra words, laughter, music or sound effects. Clean dry studio recording. Do not imitate any named actor or existing character.','reference_text':text,'language':lang,'n':3,'speed':1,'num_step':32,'guidance_scale':2,'instruct_guidance_scale':0,'seed':53}
 req=urllib.request.Request('https://api.fish.audio/v1/voice-design',data=json.dumps(payload).encode(),headers={'Authorization':'Bearer '+key,'Content-Type':'application/json','model':'voice-design-1'})
 try:
  with urllib.request.urlopen(req,timeout=55) as response:result=json.load(response)
 except urllib.error.HTTPError as e:raise RuntimeError(f'{lang}: HTTP {e.code} '+e.read(300).decode(errors='replace').replace(key,'<redacted>'))
 output=[]
 for index,c in enumerate(result.get('candidates',[])):
  raw=cache/f'{lang}-{index}.wav';raw.write_bytes(base64.b64decode(c['audio_base64']))
  dest=root/f'{lang}-{"abc"[index]}.wav'
  subprocess.run(['ffmpeg','-y','-loglevel','error','-i',str(raw),'-ar','24000','-ac','1','-c:a','pcm_s16le',str(dest)],check=True)
  with wave.open(str(dest),'rb') as w:params=w.getparams();samples=array.array('h',w.readframes(w.getnframes()))
  peak=max(abs(x) for x in samples)
  assert peak>0 and params.nframes>0
  samples=array.array('h',(round(x*22000/peak) for x in samples))
  with wave.open(str(dest),'wb') as w:w.setparams(params);w.writeframes(samples.tobytes())
  output.append({'file':dest.name,'seconds':round(params.nframes/params.framerate,3)})
 assert len(output)==3
 return {'language':lang,'text':text,'generator':'Fish Audio voice-design-1','variants':output}
with ThreadPoolExecutor(max_workers=2) as pool:
 for metadata in pool.map(generate,items):print(json.dumps(metadata,ensure_ascii=False),flush=True)
