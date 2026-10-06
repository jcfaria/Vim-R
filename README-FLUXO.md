# Fluxo de trabalho Git

Regras comuns a todos os projetos de jcfaria. Este arquivo é idêntico em
cada repositório; ao alterá-lo, replicar a mudança em todos. Regras
específicas de um projeto (testes, documentação obrigatória antes do
commit, siglas próprias) ficam no `README.md` / `CONTRIBUTING.md` dele e
complementam, sem contradizer, o que está aqui.

## Branches

| Branch       | Papel                                                        |
|--------------|--------------------------------------------------------------|
| `main`       | Consolidação. Só recebe merge de `work`; nunca commit direto. |
| `work`       | Trabalho do dia a dia. Todo commit nasce aqui.               |
| `work_<x>`   | Derivado de `work` para uma mudança arriscada ou experimental (ex.: `work_test`). Temporário. |

`main` e `work` existem sempre, no local e no remoto (`origin`).

## Siglas (humano → IA)

| Sigla    | Significado | Passos |
|----------|-------------|--------|
| **CP**   | Commit + Push | commit no branch atual (normalmente `work`) → push desse branch. `main` não é tocado. |
| **CPMPW** | Commit, Push, Merge, Push, Work | commit em `work` → push `work` → merge `work` em `main` → push `main` → volta o local para `work`. |

- "podes enviar" equivale a **CP**.
- **CMPW** e **CPMW**, usadas antes desta padronização, equivalem a
  **CPMPW**.
- Sem uma dessas ordens na mensagem, a IA prepara o commit e avisa, mas
  não faz push.
- Nenhuma sigla autoriza `--force`, criação de tags ou reescrita de
  histórico.

## Ciclo de um branch derivado

```
main  ──────────────●────────────
                   ↑ (CPMPW)
work  ──●──────●───●─────────────
         \        ↗ merge
work_x    ●──●──●
```

1. **Criar** a partir de `work` e espelhar no remoto, como cópia de
   segurança:
   ```
   git switch work
   git switch -c work_x
   git push -u origin work_x
   ```
2. **Trabalhar** em `work_x` com CP normalmente.
3. **Deu certo** → consolidar em `work` e `main`, subir, e podar:
   ```
   git switch work
   git merge work_x
   # CPMPW: push work → merge em main → push main → volta a work
   git branch -d work_x
   git push origin --delete work_x
   ```
4. **Não deu certo** → descartar e voltar a `work`:
   ```
   git switch work
   git branch -D work_x
   git push origin --delete work_x
   ```

## Abrangência e exceções

Vale para todos os repositórios próprios de `jcfaria` no GitHub
(padronizados em 2026-10-06), com estas exceções:

- **Forks de projetos de terceiros:** seguem o fluxo do projeto original.
- **Espelhos de upstream** (ex.: `CudaText-jcf`): `master` espelha o
  projeto original e não é consolidação; o trabalho próprio fica em
  `work-jcf`.
- **Repositórios compartilhados** (ex.: `RACE`): o fluxo é combinado com
  os colaboradores; branches deles não são tocados.
- **Legados congelados** (`ConsoleIO`, `Tinn-R`,
  `Tinn-R_Delphi_Community`): mantidos como estão. Se voltarem à ativa,
  recebem `work` e este arquivo.

Repositórios que ainda usavam `master` como branch principal passaram a
usar `main` na padronização.

## Regras gerais

- Histórico já enviado ao remoto não é reescrito (`--amend`, `rebase`,
  `reset --hard`, `--force`) sem autorização explícita para aquela
  reescrita específica.
- Um só autor por branch de cada vez. Antes de começar, `git status`:
  alterações locais inesperadas indicam trabalho de outra pessoa ou
  outro agente em andamento.
