# Arquivos de referência do alvo (opcional)

Coloque aqui, se tiver, os arquivos recuperados do firmware do S26+ para
habilitar a auditoria de símbolos do módulo (contrato de manual-relocation do
late-load):

- `vmlinux` (ou `vmlinux.elf`) — kernel do S26+ com `.symtab`. Serve para
  `check_symbol` e para `audit_module_against_target.py`.
- `Module.symvers` — opcional; se ausente e o alvo usar `CONFIG_MODVERSIONS`,
  pode ser recuperado do `vmlinux` com `extract_target_symvers.py` (do
  repositório Root-My-Galaxy).

Se esta pasta ficar vazia, o build do `.ko` ainda ocorre, mas **sem** a
auditoria contra o alvo — nesse caso confie no `vermagic` (KERNEL_RELEASE) e
teste o carregamento no aparelho.

> Não faça commit de `vmlinux` grande sem necessidade; ele pode passar de
> centenas de MB. Prefira mantê-lo localmente e rodar o build local, ou usar
> Git LFS.
