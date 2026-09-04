#!/usr/bin/env bash
# Builda o APK do KernelSU Manager a partir do MESMO commit do fork usado no
# modulo e no ksud.
#
# Motivo: manager, driver e ksud derivam a versao da mesma formula
# (30000 + `git rev-list --count HEAD`). Se o manager vier de outra arvore, o
# app mostra "Manager version (X) and KernelSU driver version (Y) mismatch".
# Buildando do commit fixado, os tres batem por construcao.
#
# Requisitos: JDK 21, Android SDK, e o binario ksud ja compilado.
#
# Variaveis:
#   KSUD_BIN            binario ksud (default: out/ksud)
#   KEYSTORE            caminho do .jks usado para assinar (OBRIGATORIO)
#   KEYSTORE_PASSWORD / KEY_ALIAS / KEY_PASSWORD   (OBRIGATORIOS)
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

: "${KSU_REPO:=https://github.com/polygraphene/KernelSU}"
: "${KSU_COMMIT:=a5531763971cf034e3f630d31654189a148e5f81}"
: "${KEYSTORE:?defina KEYSTORE (caminho do .jks)}"
: "${KEYSTORE_PASSWORD:?defina KEYSTORE_PASSWORD}"
: "${KEY_ALIAS:?defina KEY_ALIAS}"
: "${KEY_PASSWORD:?defina KEY_PASSWORD}"

WORK="${WORK:-$REPO_ROOT/build}"
KSU_DIR="$WORK/kernelsu"
OUT="${OUT:-$REPO_ROOT/out}"
KSUD_BIN="${KSUD_BIN:-$OUT/ksud}"
mkdir -p "$WORK" "$OUT"

[ -f "$KSUD_BIN" ] || { echo "ERRO: ksud nao encontrado em $KSUD_BIN"; exit 1; }

# --- fonte no commit fixado (historico COMPLETO: a versao vem do rev-list) ---
if [ ! -d "$KSU_DIR/.git" ]; then
  echo "== clonando $KSU_REPO @ $KSU_COMMIT =="
  git clone --filter=blob:none "$KSU_REPO" "$KSU_DIR"
fi
git -C "$KSU_DIR" fetch origin 2>/dev/null || true
git -C "$KSU_DIR" checkout -q "$KSU_COMMIT"

COUNT="$(git -C "$KSU_DIR" rev-list --count HEAD)"
EXPECTED_VC=$((30000 + COUNT))
echo "== commits: $COUNT  ->  versionCode esperado: $EXPECTED_VC =="
if [ "$COUNT" -lt 100 ]; then
  echo "ERRO: contagem de commits suspeita ($COUNT). O clone precisa de historico"
  echo "      completo, senao o versionCode sai errado e o mismatch volta."
  exit 1
fi

# --- embute o ksud como libksud.so (mesmo caminho do justfile) --------------
JNI="$KSU_DIR/manager/app/src/main/jniLibs/arm64-v8a"
mkdir -p "$JNI"
cp "$KSUD_BIN" "$JNI/libksud.so"
echo "== ksud embutido em jniLibs/arm64-v8a/libksud.so =="

# --- assinatura -------------------------------------------------------------
cp "$KEYSTORE" "$KSU_DIR/manager/signing-key.jks"
{
  echo "KEYSTORE_FILE=signing-key.jks"
  echo "KEYSTORE_PASSWORD=$KEYSTORE_PASSWORD"
  echo "KEY_ALIAS=$KEY_ALIAS"
  echo "KEY_PASSWORD=$KEY_PASSWORD"
} >> "$KSU_DIR/manager/gradle.properties"

# --- build ------------------------------------------------------------------
cd "$KSU_DIR/manager"
chmod +x ./gradlew
./gradlew --no-daemon clean assembleRelease

APK="$(find app/build/outputs/apk/release -name '*.apk' | head -1)"
[ -n "$APK" ] || { echo "ERRO: APK nao gerado"; exit 1; }
cp "$APK" "$OUT/KernelSU-Manager.apk"
echo "== gerado: $OUT/KernelSU-Manager.apk =="
ls -l "$OUT/KernelSU-Manager.apk"

# --- gate: o versionCode do APK precisa bater com o do driver ---------------
AAPT="$(find "${ANDROID_HOME:-${ANDROID_SDK_ROOT:-/usr/local/lib/android/sdk}}/build-tools" \
        -name aapt2 2>/dev/null | sort -r | head -1 || true)"
if [ -n "$AAPT" ]; then
  VC="$("$AAPT" dump badging "$OUT/KernelSU-Manager.apk" 2>/dev/null \
        | sed -n "s/.*versionCode='\([0-9]*\)'.*/\1/p" | head -1)"
  echo "== versionCode do APK: ${VC:-<nao lido>} (esperado $EXPECTED_VC) =="
  if [ -n "$VC" ] && [ "$VC" != "$EXPECTED_VC" ]; then
    echo "ERRO: versionCode $VC != $EXPECTED_VC; o mismatch com o driver voltaria."
    exit 1
  fi
else
  echo "AVISO: aapt2 nao encontrado; versionCode nao verificado."
fi
