#!/bin/sh
# If not running under bash, re-exec under bash. The script uses bashisms
# ([[ ]], ${BASH_SOURCE[0]}, < <(…), local arrays) that POSIX sh doesn't support.
# This guard makes the script work no matter how it's invoked:
#   bash install.sh        — direct, no re-exec
#   sh install.sh          — re-exec under bash (Debian /bin/sh = dash)
#   dash install.sh        — re-exec under bash
#   ./install.sh           — uses shebang #!/bin/sh, re-exec under bash
#   curl … | bash -s --    — already bash, no re-exec
if [ -z "${BASH_VERSION:-}" ]; then
    if command -v bash >/dev/null 2>&1; then
        exec bash "$0" "$@"
    else
        echo "ERROR: bash is required (current shell: $0)" >&2
        exit 1
    fi
fi
# From here on, we are definitely under bash.
set -euo pipefail

# ============================================================================
#  Installs Rust nightly locally (without rustup-init), plus wasm-pack,
#  wasm-tools, and wasm-bindgen binaries.
#
#  Layout (all next to this script):
#    ./install.sh                 this script
#    ./rustup/                    final install (rustup, cargo, toolchains)
#      ./env.sh                   source this to activate the toolchain
#      ./cargo/bin/               cargo, rustc, rustup, wasm-pack, wasm-tools,
#                                 wasm-bindgen
#      ./rustup/toolchains/       nightly toolchain + wasm32 std
#      ./shims/rustup             rustup shim (v1-manifest bypass)
#    ./.rust-install/             work dir — archives cached here, staging
#                                 subdirs are removed at the end
#
#  After install:
#    source ./rustup/env.sh
#    rustc --version
#    bun run tools ast.ts -- release/native/c2/main.rt
#
#  Requirements: bash 4+, curl, tar (with xz support).
# ============================================================================

# Global start time — used for the final "Xs total" line.
START_TIME=$SECONDS

# step_start / step_end print "[install] step-name ... 5s" for each phase.
# Keeps the log scannable: you see which step dominates.
STEP_START=0
step_start() { STEP_START=$SECONDS; log "$*"; }
step_end()   {
    local elapsed=$((SECONDS - STEP_START))
    local total=$((SECONDS - START_TIME))
    log "$* done (${elapsed}s, total ${total}s)"
    echo
}

# ---- archives (all .tar.xz, ~1MB peak RAM to extract via tar -xJf) ---------
# rustup.tar.xz         — 15 shim copies of rustup-init (cargo, rustc, ...) + rustup home dir
# rust-nightly-*.tar.xz — official rust-lang.org nightly toolchain (rustc, cargo, std, clippy, ...)
# rust-std-*.tar.xz     — wasm32-unknown-unknown std
# wasm-tools.tar.xz     — prebuilt wasm-pack + wasm-tools binaries
# wasm-bindgen.tar.xz   — prebuilt wasm-bindgen 0.2.125 (matches rts Cargo.lock)
RUSTUP_URL="https://github.com/miruji/rust-nightly/releases/download/0.1.0/rustup.tar.xz"
RUSTUP_SHA="dc10f05760fd31cfc27543312d6e6457339d116d0dd4f6a3e92bb75baeb8fff1"

TOOLCHAIN_URL="https://github.com/miruji/rust-nightly/releases/download/0.1.0/rust-nightly-x86_64-unknown-linux-gnu.tar.xz"
TOOLCHAIN_SHA="71329fa3ddbf09b23a061b17598a0c1d59a30637b2cd7834c0f3430a96c5f517"

WASM_STD_URL="https://github.com/miruji/rust-nightly/releases/download/0.1.0/rust-std-nightly-wasm32-unknown-unknown.tar.xz"
WASM_STD_SHA="a3e6ff9b876470c911734ffde50b544651f958147916cc02f91bc11ee84eeca8"

WASM_TOOLS_URL="https://github.com/miruji/rust-nightly/releases/download/0.1.0/wasm-tools.tar.xz"
WASM_TOOLS_SHA="a1a62e0aed14c7de8f1cbe92e76a220c7b7c1d73bafe8f12fa46626edf3fe061"

