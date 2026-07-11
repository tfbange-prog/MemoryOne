from pathlib import Path
s = Path('lib/ui/home_screen.dart').read_text(encoding='utf-8')
stack = []
for i,ch in enumerate(s):
    if ch=='(':
        stack.append(i)
    elif ch==')':
        if stack:
            stack.pop()
        else:
            print('Unmatched ) at', i)
            break
print('unmatched ( count', len(stack))
if stack:
    idx = stack[-1]
    lines = s.splitlines()
    acc = 0
    for li,l in enumerate(lines, start=1):
        acc += len(l)+1
        if acc>idx:
            print('last unmatched ( around line', li)
            start = max(1, li-6)
            end = min(len(lines), li+6)
            for j in range(start, end+1):
                print(f"{j:4}: {lines[j-1]}")
            break
