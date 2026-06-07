# Bash Parameter Expansion — A Practical Guide

Parameter expansion lets you inspect and transform shell variables **inside the
shell itself**, with no call to `sed`, `awk`, `cut`, `basename`, or `dirname`.
Because the work happens inside Bash, you avoid forking a separate process for
every transformation, which makes scripts faster, more portable, and easier to
read.

This guide covers the full set of operators, the subtle rules that trip people
up (the colon, glob-vs-regex, version requirements), and the real-world idioms
worth memorizing.

> **Version note.** Everything here works in Bash 4.0+. Case conversion
> (`^^`, `,,`) needs Bash 4.0; negative substring *length* (`${var:n:-m}`) needs
> Bash 4.2. None of it works in POSIX `sh` or `dash`. If portability to `sh`
> matters, the external tools still have their place — "portable" in this guide
> means "portable across modern Bash."

---

## 1. The Basics

```bash
name="sujan"
echo "$name"      # sujan
echo "${name}"    # sujan — identical
```

The braces become necessary when the variable name butts up against other
characters:

```bash
echo "${name}_backup"   # sujan_backup
echo "$name_backup"     # (empty) — Bash looks for a variable called name_backup
```

**Habit worth forming:** always quote expansions (`"${var}"`) unless you have a
specific reason to want word-splitting. Unquoted expansions split on whitespace
and undergo glob expansion, which is a common source of bugs.

---

## 2. The Colon Rule (read this first)

Most of the conditional operators come in two forms: **with** a colon and
**without** one. The colon is not decoration — it changes *when* the operator
fires.

| Form | Fires when the variable is… |
| ---- | --------------------------- |
| `${var:-x}` (colon) | **unset OR empty** |
| `${var-x}` (no colon) | **unset only** (an empty value is left alone) |

The same distinction applies to `:=` vs `=`, `:?` vs `?`, and `:+` vs `+`.

```bash
empty=""
echo "[${empty:-default}]"   # [default]   — empty counts as "missing"
echo "[${empty-default}]"    # []          — set-but-empty is left alone
```

Use the **colon form** when "" should be treated as missing (the common case).
Use the **no-colon form** when an empty string is a legitimate value you want to
preserve.

---

## 3. Defaults, Assignment, and Guards

### Use a default if unset/empty — `${var:-default}`

Returns the default but does **not** change the variable.

```bash
unset HOSTNAME
echo "${HOSTNAME:-localhost}"   # localhost
```

Instead of:

```bash
if [[ -z "$LOG_DIR" ]]; then
    LOG_DIR="/var/log"
fi
```

write:

```bash
LOG_DIR="${LOG_DIR:-/var/log}"
```

### Assign a default if unset/empty — `${var:=default}`

Like `:-`, but it also **assigns** the value back to the variable.

```bash
unset logfile
echo "${logfile:=/tmp/script.log}"   # /tmp/script.log
echo "$logfile"                       # /tmp/script.log  (now set)
```

> Cannot be used on positional parameters (`$1`, `$@`, etc.) — Bash will error.

### Error out if unset/empty — `${var:?message}`

```bash
echo "${SOURCE_DIR:?SOURCE_DIR not set}"
# bash: SOURCE_DIR: SOURCE_DIR not set
```

In a **script**, this prints the message to stderr and exits with a non-zero
status. In an **interactive shell** it prints the message but does not close
your terminal. If you omit the message, Bash supplies a generic "parameter null
or not set."

The idiomatic guard at the top of a script uses the `:` null command so you can
validate without printing or using the value:

```bash
: "${SOURCE_SHARE:?SOURCE_SHARE not defined}"
: "${DESTINATION_SHARE:?DESTINATION_SHARE not defined}"
```

`:` is a built-in that does nothing and ignores its arguments — its only job
here is to give the expansion somewhere to live. This replaces the verbose:

```bash
if [[ -z "$SOURCE_SHARE" ]]; then
    echo "SOURCE_SHARE not defined" >&2
    exit 1
fi
```

### Use an alternate value if set — `${var:+value}`

The inverse of `:-`. Returns the alternate **only when the variable has a
value**, otherwise nothing.

