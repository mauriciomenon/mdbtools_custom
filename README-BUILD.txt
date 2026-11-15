MDBTOOLS (FORK) - BUILD ESTATICO WINDOWS, PRODUTOS E LIMPEZA
=============================================================
Guia pratico do build Windows deste fork. O README.md descreve o mdbtools; este arquivo diz como gerar os
executaveis que os apps mdb2sql usam como leitor reserva de .mdb/.accdb (quando falta o driver ODBC do Access).
Versao: AC_INIT em configure.ac (fonte unica; hoje 1.0.1).


1. REGRAS
---------
- Um comando por sistema e arquitetura. Ele faz tudo: confere a ferramenta, compila, testa cada .exe, gera
  os pacotes e so no fim troca dist\w11\amd64\. Se algo falhar, os produtos anteriores ficam intactos.
- Commite antes. Com alteracao nao commitada o comando para (codigo 2) e mostra os arquivos. Ele imprime
  "Source: <tag>-<n>-g<commit>" (ou so o commit, sem tag): esse e o commit que esta dentro do pacote.
- Sem autotools, sem MSYS2, sem GLib, sem iconv: os poucos valores que o ./configure calcularia estao
  fixos no script para o alvo mingw-w64 UCRT (x86_64-windows-gnu).
- Codigos de saida: 0 ok, 1 falha de build/teste, 2 maquina errada ou arvore suja, 3 falha ao baixar ou
  conferir a ferramenta.


2. "MAKE" - BUILD COMPLETO (rodar na raiz do repo, num pwsh novo)
-----------------------------------------------------------------
  Windows 11 amd64   .\build_w11_amd64.ps1      -> dist\w11\amd64\

Requisitos: so PowerShell 7 e git. O compilador (Zig 0.17.1 = clang + cabecalhos/bibliotecas mingw-w64
UCRT num unico zip) e baixado para .tools\zig-x86_64-windows-0.17.1\ com SHA-256 conferido
(b03f477a...562e, o mesmo de https://ziglang.org/download/index.json).

O que cada .exe precisa passar antes de entrar no pacote:
  - "<exe> --version" mostra a versao;
  - so importa DLLs do proprio Windows (KERNEL32.dll e api-ms-win-crt-*.dll do UCRT, que vem no
    Windows 10/11); qualquer outra DLL derruba o build;
  - nao contem o nome do usuario nem o da maquina (compilado com -s: sem debug info nem caminhos).


3. "MAKE CLEAN" - LIMPAR
------------------------
  .\clean.ps1          apaga build.stage.*\ e dist\.stage\ (intermediarios)
  .\clean.ps1 -Dist    idem e tambem dist\ (todos os produtos)
  .tools\ (Zig baixado) nunca e apagado; apague a mao para forcar novo download.


4. ONDE FICA CADA PRODUTO
-------------------------
dist\w11\amd64\
  mdb-tables.exe mdb-schema.exe mdb-export.exe mdb-count.exe mdb-ver.exe mdb-json.exe
      executaveis soltos, estaticos (~215 KB cada), rodam de qualquer pasta, sem instalar nada.
  mdbtools-<versao>-w11-amd64.zip
      pasta mdbtools-<versao>-w11-amd64\ com os 6 .exe, COPYING, COPYING.LIB e VERSION.txt (commit).
  SHA256SUMS.txt
      sha256 dos .exe e do .zip.
Nao ha instalador nem "exe unico": sao ferramentas de linha de comando para ir dentro dos apps mdb2sql.


5. COMPORTAMENTO NO WINDOWS (o que muda em relacao ao Linux)
------------------------------------------------------------
- Texto sai em UTF-8 sem iconv: para Access 2000+ (JET4/ACE) o libmdb converte UCS-2 com
  _wcstombs_l(locale ".65001") do UCRT (codigo original, src\libmdb\iconv.c).
  Limite conhecido: Access 97 (JET3) sem iconv usa conversao latin-1, entao os caracteres 0x80-0x9F do
  cp1252 (ex.: euro, aspas curvas) saem errados; acentos comuns saem certos. Nao testado (sem arquivo JET3).
- scripts\win\utf8.manifest: argv, fopen() e locale em UTF-8 (Windows 10 1903+), entao caminhos e nomes
  de tabela com acento funcionam.
- scripts\win\binmode.c: stdout/stderr em modo binario, entao a saida tem os mesmos bytes que no Linux
  (fim de linha LF, sem CR extra; CR/LF dentro de campos memo nao e duplicado).
- Nenhum arquivo de src\ foi alterado; os dois arquivos acima sao so do build Windows.


6. TESTE CONTRA UMA CONVERSAO DUCKDB (sempre numa COPIA do .accdb)
------------------------------------------------------------------
  uv run --no-project --with duckdb python -I tests\compare_duckdb.py dist\w11\amd64 <copia.accdb> <ref.duckdb>
      lista de tabelas (mdb-tables) e numero de linhas de cada tabela (mdb-count) iguais as do DuckDB.
  ... mesmo comando com --values
      tambem cada celula de cada tabela (mdb-export), linhas comparadas como multiconjunto.
  Saida "OK" e codigo 0, ou uma linha "PROBLEM ..." por diferenca e codigo 1.


7. PASTAS DE TRABALHO (podem ser apagadas; o build recria)
----------------------------------------------------------
  build.stage.<pid>\     cabecalhos gerados, objetos e cache do Zig (apagado no fim)
  dist\.stage\           pacotes sendo montados antes de irem para dist\w11\amd64\
  .tools\                Zig fixado
  Tudo isso esta no .gitignore.


8. ONDE ESTA A CHAMADA DO COMPILADOR
------------------------------------
  build_w11_amd64.ps1   tudo num arquivo: baixa/confere o Zig, gera include\mdbtools.h e mdbver.h a partir
                        dos .in, "zig cc -target x86_64-windows-gnu -O2 -s" em src\libmdb\*.c (com a
                        fakeglib embutida) e em src\util\<ferramenta>.c, confere e empacota.
  Para mais ferramentas: acrescente o nome em $Tools (as que usam libmdbsql, como mdb-sql, precisam
  tambem de src\sql e de bison/flex, que este build nao tem).
