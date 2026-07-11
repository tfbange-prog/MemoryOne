from pathlib import Path
s=Path('lib/ui/home_screen.dart').read_text(encoding='utf-8')
idx=34671
lines=s.splitlines()
acc=0
for li,l in enumerate(lines, start=1):
    if acc+len(l)+1>idx:
        col=idx-acc+1
        print(li,col)
        print(l)
        break
