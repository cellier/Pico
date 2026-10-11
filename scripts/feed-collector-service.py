#!/usr/bin/env python3
"""Install/manage the local read-only Feed collector. Does not run AI or publish cards."""
import argparse
import os
import plistlib
import subprocess
from pathlib import Path

LABEL='com.telos.feed-collector'

def configuration(app,data):
    info=plistlib.loads((app/'Contents/Info.plist').read_bytes())
    resources=app/'Contents/Resources'
    interpreter=Path(info['TelosPython'])
    if not interpreter.is_absolute():interpreter=resources/interpreter
    script=resources/'Backend/feed_collection.py'
    if not interpreter.is_file() or not script.is_file():raise ValueError('Build Telos with the collector first')
    return {'Label':LABEL,'ProgramArguments':[str(interpreter),'-B','-u',str(script),'--data',str(data)],
            'RunAtLoad':True,'StartInterval':900,'ProcessType':'Background',
            'StandardOutPath':str(data/'feed-collector.log'),'StandardErrorPath':str(data/'feed-collector.log'),
            'EnvironmentVariables':{'PYTHONDONTWRITEBYTECODE':'1'}}

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action',choices=['install','uninstall','status'])
    parser.add_argument('--app',type=Path,default=Path(__file__).resolve().parents[1]/'build/Telos.app')
    parser.add_argument('--data',type=Path,default=Path.home()/'Library/Application Support/Telos')
    parser.add_argument('--dry-run',action='store_true');args=parser.parse_args()
    target=Path.home()/'Library/LaunchAgents'/f'{LABEL}.plist'
    domain=f'gui/{os.getuid()}'
    if args.action=='status':
        result=subprocess.run(['launchctl','print',domain+'/'+LABEL],capture_output=True,text=True)
        print('Collector loaded' if result.returncode==0 else 'Collector not loaded');return
    if args.action=='install':
        config=configuration(args.app.resolve(),args.data.resolve())
        if args.dry_run:print(plistlib.dumps(config).decode());return
        args.data.mkdir(parents=True,exist_ok=True)
        log=args.data/'feed-collector.log';log.touch(exist_ok=True);log.chmod(0o600)
        target.parent.mkdir(parents=True,exist_ok=True)
        temp=target.with_suffix('.tmp');temp.write_bytes(plistlib.dumps(config));temp.chmod(0o600);temp.replace(target)
        subprocess.run(['launchctl','bootout',domain+'/'+LABEL],capture_output=True)
        subprocess.run(['launchctl','bootstrap',domain,str(target)],check=True)
        print('Collector enabled: sources checked hourly, failures retried with backoff; no AI requests or notifications while the app is closed.')
    else:
        if args.dry_run:print('Would unload '+LABEL);return
        subprocess.run(['launchctl','bootout',domain+'/'+LABEL],capture_output=True)
        target.unlink(missing_ok=True)
        print('Collector disabled; saved candidates and feed history remain available.')

if __name__=='__main__':main()
