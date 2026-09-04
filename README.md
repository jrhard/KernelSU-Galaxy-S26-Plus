# ksud + KernelSU LKM para Galaxy S26+ (kernel 6.12)

Infraestrutura de build que compila, via **GitHub Actions**, um `ksud`
(daemon userspace do KernelSU) com o módulo de kernel `kernelsu.ko`
**embutido e específico para o Galaxy S26+** (KMI `android16-6.12`).

O daemon é gerado a partir do fork **`polygraphene/KernelSU`**, branch
`kdp-612` (commit fixado
[`a5531763`](https://github.com/polygraphene/KernelSU/commit/a5531763971cf034e3f630d31654189a148e5f81)),
que traz:

- o fix de resolução de símbolos **Samsung KDP** no kernel 6.12
  (`kdp_usecount_sub_and_test`);
- o suporte a **RKP / DEFEX**;
- as mudanças de `ksud` do late-load (staging em `/data/local/tmp/.ksud-stage`,
  `finish_install`) que foram portadas no PR
  [`BuSung-dev/Root-My-Galaxy-Payloads#198`](https://github.com/BuSung-dev/Root-My-Galaxy-Payloads/pull/198).

Este repositório contém **apenas** a infra de build do KernelSU/ksud. Ele não
inclui nenhum exploit nem payload de obtenção de root — o `ksud` pressupõe que
você já tenha root para rodar `ksud late-load`.

## Por que via GitHub Actions

O `ksud` é um binário Android `aarch64` e precisa do **Android NDK r29** para
cross-compilar; o `.ko` precisa da imagem **DDK** `android16-6.12`. Os runners
do GitHub baixam ambos sem restrição, o que torna o build reprodutível sem
depender do ambiente local.

## O que você precisa fornecer (específico do aparelho)

O `.ko` só carrega num kernel Samsung (`CONFIG_MODULE_FORCE_LOAD=n`) se o
**`vermagic` bater exatamente** com o release do kernel. Preencha em
[`device/galaxy-s26-plus.env`](device/galaxy-s26-plus.env):

| Variável | Como obter | Exemplo |
| --- | --- | --- |
| `KERNEL_RELEASE` | `uname -r` no aparelho (string **exata**, com sufixo de build) | `6.12.30-android16-8-...` |
| `KMI` | derivado do release (`androidNN-<maj.min>`) | `android16-6.12` |

Opcional, porém recomendado para auditoria de símbolos (manual-relocation):
coloque `vmlinux` e/ou `Module.symvers` do S26+ em `device/target/` (veja
[`device/target/README.md`](device/target/README.md)).

> A "source do kernel" ajuda a confirmar configs e a versão base, mas o sufixo
> de build do `vermagic` vem do **firmware já compilado** — por isso o
> `uname -r` do aparelho é o dado mais importante.

## Requisitos críticos do módulo (não regredir)

O `.ko` é carregado pelo `ksud late-load`, que usa o loader de
**manual-relocation** do `ksuinit`: ele reescreve cada símbolo `SHN_UNDEF` para
`SHN_ABS` com o endereço vindo do `/proc/kallsyms` e então chama `init_module`.
Duas condições decorrem disso e o build **falha de propósito** se não forem
atendidas:

1. **`__versions` presente e de tamanho 0.** O loader não toca nessa seção. Se
   ela vier com os CRCs do GKI do DDK, o kernel Samsung rejeita em
   `check_modstruct_version()` (`disagrees about version of symbol
   module_layout` → `-ENOEXEC`). Com ela vazia, `check_version()` não acha
   entradas e libera, e `same_magic()` ignora a release string. O build zera o
   `Module.symvers` do DDK e usa `KBUILD_MODPOST_WARN=1` para isso, validando
   o resultado com `readelf`.
   Se a seção estiver **ausente** também falha: com `CONFIG_MODULE_FORCE_LOAD=n`
   o kernel cai em `try_to_force_load()` → `-ENOEXEC`.

2. **`CONFIG_KSU_SAMSUNG_NO_PATCH_TEXT=y`.** O patch de texto ao vivo
   (`stop_machine` + escrita na syscall table) causa **panic em EL2
   Samsung/Exynos**. Nesse modo `ksu_patch_text()` retorna `-EOPNOTSUPP` sem
   chamar `stop_machine`, e o KernelSU usa o caminho fail-closed (kretprobe em
   `__arm64_sys_setresuid` + kprobes de sucompat por endereço).

## Como buildar

1. Preencha `device/galaxy-s26-plus.env` (pelo menos `KERNEL_RELEASE`).
2. Faça commit e vá em **Actions → Build ksud (Galaxy S26+) → Run workflow**
   (ou rode com `workflow_dispatch` passando `kernel_release`).
3. Baixe os artifacts:
   - `android16-6.12_kernelsu.ko` — o módulo isolado (para auditoria);
   - `ksud-galaxy-s26-plus` — o daemon com o `.ko` embutido (é o que você usa).

Instalação no aparelho (já com root):

```sh
adb push ksud /data/local/tmp/ksud
adb shell su -c 'cp /data/local/tmp/ksud /data/local/tmp/.ksud-stage && \
  chmod 755 /data/local/tmp/.ksud-stage && /data/local/tmp/.ksud-stage late-load'
```

## Manager casado (resolve o "version mismatch")

Manager, driver e `ksud` derivam a versão da **mesma** fórmula
(`30000 + git rev-list --count HEAD`). Um manager baixado de outra árvore gera:

```
Manager version (32601) and KernelSU driver version (32527) mismatch.
```

Por isso o workflow também compila o Manager **do commit fixado**, ficando
`32527` nos três. Como o módulo valida a assinatura do manager, o job `key`
gera uma chave, registra o certificado dela como **slot 2**
(`KSU_EXPECTED_SIZE2`/`KSU_EXPECTED_HASH2`) e assina o APK com ela — o driver
passa a aceitar tanto o manager oficial (slot 1) quanto o nosso.

⚠️ **Ao instalar o APK:**

1. **Desinstale o KernelSU Manager atual antes.** O APK novo usa outra chave de
   assinatura; o Android recusa instalar por cima (`signatures do not match`).
2. **Use o `ksud` e o APK da MESMA run.** A chave é gerada por execução, então
   artefatos de runs diferentes não combinam. (Se preferir uma chave fixa,
   guarde o `.jks` em GitHub Secrets e troque o job `key` por ele.)

## Build local (alternativa)

Se preferir compilar na sua máquina (com NDK r29 e Docker), use os scripts em
[`scripts/`](scripts/):

```sh
# 1) módulo .ko (precisa de Docker)
KERNEL_RELEASE='6.12.xx-android16-...' scripts/build-lkm.sh

# 2) ksud com o .ko embutido (precisa de NDK r29)
ANDROID_NDK_HOME=/caminho/para/ndk scripts/build-ksud.sh
```

## Créditos

- [KernelSU](https://github.com/tiann/KernelSU) — projeto original (GPL-2.0).
- [`polygraphene/KernelSU`](https://github.com/polygraphene/KernelSU) — fork com
  suporte Samsung KDP/RKP/DEFEX e 6.12.
- Imagem DDK: `ghcr.io/ylarod/ddk-min`.