```bash
DEBUG=yes
echo "${DEBUG:+Debug enabled}"   # Debug enabled

unset DEBUG
echo "${DEBUG:+Debug enabled}"   # (empty)
```

Handy for conditionally adding a flag without an `if`:

```bash
rsync $opts ${VERBOSE:+--verbose} "$src" "$dst"
```

---

## 4. Length

```bash
file="archive.log"
echo "${#file}"          # 11

arr=(a b c d)
echo "${#arr[@]}"        # 4   — number of elements
echo "${#arr[0]}"        # 1   — length of element 0
```

---

## 5. Substrings — `${var:offset}` and `${var:offset:length}`

```bash
str="2025-archive.log"
echo "${str:5}"          # archive.log   — from offset 5 to end
echo "${str:0:4}"        # 2025          — 4 chars from offset 0
```

**Negative offset** counts from the end — but you **must** put a space (or
parentheses) before the minus, or Bash reads it as the `:-` default operator:

```bash
echo "${str: -3}"        # log           — last 3 characters
echo "${str:(-3)}"       # log           — alternative syntax
```

**Negative length** (Bash 4.2+) means "stop this many characters from the end":

```bash
echo "${str:5:-4}"       # archive       — from offset 5, dropping last 4
```

---

## 6. Trimming Patterns — `#`, `##`, `%`, `%%`

These four operators strip a matching pattern from the front or back of a value.

> **Critical:** the pattern is a **shell glob**, not a regex. `*` matches any
> run of characters, `?` matches one character, `[...]` matches a character
> class. `.` is a literal dot. There is no `\d`, no `+`, no anchors.

| Operator | Removes from | Match |
| -------- | ------------ | ----- |
| `${var#pat}`  | front | shortest |
| `${var##pat}` | front | longest |
| `${var%pat}`  | back  | shortest |
| `${var%%pat}` | back  | longest |

Mnemonic: `#` is left of `$` on the keyboard (front), `%` is right (back).

```bash
path="/var/log/messages"
echo "${path#*/}"        # var/log/messages   — strip up to first /
echo "${path##*/}"       # messages           — strip up to last  / (= basename)
echo "${path%/*}"        # /var/log           — strip from last / (= dirname)

file="archive.tar.gz"
echo "${file%.*}"        # archive.tar        — drop shortest .xxx
echo "${file%%.*}"       # archive            — drop everything from first .
```

### Replacing the `basename` / `dirname` external commands

```bash
path="/var/log/messages"
filename="${path##*/}"   # messages   (instead of: basename "$path")
directory="${path%/*}"   # /var/log   (instead of: dirname  "$path")
basefile="${filename%.*}" # messages  (extension stripped)
```

> **Edge cases where the real tools differ:** for a path with no slash,
> `${path%/*}` returns the whole string, whereas `dirname` returns `.`. For a
> trailing slash like `dir/`, the expansions don't normalize the way `basename`
> does. For tidy, predictable paths the expansions are perfect; for arbitrary
> user input, `basename`/`dirname` are safer.

---

## 7. Search and Replace — `/` and `//`

The text to match is, again, a **glob pattern**.

| Operator | Replaces |
| -------- | -------- |
| `${var/old/new}`  | first match |
| `${var//old/new}` | all matches |
| `${var/#old/new}` | only if `old` matches the **start** |
| `${var/%old/new}` | only if `old` matches the **end** |

```bash
file="report.txt"
echo "${file/txt/log}"        # report.log

str="red red red"
echo "${str//red/blue}"       # blue blue blue

# Delete by replacing with nothing
err="error.log"
echo "${err/.log/}"           # error

# Anchored to start / end
path="/tmp/file"
echo "${path/#\/tmp//archive}"  # /archive/file
echo "${file/%txt/log}"         # report.log

# The pattern can be a glob:
p="img001 img002 img003"
echo "${p//img[0-9][0-9][0-9]/X}"   # X X X
```

---

## 8. Case Conversion (Bash 4.0+)

| Operator | Effect |
| -------- | ------ |
| `${var^^}` | whole string to UPPERCASE |
| `${var,,}` | whole string to lowercase |
| `${var^}`  | first character to uppercase |
| `${var,}`  | first character to lowercase |