WASM_BINDGEN_URL="https://github.com/miruji/rust-nightly/releases/download/0.1.0/wasm-bindgen.tar.xz"
WASM_BINDGEN_SHA="7b0c09516c8a4147c43042ffa69f7f0d4f74dd1250910970f6f664bab9576286"

# Both dirs resolve relative to the script's location, not $PWD — so
# `curl ... | bash` and `bash ./install.sh` behave the same.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="$SCRIPT_DIR/rustup"
WORK_DIR="$SCRIPT_DIR/.rust-install"

# ---- helpers ---------------------------------------------------------------
log()  { printf '\033[1;34m[install]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[install] WARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[install] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

sha256_check() {
    local file="$1" expected="$2" actual
    actual="$(sha256sum "$file" | awk '{print $1}')"
    [[ "$actual" == "$expected" ]] || die "sha256 mismatch for $(basename "$file"):
  expected: $expected
  actual:   $actual"
}

# Resumable + sha256-checked download. Cached: existing file that passes sha256
# is reused as-is.
download() {
    local url="$1" dest="$2" expected_sha="${3:-}"
    if [[ -f "$dest" ]]; then
        log "cached: $(basename "$dest")"
    else
        log "downloading: $(basename "$dest")"
        curl -L -C - --fail -o "$dest.tmp" "$url"
        mv "$dest.tmp" "$dest"
    fi
    if [[ -n "$expected_sha" ]]; then
        sha256_check "$dest" "$expected_sha"
    fi
}

# Returns 0 if binaries can actually be executed from <dir>, 1 otherwise.
# NOT just `[[ -x ]]` — that test passes on FUSE/object-storage mounts even
# when execution is denied. Only reliable check: write a script, chmod +x,
# try to run it.
is_exec_capable_dir() {
    local dir="$1" probe
    [[ -d "$dir" ]] || return 1
    probe="$(mktemp "$dir/.exec-probe.XXXXXX.sh" 2>/dev/null)" || return 1
    printf '#!/usr/bin/env bash\nexit 0\n' > "$probe"
    chmod +x "$probe" 2>/dev/null || { rm -f "$probe"; return 1; }
    [[ -x "$probe" ]] || { rm -f "$probe"; return 1; }
    "$probe" >/dev/null 2>&1 || { rm -f "$probe"; return 1; }
    rm -f "$probe"
    return 0
}

# Runs the rust-installer's bundled install.sh. Tries direct exec first;
# falls back to `bash install.sh` if the exec bit was dropped (FUSE).
run_bundled_installer() {
    local staging="$1"; shift
    local installer="$staging/install.sh"
    [[ -f "$installer" ]] || die "bundled install.sh not found at $installer"
    chmod +x "$installer" 2>/dev/null || true
    local rc=0
    "$installer" "$@" || rc=$?
    if [[ $rc -eq 0 ]]; then
        return 0
    fi
    warn "direct exec of bundled install.sh failed (rc=$rc), retrying via 'bash install.sh'"
    bash "$installer" "$@"
}

# ============================================================================
log "rust-nightly installer"
log "  target dir : $TARGET_DIR"
log "  work dir   : $WORK_DIR  (cached downloads + staging)"
mkdir -p "$WORK_DIR"

# Upfront check: if the script's own dir is on a non-exec FS (FUSE/noexec),
# fail fast with a clear message instead of failing mid-download.
if ! is_exec_capable_dir "$SCRIPT_DIR"; then
    die "install.sh is located in '$SCRIPT_DIR', which is on a filesystem that
does not support execution (noexec mount, or FUSE that drops the exec bit —
e.g. grok-files, certain ossfs configs).

The installer cannot proceed: the bundled rust-installer and the final
rustc/cargo/rustup binaries all need to be executable from here.

Fix: move install.sh to a directory on a normal filesystem and re-run:
    cp install.sh /tmp/ && cd /tmp && bash install.sh"
fi
echo

# ---- 1. download all 5 archives -------------------------------------------
step_start "downloading archives (5 tar.xz files total)"
download "$RUSTUP_URL"      "$WORK_DIR/rustup.tar.xz"                                  "$RUSTUP_SHA"
download "$TOOLCHAIN_URL"   "$WORK_DIR/rust-nightly-x86_64-unknown-linux-gnu.tar.xz"   "$TOOLCHAIN_SHA"
download "$WASM_STD_URL"    "$WORK_DIR/rust-std-nightly-wasm32-unknown-unknown.tar.xz" "$WASM_STD_SHA"
download "$WASM_TOOLS_URL"  "$WORK_DIR/wasm-tools.tar.xz"                              "$WASM_TOOLS_SHA"
download "$WASM_BINDGEN_URL" "$WORK_DIR/wasm-bindgen.tar.xz"                            "$WASM_BINDGEN_SHA"
step_end "downloads"

# ---- 2. extract rustup.tar.xz  →  $TARGET_DIR/{cargo,rustup}/ --------------
step_start "extracting rustup.tar.xz"
mkdir -p "$TARGET_DIR"
rm -rf "$WORK_DIR/rustup-extract"
mkdir -p "$WORK_DIR/rustup-extract"
tar -xJf "$WORK_DIR/rustup.tar.xz" -C "$WORK_DIR/rustup-extract"

# Archive top-level is "rust/" with subdirs cargo/ and rustup/.
RUSTUP_TOP="$WORK_DIR/rustup-extract"
[[ -d "$WORK_DIR/rustup-extract/rust" ]] && RUSTUP_TOP="$WORK_DIR/rustup-extract/rust"
for sub in cargo rustup; do
    if [[ -d "$RUSTUP_TOP/$sub" ]]; then
        rm -rf "$TARGET_DIR/$sub"
        mv "$RUSTUP_TOP/$sub" "$TARGET_DIR/$sub"
    fi
done
rm -rf "$WORK_DIR/rustup-extract"
step_end "rustup dir: $TARGET_DIR"

# ---- 3. install x86_64 toolchain (rustc, cargo, std, clippy, ...) ----------
step_start "extracting rust-nightly-x86_64-unknown-linux-gnu.tar.xz"
rm -rf "$WORK_DIR/tc-staging"
mkdir -p "$WORK_DIR/tc-staging"
tar -xJf "$WORK_DIR/rust-nightly-x86_64-unknown-linux-gnu.tar.xz" -C "$WORK_DIR/tc-staging"

STAGING="$WORK_DIR/tc-staging/rust-nightly-x86_64-unknown-linux-gnu"
[[ -f "$STAGING/install.sh" ]] || die "install.sh not found in toolchain archive"

TC_DIR="$TARGET_DIR/rustup/toolchains/nightly-x86_64-unknown-linux-gnu"
mkdir -p "$TC_DIR"

log "installing toolchain via bundled install.sh (skipping rust-docs)"
run_bundled_installer "$STAGING" \
    --prefix="$TC_DIR" \
    --disable-ldconfig \
    --without=rust-docs,rust-docs-json-preview > /dev/null
rm -rf "$WORK_DIR/tc-staging"

# Smoke-test rustc. Distinguish "missing" from "non-executable" in the error.
if [[ ! -x "$TC_DIR/bin/rustc" ]]; then
    if [[ -f "$TC_DIR/bin/rustc" ]]; then
        die "rustc was installed to $TC_DIR/bin/rustc but is not executable.
TARGET_DIR is likely on a filesystem that does not preserve the exec bit.
Move install.sh to a normal filesystem and re-run."
    fi
    die "rustc missing after install at $TC_DIR/bin/rustc"
fi
"$TC_DIR/bin/rustc" --version >/dev/null 2>&1 || \
    die "rustc binary exists and is marked executable, but cannot be run.
TARGET_DIR '$TARGET_DIR' is likely on a noexec mount.
Move install.sh to a normal filesystem and re-run."
step_end "toolchain at: $TC_DIR"

# ---- 4. install wasm32-unknown-unknown std (same toolchain) ---------------
step_start "extracting rust-std-nightly-wasm32-unknown-unknown.tar.xz"
rm -rf "$WORK_DIR/wasm-staging"
mkdir -p "$WORK_DIR/wasm-staging"
tar -xJf "$WORK_DIR/rust-std-nightly-wasm32-unknown-unknown.tar.xz" -C "$WORK_DIR/wasm-staging"

WASM_STAGING="$WORK_DIR/wasm-staging/rust-std-nightly-wasm32-unknown-unknown"
[[ -f "$WASM_STAGING/install.sh" ]] || die "install.sh not found in wasm-std archive"

log "installing wasm32-unknown-unknown std via bundled install.sh"
run_bundled_installer "$WASM_STAGING" \
    --prefix="$TC_DIR" \
    --disable-ldconfig > /dev/null
rm -rf "$WORK_DIR/wasm-staging"
[[ -d "$TC_DIR/lib/rustlib/wasm32-unknown-unknown" ]] || die "wasm32 std not installed"
step_end "wasm32-std at: $TC_DIR/lib/rustlib/wasm32-unknown-unknown"

# ---- 5. install wasm-pack + wasm-tools binaries ---------------------------
# wasm-tools.tar.xz contains two prebuilt binaries: wasm-pack + wasm-tools.
# Both are placed in cargo/bin (where PATH points after `source env.sh`).
step_start "extracting wasm-tools.tar.xz"
rm -rf "$WORK_DIR/wasm-tools-extract"
mkdir -p "$WORK_DIR/wasm-tools-extract"
tar -xJf "$WORK_DIR/wasm-tools.tar.xz" -C "$WORK_DIR/wasm-tools-extract"

# Search one level deep — the archive may or may not have a top-level dir.
CARGO_BIN="$TARGET_DIR/cargo/bin"
mkdir -p "$CARGO_BIN"
for bin_name in wasm-pack wasm-tools; do
    src=""
    if [[ -f "$WORK_DIR/wasm-tools-extract/$bin_name" ]]; then
        src="$WORK_DIR/wasm-tools-extract/$bin_name"
    else
        while IFS= read -r -d '' f; do
            src="$f"; break
        done < <(find "$WORK_DIR/wasm-tools-extract" -maxdepth 2 -type f -name "$bin_name" -print0 2>/dev/null)
    fi
    if [[ -n "$src" && -f "$src" ]]; then
        rm -f "$CARGO_BIN/$bin_name"
        mv "$src" "$CARGO_BIN/$bin_name"
        chmod +x "$CARGO_BIN/$bin_name" 2>/dev/null || warn "could not set +x on $bin_name"
        log "  installed: $bin_name"
    else
        warn "  not found in archive: $bin_name"
    fi
done
rm -rf "$WORK_DIR/wasm-tools-extract"
step_end "wasm-pack + wasm-tools"

# ---- 6. install wasm-bindgen binary ---------------------------------------
# wasm-bindgen 0.2.125 (matches rts Cargo.lock). Without this, `wasm-pack build`
# falls back to `cargo install wasm-bindgen-cli` and compiles walrus/ureq/clap
# from source (~5min, needs network). With this binary on PATH, wasm-pack finds
# it immediately and skips the install step.
step_start "extracting wasm-bindgen.tar.xz"
rm -rf "$WORK_DIR/wasm-bindgen-extract"
mkdir -p "$WORK_DIR/wasm-bindgen-extract"
tar -xJf "$WORK_DIR/wasm-bindgen.tar.xz" -C "$WORK_DIR/wasm-bindgen-extract"

# Find the wasm-bindgen binary (archive may have a top-level dir like
# wasm-bindgen-0.2.125/).
bin_name="wasm-bindgen"
src=""
if [[ -f "$WORK_DIR/wasm-bindgen-extract/$bin_name" ]]; then
    src="$WORK_DIR/wasm-bindgen-extract/$bin_name"
else
    while IFS= read -r -d '' f; do
        src="$f"; break
    done < <(find "$WORK_DIR/wasm-bindgen-extract" -maxdepth 2 -type f -name "$bin_name" -print0 2>/dev/null)
fi
if [[ -n "$src" && -f "$src" ]]; then
    rm -f "$CARGO_BIN/$bin_name"
    mv "$src" "$CARGO_BIN/$bin_name"
    chmod +x "$CARGO_BIN/$bin_name" 2>/dev/null || warn "could not set +x on $bin_name"
    log "  installed: $bin_name"
else
    die "wasm-bindgen binary not found in wasm-bindgen.tar.xz"
fi
rm -rf "$WORK_DIR/wasm-bindgen-extract"
step_end "wasm-bindgen"

# ---- 7. write env.sh -------------------------------------------------------
step_start "writing env.sh + rustup shim"
cat > "$TARGET_DIR/env.sh" <<EOF
# Source this to enable the rust-nightly toolchain.
#   source $TARGET_DIR/env.sh
export CARGO_HOME="$TARGET_DIR/cargo"
export RUSTUP_HOME="$TARGET_DIR/rustup"
export PATH="\$CARGO_HOME/bin:\$PATH"
rustc --version >/dev/null 2>&1 && echo "[env] rustc \$(rustc --version)"
EOF
chmod +x "$TARGET_DIR/env.sh" 2>/dev/null || warn "could not set exec bit on env.sh — use 'source' instead of './'"

# rust-installer writes v1 (legacy) manifests. Real rustup refuses to list or
# add targets on v1 toolchains:
#     error: toolchain does not support components (v1 manifest)
# This breaks `rustup target list --installed` and `rustup target add <T>`,
# which rts's tools/build.ts uses to detect wasm32. Workaround: a shim that
# intercepts these subcommands and reads the disk.
REAL_RUSTUP="$TARGET_DIR/cargo/bin/rustup"
SHIM_DIR="$TARGET_DIR/shims"
mkdir -p "$SHIM_DIR"

cat > "$SHIM_DIR/rustup" <<EOF
#!/usr/bin/env bash
# rustup shim — handles v1-manifest toolchains.
REAL_RUSTUP="$REAL_RUSTUP"
TC_DIR="\$RUSTUP_HOME/toolchains/nightly-x86_64-unknown-linux-gnu"

if [[ "\$1" == "target" && "\$2" == "list" && "\${3:-}" == "--installed" ]]; then
    [[ -d "\$TC_DIR/lib/rustlib/x86_64-unknown-linux-gnu/lib" ]] && echo "x86_64-unknown-linux-gnu"
    [[ -d "\$TC_DIR/lib/rustlib/wasm32-unknown-unknown/lib" ]] && echo "wasm32-unknown-unknown"
    exit 0
fi

if [[ "\$1" == "target" && "\$2" == "list" && -z "\${3:-}" ]]; then
    "\$REAL_RUSTUP" target list 2>/dev/null | sed \\
        -e 's|^wasm32-unknown-unknown .*|wasm32-unknown-unknown (installed)|' \\
        -e 's|^x86_64-unknown-linux-gnu .*|x86_64-unknown-linux-gnu (installed)|'
    exit 0
fi

if [[ "\$1" == "target" && "\$2" == "add" ]]; then
    target="\${3:-}"
    if [[ -d "\$TC_DIR/lib/rustlib/\$target/lib" ]]; then
        echo "info: component 'rust-std-\$target' for target '\$target' is up to date"
        exit 0
    fi
fi

exec "\$REAL_RUSTUP" "\$@"
EOF

chmod +x "$SHIM_DIR/rustup" 2>/dev/null || warn "could not set exec bit on rustup shim"

# Put shims first in PATH so the shim wins over the real rustup.
cat >> "$TARGET_DIR/env.sh" <<EOF
export PATH="$SHIM_DIR:\$PATH"
EOF
step_end "env.sh + shim"

# ---- 8. cleanup staging (keep cached archives) ----------------------------
log "cleanup staging (cached archives kept in $WORK_DIR)"
echo

# ---- 9. final summary -----------------------------------------------------
TOTAL=$((SECONDS - START_TIME))
TERM_WIDTH=$(tput cols 2>/dev/null || echo 80)
LINE=$(printf '%*s' "$TERM_WIDTH" '' | tr ' ' '─')

echo "$LINE"
echo "Installation complete."
echo
echo "Total time: ${TOTAL}s"
echo
echo "Activate:"
echo "  source $TARGET_DIR/env.sh"
echo
echo "Verify:"
echo "  rustc --version"
echo "  cargo --version"
echo "  rustup target list --installed"
echo "  wasm-pack --version"
echo "  wasm-tools --version"
echo "  wasm-bindgen --version"
echo
echo "Uninstall:"
echo "  rm -rf $TARGET_DIR $WORK_DIR"
echo "$LINE"
