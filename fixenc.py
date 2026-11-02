import io

p = 'src/SessionRecovery.psm1'
s = io.open(p, encoding='utf-8', newline='').read()
eol = '\r\n' if '\r\n' in s else '\n'

old = """    # Deliberately conservative: the marker must sit at an edge of the title
    # next to real text. "5 * 3 - Calculator" stays clean, and a title made
    # only of markers does not count.
    param([string]$Title)
    if ([string]::IsNullOrWhiteSpace($Title)) { return $false }
    $t = $Title.Trim()
    if ($t.Length -lt 2) { return $false }
    # Leading marker followed by text that is not another marker.
    if ($t -match '^[*\u25cf\u2022][^\\s*\u25cf\u2022]') { return $true }
    # Leading marker, a space, then text ("\u25cf main.ts - ...").
    if ($t -match '^[*\u25cf\u2022]\\s+[^\\s*\u25cf\u2022]') { return $true }
    # Trailing marker right after text ("draft.txt*" / "draft.txt [*]").
    if ($t -match '[^\\s*\u25cf\u2022]\\s*\\[\\+\\]$') { return $true }
    # vim puts its dirty marker right after the buffer name, mid-title
    # ("main.c [+] - VIM"), standing alone as a token.
    if ($t -match '(?:^|\\s)\\[\\+\\](?:\\s|$)') { return $true }
    if ($t -match '[^\\s*\u25cf\u2022][*\u25cf\u2022]$') { return $true }
    return $false"""

new_marked = [
    "    # Deliberately conservative: the marker must sit at an edge of the title",
    "    # next to real text. \"5 * 3 - Calculator\" stays clean, and a title made",
    "    # only of markers does not count.",
    "    #",
    "    # The bullet characters are built from code points instead of being typed",
    "    # literally. This file has no BOM, and Windows PowerShell 5.1 decodes it",
    "    # as ANSI, so a literal bullet in a regex silently became the wrong",
    "    # character on CI while passing on a machine that read it as UTF-8.",
    "    param([string]$Title)",
    "    if ([string]::IsNullOrWhiteSpace($Title)) { return $false }",
    "    $t = $Title.Trim()",
    "    if ($t.Length -lt 2) { return $false }",
    "    $markers = [string]@([char]0x002A, [char]0x25CF, [char]0x2022) -join ''",
    "    # Leading marker followed by text that is not another marker.",
    "    if ($t -match ('^[' + $markers + '][^\\s' + $markers + ']')) { return $true }",
    "    # Leading marker, a space, then text (\"<bullet> main.ts - ...\").",
    "    if ($t -match ('^[' + $markers + ']\\s+[^\\s' + $markers + ']')) { return $true }",
    "    # Trailing marker right after text (\"draft.txt*\" / \"draft.txt [*]\").",
    "    if ($t -match ('[^\\s' + $markers + ']\\s*\\[\\+\\]$')) { return $true }",
    "    # vim puts its dirty marker right after the buffer name, mid-title",
    "    # (\"main.c [+] - VIM\"), standing alone as a token.",
    "    if ($t -match '(?:^|\\s)\\[\\+\\](?:\\s|$)') { return $true }",
    "    if ($t -match ('[^\\s' + $markers + '][*' + $markers + ']$')) { return $true }",
    "    return $false",
]

count = s.count(old.replace('\\u25cf', '\u25cf').replace('\\u2022', '\u2022'))
print("literal-block matches:", count)

# Rebuild the search text with the real characters, matching the file.
real_old = old.replace('\\u25cf', '\u25cf').replace('\\u2022', '\u2022')
if count != 1:
    raise SystemExit("could not locate block exactly once")

s = s.replace(real_old, eol.join(new_marked), 1)
io.open(p, 'w', encoding='utf-8', newline='').write(s)
print("rewritten")
