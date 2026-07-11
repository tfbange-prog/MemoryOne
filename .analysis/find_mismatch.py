from pathlib import Path
s = Path('lib/ui/home_screen.dart').read_text(encoding='utf-8')
paren = 0
maxp = 0
maxi = 0
for i, ch in enumerate(s):
    if ch == '(':
        paren += 1
    elif ch == ')':
        paren -= 1
    if paren > maxp:
        maxp = paren
        maxi = i
print('max_depth', maxp, 'index', maxi)
lines = s.splitlines()
acc = 0
for li, l in enumerate(lines, start=1):
    acc += len(l) + 1
    if acc > maxi:
        print('around line', li)
        start = max(1, li - 6)
        end = min(len(lines), li + 6)
        for j in range(start, end + 1):
            print(f"{j:4}: {lines[j-1]}")
        break

# also print final paren counts
print('final_counts', s.count('('), s.count(')'))
