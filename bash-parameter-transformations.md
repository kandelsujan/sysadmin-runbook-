# Bash Parameter Transformation & Expansion Operators

A practical reference for manipulating variables inside `${...}` without spawning external
tools like `sed`, `cut`, `tr`, or `basename`. Everything here is built into bash, so it is
faster and avoids subprocess overhead in loops.

> **Terminology note:** Bash's manual reserves the phrase *"parameter transformation"* for
> the `${parameter@operator}` family (see the last section). In everyday usage people apply
> the term loosely to *all* the `${...}` operators below. This document covers the full set
> and flags which forms require which bash version.

---

## 1. Default values & presence tests

These decide what to expand to based on whether a variable is **unset**, **null** (empty), or
**set**. The colon makes the test treat *null the same as unset*; without the colon, only the
unset case triggers.

| Operator | Behaves when... | Effect |
|---|---|---|
| `${var:-word}` | unset **or** null | expand to `word`, leave `var` unchanged |
| `${var-word}` | unset only | expand to `word`, leave `var` unchanged |
| `${var:=word}` | unset **or** null | **assign** `word` to `var`, then expand |
| `${var=word}` | unset only | **assign** `word` to `var`, then expand |
| `${var:?word}` | unset **or** null | print `word` to stderr and exit (non-interactive) |
| `${var?word}` | unset only | print `word` to stderr and exit |
| `${var:+word}` | set **and** non-null | expand to `word`, else expand to nothing |
| `${var+word}` | set (even if null) | expand to `word`, else expand to nothing |

### Examples

```bash
# :-  Fall back to a default without changing the variable
name=""
echo "${name:-anonymous}"      # -> anonymous   (name is still "")

# :=  Set a default and keep it for the rest of the script
: "${LOG_DIR:=/var/log/myapp}" # assigns if unset/null; the ':' is a no-op command
echo "$LOG_DIR"                # -> /var/log/myapp

# :?  Guard required inputs and fail loudly
deploy() {
  : "${TARGET:?must set TARGET host}"   # aborts the function/script if TARGET missing
  echo "deploying to $TARGET"
}

# :+  Add a flag only when a variable is present
verbose=1
rsync $* ${verbose:+--verbose} src/ dst/   # --verbose appears only if $verbose is set
```

### Use cases
- **Config defaults:** `port="${PORT:-8080}"` lets an env var override a sane default.
- **Required args:** `${1:?usage: backup <file>}` documents and enforces positional args.
- **Conditional flags:** `${DEBUG:+-x}` toggles `set -x`-style behavior cleanly.
- **`-` vs `:-` distinction matters** when an empty string is a *valid, intentional* value
  (e.g. an empty password). Use the no-colon form to respect deliberate emptiness.

---

## 2. Length

| Operator | Result |
|---|---|
| `${#var}` | number of characters in the value |
| `${#array[@]}` | number of elements in an array |
| `${#array[i]}` | length of element `i` |

```bash
word="bash"
echo "${#word}"           # -> 4

files=(a.txt b.txt c.txt)
echo "${#files[@]}"       # -> 3
echo "${#files[1]}"       # -> 5   (length of "b.txt")
```

**Use case:** validate input length without `wc`/`expr`, e.g.
`(( ${#pin} == 4 )) || echo "PIN must be 4 digits"`.

---

## 3. Substring extraction

```bash
${var:offset}
${var:offset:length}
```

- `offset` is zero-based.
- A **negative** offset counts from the end — but you must put a space (or parentheses) before
  the minus so bash doesn't read it as `:-` (the default-value operator).
- A **negative** length means "stop that many characters before the end."

```bash
s="parameter"
echo "${s:0:5}"     # -> param      (5 chars from start)
echo "${s:5}"       # -> eter       (from index 5 to end)
echo "${s: -3}"     # -> ter        (last 3 chars; note the space)
echo "${s: -3:2}"   # -> te
echo "${s:2:-3}"    # -> ramet      (from index 2, drop last 3)

# Works on positional parameters and arrays too
set -- a b c d e
echo "${@:2:3}"     # -> b c d      (slice of the argument list)

arr=(zero one two three)
echo "${arr[@]:1:2}" # -> one two
```

**Use cases:** grab a fixed-width field, take the first N characters of a hash, or slice
`"$@"` to skip a leading subcommand (`cmd="$1"; shift; rest=("${@}")`).

