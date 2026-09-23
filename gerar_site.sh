#!/bin/sh
set -eu

# V9 do Sebo Menos Telas.
# Uso: ./gerar_site.sh
# Requer apenas Python 3.
# A busca considera título, autor, editora, ISBN, ano, estante, idioma e preço.
#
# URLs são persistidas em .urlmap.json. Isso é proposital: remover/adicionar/reordenar
# linhas do CSV não deve mudar as URLs dos livros que continuam no acervo.
# Para livros com ISBN, o ISBN é a chave estável. Sem ISBN, usa-se a combinação
# título + autor + editora + ano. O sufixo curto é um código determinístico.

CSV="${1:-catalogo.csv}"
OUT="${2:-site}"
INDEX_TEMPLATE="${3:-index.html}"
SOBRE_TEMPLATE="${4:-sobre.html}"
FAVICON_TEMPLATE="${5:-favicon.png}"
LOGO_TEMPLATE="${6:-logo.png}"
ERROR_TEMPLATE="${7:-404.html}"
BASE_URL="https://sebomenostelas.com.br"
URLMAP=".urlmap.json"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

python3 "$SCRIPT_DIR/gerar_site.py" \
  "$CSV" "$OUT" "$INDEX_TEMPLATE" "$SOBRE_TEMPLATE" \
  "$FAVICON_TEMPLATE" "$LOGO_TEMPLATE" "$ERROR_TEMPLATE" \
  "$BASE_URL" "$URLMAP"
