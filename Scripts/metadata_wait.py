#!/usr/bin/env python3
"""Wait only by repeating the existing read-only, fail-closed metadata verifier.

No verifier result is rewritten, cached as success, or bypassed. Feature-off is
exactly one invocation. A bounded wait expiration remains a failed check.
"""
import argparse
import os
import subprocess
import sys
import time


def enabled_for(env):
    return env.get('INNO_JOB_CANCELLATION', '').lower() in ('', 'enabled') and env.get('GITHUB_EVENT_NAME') == 'pull_request'


def run(command,enabled=True,timeout=21000,interval=30,invoke=subprocess.run,clock=time.monotonic,sleep=time.sleep):
    if not command or timeout<0 or interval<=0:raise ValueError('bounded command and positive interval required')
    deadline=clock()+timeout
    while True:
        result=invoke(command,check=False)
        if result.returncode==0 or not enabled:return result.returncode
        if result.returncode<0:return result.returncode
        remaining=deadline-clock()
        if remaining<=0:return result.returncode
        print('Metadata proof is not yet valid; retrying the unchanged authoritative verifier.',file=sys.stderr)
        sleep(min(interval,remaining))


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('command',nargs=argparse.REMAINDER);args=parser.parse_args()
    command=args.command[1:] if args.command and args.command[0]=='--' else args.command
    enabled=enabled_for(os.environ)
    sys.exit(run(command,enabled))
if __name__=='__main__':main()