---

## 4. Prefix / suffix removal (pattern matching)

These strip text that matches a **glob pattern** (`*`, `?`, `[...]`) — not a regex — from the
front or back. They are the bash-native replacement for `basename`, `dirname`, and extension
stripping.

| Operator | Removes |
|---|---|
| `${var#pattern}` | **shortest** match from the **start** |
| `${var##pattern}` | **longest** match from the **start** |
| `${var%pattern}` | **shortest** match from the **end** |
| `${var%%pattern}` | **longest** match from the **end** |

Memory aid: on a US keyboard `#` is left of `$` (front) and `%` is right-ish (back).

```bash
path="/home/user/archive.tar.gz"

echo "${path##*/}"      # -> archive.tar.gz   (basename: drop longest leading */)
echo "${path%/*}"       # -> /home/user       (dirname:  drop shortest trailing /*)

echo "${path%.gz}"      # -> /home/user/archive.tar   (strip one extension)
echo "${path%.*}"       # -> /home/user/archive.tar   (drop shortest .* suffix)
echo "${path%%.*}"      # -> /home/user/archive       (drop longest .* suffix)

file="archive.tar.gz"
echo "${file#*.}"       # -> tar.gz   (everything after first dot)
echo "${file##*.}"      # -> gz       (everything after last dot = extension)
```

### Use cases
- **`basename`/`dirname` without forking:** `${p##*/}` and `${p%/*}`.
- **Extension swapping:** `mv "$f" "${f%.png}.jpg"`.
- **Trim a known prefix:** `branch="${ref#refs/heads/}"`.
- **Loop-friendly:** running `basename` 10,000 times in a loop is slow; the `#`/`%` forms cost
  nothing.

---

## 5. Pattern substitution (search & replace)

| Operator | Replaces |
|---|---|
| `${var/pat/repl}` | **first** match anywhere |
| `${var//pat/repl}` | **all** matches |
| `${var/#pat/repl}` | match only if **anchored at start** |
| `${var/%pat/repl}` | match only if **anchored at end** |
| `${var/pat}` | delete first match (no replacement) |
| `${var//pat}` | delete all matches |

`pat` is a glob pattern. Omitting the replacement deletes. In the replacement text, `&` refers
to the matched text (bash 5.2+ requires escaping it as `\&` if you want a literal ampersand).

```bash
s="foo-bar-baz"
echo "${s/-/_}"        # -> foo_bar-baz   (first only)
echo "${s//-/_}"       # -> foo_bar_baz   (all)
echo "${s//-/}"        # -> foobarbaz     (delete all dashes)

csv="a,b,,c"
echo "${csv//,/ }"     # -> a b  c

p="HELLO.txt"
echo "${p/#HELLO/hello}"  # -> hello.txt   (anchored at start)
echo "${p/%txt/md}"       # -> HELLO.md    (anchored at end)

# Glob patterns work
ws="too   many   spaces"
echo "${ws//+([[:space:]])/ }"   # requires: shopt -s extglob
```

