"""Build only public static assets; keep migration exports and credentials private."""
import argparse
import json
import shutil
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
PUBLIC=('index.html','viewer.js','viewer.css','ui.js','map-tools.js','google-api.js','oauth-return.html','oauth-return.js')

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--apps-script-url',default='')
    args=parser.parse_args()
    target=ROOT/'.local/google-site';target.mkdir(parents=True,exist_ok=True)
    for name in PUBLIC:shutil.copy2(ROOT/name,target/name)
    for name in ('assets','map-data/tiles'):shutil.copytree(ROOT/name,target/name,dirs_exist_ok=True)
    shutil.copy2(ROOT/'map-data/province-adjacency.json',target/'map-data/province-adjacency.json')
    config={'backend':'apps-script','appsScriptUrl':args.apps_script_url}
    (target/'app-config.js').write_text('window.FAUXLORE_CONFIG='+json.dumps(config)+';\n',encoding='utf-8')
    upload=ROOT/'.local/google-upload';upload.mkdir(parents=True,exist_ok=True)
    code='\n\n'.join((ROOT/'apps-script'/name).read_text(encoding='utf-8') for name in ('Store.gs','Auth.gs','Map.gs','Code.gs','Setup.gs'))
    (upload/'Code.txt').write_text(code,encoding='utf-8-sig')
    for source,dest in (('Bridge.html','Bridge.txt'),('appsscript.json','Manifest.txt')):
        (upload/dest).write_text((ROOT/'apps-script'/source).read_text(encoding='utf-8'),encoding='utf-8-sig')
    print(json.dumps({'site':str(target),'upload':str(upload),'endpoint_configured':bool(args.apps_script_url)}))

if __name__=='__main__':main()
