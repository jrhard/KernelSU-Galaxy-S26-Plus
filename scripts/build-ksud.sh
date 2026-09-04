#!/usr/bin/env bash
# Compila o ksud (aarch64-linux-android) a partir do fork
# polygraphene/KernelSU@kdp-612, embutindo o kernelsu.ko do S26+ gerado por
# scripts/build-lkm.sh.
#
# Requisitos: Rust (rustup) + Android NDK r29 (ANDROID_NDK_HOME apontando p/ ele).
#
# Variáveis (device/galaxy-s26-plus.env, sobreponíveis por env):
#   KMI, KSU_REPO, KSU_COMMIT, ANDROID_API
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$REPO_ROOT/device/galaxy-s26-plus.env}"
load_env() {
  [ -f "$ENV_FILE" ] || return 0
  while IFS='=' read -r k v; do
    case "$k" in ''|\#*) continue ;; esac
    k="${k%% *}"; v="${v%\"}"; v="${v#\"}"
    [ -z "${!k:-}" ] && export "$k=$v" || true
  done < "$ENV_FILE"
}
load_env

: "${KMI:=android16-6.12}"
: "${KSU_REPO:=https://github.com/polygraphene/KernelSU}"
: "${KSU_COMMIT:=a5531763971cf034e3f630d31654189a148e5f81}"
: "${ANDROID_API:=26}"
: "${ANDROID_NDK_HOME:?defina ANDROID_NDK_HOME apontando para o Android NDK r29}"

TRIPLE="aarch64-linux-android"
WORK="${WORK:-$REPO_ROOT/build}"
KSU_DIR="$WORK/kernelsu"
OUT="${OUT:-$REPO_ROOT/out}"
LKM="${LKM:-$REPO_ROOT/out/lkm/${KMI}_kernelsu.ko}"
mkdir -p "$WORK" "$OUT"

[ -f "$LKM" ] || { echo "ERRO: módulo não encontrado em $LKM. Rode scripts/build-lkm.sh antes."; exit 1; }

# --- fonte do KernelSU no commit fixado -------------------------------------
if [ ! -d "$KSU_DIR/.git" ]; then
  echo "== clonando $KSU_REPO @ $KSU_COMMIT =="
  git clone --filter=blob:none "$KSU_REPO" "$KSU_DIR"
fi
git -C "$KSU_DIR" fetch --depth 1 origin "$KSU_COMMIT" 2>/dev/null || git -C "$KSU_DIR" fetch origin
git -C "$KSU_DIR" checkout -q "$KSU_COMMIT"

BIN_DIR="$KSU_DIR/userspace/ksud/bin/aarch64"
mkdir -p "$BIN_DIR"

# --- toolchain NDK (equivalente ao .github/scripts/setup-rust-build.sh) -----
case "$(uname -s)" in
  Linux)  HOST="linux-x86_64" ;;
  Darwin) HOST="darwin-x86_64" ;;
  *) echo "ERRO: host não suportado por este script (use o CI)."; exit 1 ;;
esac
LLVM="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/$HOST"
CLANG="$LLVM/bin/${TRIPLE}${ANDROID_API}-clang"
[ -x "$CLANG" ] || { echo "ERRO: clang do NDK não encontrado: $CLANG"; exit 1; }

export CC_aarch64_linux_android="$CLANG"
export CXX_aarch64_linux_android="${CLANG}++"
export AR_aarch64_linux_android="$LLVM/bin/llvm-ar"
export CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER="$CLANG"
export BINDGEN_EXTRA_CLANG_ARGS_aarch64_linux_android="--sysroot=$LLVM/sysroot -I$LLVM/sysroot/usr/include/$TRIPLE"

rustup target add "$TRIPLE" >/dev/null 2>&1 || true

cd "$KSU_DIR"

# --- ksuinit (binário embutido para boot-patch; inofensivo no late-load) ----
echo "== build ksuinit =="
cargo build --release --target "$TRIPLE" -p ksuinit
cp "target/$TRIPLE/release/ksuinit" "$BIN_DIR/ksuinit"

# --- embute o módulo do S26+ ------------------------------------------------
cp "$LKM" "$BIN_DIR/${KMI}_kernelsu.ko"
echo "== embutido: $BIN_DIR/${KMI}_kernelsu.ko =="

# rust-embed usa debug-embed; garante recompilação após trocar os assets.
touch userspace/ksud/build.rs

# --- ksud -------------------------------------------------------------------
echo "== build ksud =="
cargo build --release --target "$TRIPLE" -p ksud

cp "target/$TRIPLE/release/ksud" "$OUT/ksud"
echo "== gerado: $OUT/ksud =="
ls -l "$OUT/ksud"
file "$OUT/ksud" 2>/dev/null || true
