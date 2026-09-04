#!/usr/bin/env bash
# Compila o módulo kernelsu.ko para o Galaxy S26+ (KMI android16-6.12) a partir
# do fork polygraphene/KernelSU@kdp-612, usando a imagem DDK.
#
# Pode rodar de duas formas:
#   * dentro da imagem DDK (CI)     -> defina IN_DDK=1
#   * na sua máquina com Docker     -> ele mesmo sobe o container
#
# Variáveis (lidas de device/galaxy-s26-plus.env, sobreponíveis por env):
#   KERNEL_RELEASE  (OBRIGATÓRIA)  string exata de `uname -r` do aparelho
#   KMI, KSU_REPO, KSU_COMMIT, DDK_RELEASE, KSU_CONFIGS
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$REPO_ROOT/device/galaxy-s26-plus.env}"

# Carrega o perfil do aparelho SEM sobrescrever variáveis já definidas no
# ambiente (assim overrides do CI/linha de comando têm precedência).
load_env() {
  [ -f "$ENV_FILE" ] || return 0
  while IFS='=' read -r k v; do
    case "$k" in ''|\#*) continue ;; esac
    k="${k%% *}"; v="${v%\"}"; v="${v#\"}"
    [ -z "${!k:-}" ] && export "$k=$v" || true
  done < "$ENV_FILE"
}
load_env

: "${KERNEL_RELEASE:?defina KERNEL_RELEASE (uname -r exato do S26+) em $ENV_FILE}"
: "${KMI:=android16-6.12}"
: "${KSU_REPO:=https://github.com/polygraphene/KernelSU}"
: "${KSU_COMMIT:=a5531763971cf034e3f630d31654189a148e5f81}"
: "${DDK_RELEASE:=20260313}"
: "${KSU_CONFIGS:=CONFIG_KSU=m CONFIG_KSU_SAMSUNG_KDP=y CONFIG_KSU_SAMSUNG_RKP=y CONFIG_KSU_SAMSUNG_DEFEX=y}"

WORK="${WORK:-$REPO_ROOT/build}"
KSU_DIR="$WORK/kernelsu"
OUT="${OUT:-$REPO_ROOT/out/lkm}"
mkdir -p "$WORK" "$OUT"

# --- obter a fonte do KernelSU no commit fixado -----------------------------
if [ ! -d "$KSU_DIR/.git" ]; then
  echo "== clonando $KSU_REPO @ $KSU_COMMIT =="
  git clone --filter=blob:none "$KSU_REPO" "$KSU_DIR"
fi
git -C "$KSU_DIR" fetch --depth 1 origin "$KSU_COMMIT" 2>/dev/null || \
  git -C "$KSU_DIR" fetch origin
git -C "$KSU_DIR" checkout -q "$KSU_COMMIT"