```bash
host="server01"
echo "${host^^}"   # SERVER01
echo "${host^}"    # Server01

name="SERVER01"
echo "${name,,}"   # server01
echo "${name,}"    # sERVER01
```

You can restrict which characters are affected with a trailing pattern, e.g.
`${var^^[aeiou]}` upper-cases only vowels.

---

## 9. Arrays

```bash
files=(alpha beta gamma)

echo "${#files[@]}"     # 3            — element count
echo "${files[@]}"      # alpha beta gamma
echo "${!files[@]}"     # 0 1 2        — the indices

for f in "${files[@]}"; do
    echo "$f"
done
```

**`[@]` vs `[*]`** matters when quoted: `"${files[@]}"` expands to *separate*
quoted words (almost always what you want for iteration), while `"${files[*]}"`
joins everything into one string using the first character of `IFS`:

```bash
IFS=,; echo "${files[*]}"   # alpha,beta,gamma
```

---

## 10. Indirect Expansion — `${!var}`

When a variable holds the *name* of another variable, `${!var}` dereferences it:

```bash
real="hello"
pointer="real"
echo "${!pointer}"   # hello
```

(`${!prefix@}` and `${!prefix*}` also list all variable names sharing a prefix.)

---

## 11. Performance — Why This Matters

Each of these spawns a child process per call:

```bash
basename "$file"
dirname  "$file"
echo "$x" | sed 's/\.log//'
```

The expansion equivalents run entirely inside the current shell:

```bash
"${file##*/}"
"${file%/*}"
"${file%.log}"
```

In a tight loop over thousands of files, eliminating the fork/exec overhead is
the difference between a script that finishes instantly and one you wait on. The
trade-off is readability — deeply nested expansions can get cryptic, so reach
for the external tool when clarity wins over the microseconds.

---

## 12. Cheat Sheet

| Operation | Example | Description |
| --------- | ------- | ----------- |
| Value | `${var}` | The variable's value |
| Default (unset/empty) | `${var:-x}` | Use `x`, don't assign |
| Default (unset only) | `${var-x}` | Use `x` only if unset |
| Assign default | `${var:=x}` | Use `x` **and** assign it |
| Error if missing | `${var:?msg}` | Print `msg` to stderr, exit |
| Alternate if set | `${var:+x}` | Use `x` only if `var` has a value |
| Length | `${#var}` | Character count |
| Substring | `${var:2:5}` | 5 chars from offset 2 |
| Last N chars | `${var: -3}` | Note the space before `-` |
| Strip front, short | `${var#pat}` | Glob, shortest match |
| Strip front, long | `${var##pat}` | Glob, longest match (basename) |
| Strip back, short | `${var%pat}` | Glob, shortest match |
| Strip back, long | `${var%%pat}` | Glob, longest match |
| Replace first | `${var/a/b}` | First match |
| Replace all | `${var//a/b}` | All matches |
| Replace at start | `${var/#a/b}` | Anchored to front |
| Replace at end | `${var/%a/b}` | Anchored to back |
| Uppercase all | `${var^^}` | Bash 4.0+ |
| Lowercase all | `${var,,}` | Bash 4.0+ |
| Uppercase first | `${var^}` | Bash 4.0+ |
| Indirect | `${!var}` | Dereference name held in `var` |
| Array elements | `${arr[@]}` | All elements (quote it!) |
| Array indices | `${!arr[@]}` | The keys/indices |
| Array length | `${#arr[@]}` | Element count |

---

## 13. The Ones Worth Memorizing

```bash
${VAR:-default}    # fall back to a default
${VAR:?required}   # fail fast if a required var is missing
${#VAR}            # length

${VAR##*/}         # basename
${VAR%/*}          # dirname
${VAR%.*}          # strip extension

${VAR//old/new}    # global replace

${VAR^^}           # uppercase
${VAR,,}           # lowercase
```

These alone replace the bulk of routine `basename`, `dirname`, `cut`, `sed`, and
`awk` usage — and your scripts get faster, cleaner, and easier to maintain.
