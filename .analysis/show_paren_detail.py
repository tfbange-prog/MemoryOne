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
    print('index', idx)
    lines = s.splitlines()
    acc = 0
    for li,l in enumerate(lines, start=1):
        if acc + len(l)+1 > idx:
            col = idx - acc + 1
            print('line',li,'col',col)
            print('line content:\n', l)
            print('\ncontext:')
            start_idx = max(0, idx-160)
            end_idx = min(len(s), idx+160)
            context = s[start_idx:end_idx]
            # show with line numbers
            context_lines = context.splitlines()
            base_line = li - (len(context_lines)//2)
            for off, cl in enumerate(context_lines):
                print(f"{base_line+off:5}: {cl}")
            break