# --- passos que rodam DENTRO da imagem DDK ----------------------------------
if [ "${IN_DDK:-0}" = "1" ]; then
  : "${KDIR:?a imagem DDK deve exportar KDIR}"
  echo "== build dentro do DDK: KMI=$KMI  KDIR=$KDIR =="
  git config --global --add safe.directory '*' || true
  cd "$KSU_DIR/kernel"

  # Sobrescreve o release para o vermagic bater com o alvo.
  DEFAULT_REL="$(cat "$KDIR/include/config/kernel.release")"
  echo "== release do DDK: '$DEFAULT_REL'  ->  alvo: '$KERNEL_RELEASE' =="
  for f in "$KDIR/include/generated/utsrelease.h" "$KDIR/include/config/kernel.release"; do
    [ -f "$f" ] && sed -i "s@${DEFAULT_REL}@${KERNEL_RELEASE}@g" "$f"
  done

  # O late-loader (ksuinit) reescreve os simbolos indefinidos para SHN_ABS com
  # enderecos do /proc/kallsyms, mas NAO toca na secao __versions. Se o modulo
  # carregar os CRCs do GKI do DDK, o kernel Samsung rejeita em
  # check_modstruct_version() -> "disagrees about version of symbol
  # module_layout" -> -ENOEXEC. Zerando o Module.symvers do DDK, o modpost nao
  # encontra CRC algum e emite __versions PRESENTE porem de tamanho 0: nesse
  # caso check_version() nao acha entradas e libera, e same_magic() ignora a
  # release string. E o que a receita Samsung exige.
  if [ -f "$KDIR/Module.symvers" ]; then
    cp "$KDIR/Module.symvers" "$WORK/Module.symvers.ddk.bak" 2>/dev/null || true
    : > "$KDIR/Module.symvers"
  fi

  # Slot 2 de assinatura de manager: permite que o modulo aceite TAMBEM um
  # manager assinado com a nossa chave, sem perder o oficial (slot 1, default
  # do Kbuild). O Kbuild aborta se um for definido sem o outro.
  EXTRA_SIG=""
  if [ -n "${KSU_EXPECTED_SIZE2:-}" ] || [ -n "${KSU_EXPECTED_HASH2:-}" ]; then
    if [ -z "${KSU_EXPECTED_SIZE2:-}" ] || [ -z "${KSU_EXPECTED_HASH2:-}" ]; then
      echo "ERRO: defina KSU_EXPECTED_SIZE2 e KSU_EXPECTED_HASH2 juntos."; exit 1
    fi
    EXTRA_SIG="KSU_EXPECTED_SIZE2=$KSU_EXPECTED_SIZE2 KSU_EXPECTED_HASH2=$KSU_EXPECTED_HASH2"
    echo "== assinatura de manager (slot 2): $KSU_EXPECTED_SIZE2 / $KSU_EXPECTED_HASH2 =="
  fi

  make clean >/dev/null 2>&1 || true
  # shellcheck disable=SC2086
  env $KSU_CONFIGS $EXTRA_SIG KBUILD_MODPOST_WARN=1 CC=clang make -j"$(nproc)"

  echo "== modinfo =="
  modinfo ./kernelsu.ko | grep -E 'vermagic|name' || true
  VM="$(modinfo -F vermagic ./kernelsu.ko | awk '{print $1}')"
  if [ "$VM" != "$KERNEL_RELEASE" ]; then
    echo "ERRO: vermagic '$VM' != KERNEL_RELEASE '$KERNEL_RELEASE'"; exit 1
  fi

  # Gate: __versions precisa EXISTIR e ter tamanho 0 (ver comentario acima).
  READER=""
  for RE in readelf llvm-readelf; do
    command -v "$RE" >/dev/null 2>&1 && { READER="$RE"; break; }
  done
  [ -n "$READER" ] || { echo "ERRO: nenhum readelf disponivel para validar __versions"; exit 1; }
  VHEX="$("$READER" -SW ./kernelsu.ko 2>/dev/null \
          | sed 's/^ *\[[ 0-9]*\] *//' \
          | awk '$1=="__versions"{print $5; exit}')"
  if [ -z "$VHEX" ]; then
    echo "ERRO: secao __versions AUSENTE. Com CONFIG_MODULE_FORCE_LOAD=n o kernel"
    echo "      recusa o modulo (try_to_force_load -> -ENOEXEC)."
    exit 1
  fi
  VSZ=$((16#$VHEX))
  echo "== __versions size: $VSZ bytes =="
  if [ "$VSZ" -ne 0 ]; then
    echo "ERRO: __versions tem $VSZ bytes (CRCs do DDK/GKI, nao do alvo Samsung)."
    echo "      O kernel do aparelho vai rejeitar com 'disagrees about version of symbol'."
    exit 1
  fi

  # Gate: NO_PATCH_TEXT nao gera .o proprio (e so um -D), entao confirmamos no
  # binario pela string que so existe nesse modo. Sem isso, o patch de texto ao
  # vivo (stop_machine + escrita na syscall table) causa panic em EL2 Samsung.
  case " $KSU_CONFIGS " in
    *" CONFIG_KSU_SAMSUNG_NO_PATCH_TEXT=y "*)
      if grep -aq "patch_text disabled for this Samsung target" ./kernelsu.ko; then
        echo "== NO_PATCH_TEXT: confirmado no binario =="
      else
        echo "ERRO: CONFIG_KSU_SAMSUNG_NO_PATCH_TEXT=y foi solicitado, mas a marca"
        echo "      correspondente nao esta no modulo (o -D nao propagou)."
        exit 1
      fi
      ;;
  esac

  # Auditoria opcional contra o vmlinux do alvo, se fornecido em device/target/.
  # Aceita vmlinux, vmlinux.elf, vmlinux.xz, vmlinux.gz (descomprime se preciso).
  RAW="$(ls "$REPO_ROOT"/device/target/vmlinux 2>/dev/null \
        "$REPO_ROOT"/device/target/vmlinux.elf 2>/dev/null \
        "$REPO_ROOT"/device/target/vmlinux.xz 2>/dev/null \
        "$REPO_ROOT"/device/target/vmlinux.gz 2>/dev/null | head -1 || true)"
  if [ -n "$RAW" ]; then
    case "$RAW" in
      *.xz) TGT_VMLINUX="$WORK/vmlinux"; xz -dc "$RAW" > "$TGT_VMLINUX" ;;
      *.gz) TGT_VMLINUX="$WORK/vmlinux"; gzip -dc "$RAW" > "$TGT_VMLINUX" ;;
      *)    TGT_VMLINUX="$RAW" ;;
    esac
    if [ -x ./check_symbol ]; then
      echo "== check_symbol contra alvo: $RAW =="
      ./check_symbol ./kernelsu.ko "$TGT_VMLINUX" || echo "AVISO: check_symbol reportou divergencias (revise)."
    fi
  else
    echo "== sem device/target/vmlinux: auditoria de simbolos pulada =="
  fi

  llvm-strip -d ./kernelsu.ko
  cp ./kernelsu.ko "$OUT/${KMI}_kernelsu.ko"
  echo "== gerado: $OUT/${KMI}_kernelsu.ko =="
  ls -l "$OUT/${KMI}_kernelsu.ko"
  exit 0
fi

# --- fora do container: sobe o Docker e re-executa este script --------------
IMAGE="ghcr.io/ylarod/ddk-min:${KMI}-${DDK_RELEASE}"
echo "== rodando build via Docker: $IMAGE =="
command -v docker >/dev/null || { echo "ERRO: Docker não encontrado."; exit 1; }
docker run --rm --privileged \
  -e IN_DDK=1 \
  -e KERNEL_RELEASE="$KERNEL_RELEASE" \
  -e KMI="$KMI" -e KSU_REPO="$KSU_REPO" -e KSU_COMMIT="$KSU_COMMIT" \
  -e KSU_CONFIGS="$KSU_CONFIGS" \
  -v "$REPO_ROOT:$REPO_ROOT" -w "$REPO_ROOT" \
  "$IMAGE" bash -lc "REPO_ROOT='$REPO_ROOT' WORK='$WORK' OUT='$OUT' '$REPO_ROOT/scripts/build-lkm.sh'"
