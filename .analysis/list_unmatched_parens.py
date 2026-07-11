from pathlib import Path
s=Path('lib/ui/home_screen.dart').read_text(encoding='utf-8')
stack=[]
for i,ch in enumerate(s):
    if ch=='(':
        stack.append(i)
    elif ch==')':
        if stack:
            stack.pop()
        else:
            print('unmatched ) at', i)
if not stack:
    print('no unmatched ( found')
else:
    print('unmatched ( count', len(stack))
    lines=s.splitlines()
    acc=0
    for li,l in enumerate(lines, start=1):
        next_acc=acc+len(l)+1
        # print any stack items in this line
        to_print=[idx for idx in stack if acc<=idx<next_acc]
        for idx in to_print:
            col=idx-acc+1
            print(f'line {li} col {col}: {l}')
        acc=next_acc
