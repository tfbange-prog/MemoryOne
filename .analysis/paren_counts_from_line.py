from pathlib import Path
lines=Path('lib/ui/home_screen.dart').read_text(encoding='utf-8').splitlines()
start_line=1006
paren=0
for i in range(start_line-1, len(lines)):
    line=lines[i]
    for ch in line:
        if ch=='(': paren+=1
        elif ch==')': paren-=1
    print(f'{i+1:4}: {paren:3} {line}')
    # stop early if paren returns to 0 after start
    if i>start_line-1 and paren==0:
        print('paren returned to 0 at line', i+1)
        break