### Use cases
- **Sanitize filenames:** `safe="${name// /_}"`.
- **Path translation:** `${path//\//\\}` to swap `/` for `\`.
- **Light templating:** `${template/\{\{name\}\}/$value}`.
- **Trim:** combine with extglob — `${s##+([[:space:]])}` and `${s%%+([[:space:]])}` for a
  pure-bash strip.

---

## 6. Case modification (bash 4.0+)

| Operator | Effect |
|---|---|
| `${var^}` | uppercase the **first** character |
| `${var^^}` | uppercase **all** characters |
| `${var,}` | lowercase the **first** character |
| `${var,,}` | lowercase **all** characters |
| `${var~}` | toggle case of the **first** character |
| `${var~~}` | toggle case of **all** characters |

An optional pattern restricts which characters are affected: `${var^^[aeiou]}` upper-cases only
vowels.

```bash
name="aLiCe"
echo "${name^}"     # -> ALiCe
echo "${name^^}"    # -> ALICE
echo "${name,,}"    # -> alice
echo "${name~~}"    # -> AlIcE

echo "${name^^[aeiou]}"   # -> aLiCE   (only vowels upper-cased)
```

**Use cases:** normalize user input for comparison (`[[ "${ans,,}" == y* ]]`), title-case a
label, or build case-insensitive lookups.

---

## 7. Indirect expansion & name matching

| Operator | Result |
|---|---|
| `${!var}` | value of the variable *named by* `var` (indirection) |
| `${!prefix*}` | names of all set variables starting with `prefix` (one word) |
| `${!prefix@}` | same, but each name is a separate word when quoted |
| `${!array[@]}` | the **keys/indices** of an array (vs. `${array[@]}` for values) |

```bash
# Indirection: dereference a variable whose name is held in another variable
host_prod="prod.example.com"
env="prod"
ref="host_$env"
echo "${!ref}"          # -> prod.example.com

# Enumerate variables by prefix
GIT_AUTHOR="me"; GIT_BRANCH="main"
for v in ${!GIT_*}; do echo "$v=${!v}"; done
# -> GIT_AUTHOR=me
# -> GIT_BRANCH=main

# Array indices (essential for sparse or associative arrays)
declare -A color=([sky]=blue [grass]=green)
echo "${!color[@]}"     # -> sky grass   (keys)
echo "${color[@]}"      # -> blue green  (values)
```

**Use cases:** poor-man's namespacing (`host_$env`), iterating env vars by prefix, and walking
associative-array keys — the only way to get the keys out.

---

## 8. The `${parameter@operator}` transformation operators

This is the family bash officially calls **parameter transformation** (added in 4.4, with more
operators in 5.1). Each applies a named transformation via a single letter.

| Operator | Transformation |
|---|---|
| `${var@Q}` | value **quoted** so it can be safely reused as shell input |
| `${var@E}` | value with backslash escapes **expanded** (like `$'...'`) |
| `${var@P}` | value expanded as a **prompt** string (PS1-style escapes) |
| `${var@A}` | an **assignment statement** that recreates the variable + attributes |
| `${var@K}` | key/value pairs, quoted (assoc arrays; bash 5.1+) |
| `${var@a}` | the variable's **attribute** flags (e.g. `a`, `A`, `r`, `x`) |
| `${var@U}` | value **uppercased** (bash 5.1+) |
| `${var@u}` | value with first char uppercased (bash 5.1+) |
| `${var@L}` | value **lowercased** (bash 5.1+) |

```bash
# @Q  — safe re-quoting; survives eval and "set -x"-style logging
msg="it's a; rm -rf /"
echo "${msg@Q}"          # -> 'it'\''s a; rm -rf /'
eval "echo ${msg@Q}"     # safely prints the literal string, no command injection

# @E  — interpret escape sequences stored in a plain variable
raw='line1\nline2\ttabbed'
printf '%s\n' "${raw@E}"
# -> line1
# -> line2   tabbed

# @P  — render prompt escapes (\u user, \h host, \w cwd, \d date ...)
banner='\u@\h:\w'
echo "${banner@P}"       # -> alice@laptop:/home/alice

# @A  — serialize a variable for later restoration / debugging
declare -i count=42
echo "${count@A}"        # -> declare -i count=42

# @a  — inspect attributes
declare -r PI=3.14
echo "${PI@a}"           # -> r   (read-only)
```

### Use cases
- **`@Q` is the big one:** safely log commands, pass strings through `eval`/`ssh`/`xargs`, or
  generate reproducible command lines without injection risk. Prefer it over hand-rolled
  quoting.
- **`@E`** decodes escape sequences read from a config file or `$'...'` without `echo -e`
  portability headaches.
- **`@P`** lets scripts reuse PS1-style formatting for status banners.
- **`@A`/`@K`** snapshot variables (including arrays and their attributes) to a file you can
  `source` later — handy for caching computed state.
- **`@a`** lets a script branch on whether a variable is read-only, exported, an array, etc.

---

## Quick gotchas

- These operators work on **glob patterns**, not regex. `*`, `?`, `[...]`, and (with
  `shopt -s extglob`) `+(...)`, `@(...)`, `!(...)` — but never `.*` or `\d`.
- **Always quote the expansion** (`"${var//x/y}"`) to prevent word-splitting and glob
  re-expansion of the *result*.
- Negative substring offsets need a leading space: `${s: -3}`, not `${s:-3}` (the latter is the
  default-value operator).
- Case and `@U/@u/@L` operators are **bash-only** (not POSIX `sh`) and version-gated. Check with
  `bash --version` if you target older systems; macOS ships bash 3.2 by default.
- `${var:=word}` cannot assign to positional parameters (`$1`, `$2`, ...) — use `:-` there.
