#!/bin/sh
set -eu

# V2 do Sebo Menos Telas.
# Uso: ./gerar_site.sh
# Requer apenas Python 3.
#
# URLs são persistidas em .urlmap.json. Isso é proposital: remover/adicionar/reordenar
# linhas do CSV não deve mudar as URLs dos livros que continuam no acervo.
# Para livros com ISBN, o ISBN é a chave estável. Sem ISBN, usa-se a combinação
# título + autor + editora + ano. O sufixo curto é um código determinístico.

CSV="${1:-catalogo.csv}"
OUT="${2:-site}"
INDEX_TEMPLATE="index.html"
SOBRE_TEMPLATE="sobre.html"
BASE_URL="https://sebomenostelas.com.br"
URLMAP=".urlmap.json"

python3 - "$CSV" "$OUT" "$INDEX_TEMPLATE" "$SOBRE_TEMPLATE" "$BASE_URL" "$URLMAP" <<'PY'
import csv, hashlib, html, json, re, shutil, sys, unicodedata, urllib.parse, zipfile
from pathlib import Path

csv_path=Path(sys.argv[1]).expanduser().resolve()
out=Path(sys.argv[2]).expanduser().resolve()
index_template=Path(sys.argv[3]).expanduser().resolve()
sobre_template=Path(sys.argv[4]).expanduser().resolve()
base_url=sys.argv[5].rstrip("/")
urlmap_path=Path(sys.argv[6]).expanduser().resolve()

if not csv_path.exists(): raise SystemExit(f"CSV não encontrado: {csv_path}")
if not index_template.exists(): raise SystemExit(f"Template não encontrado: {index_template}")

out.mkdir(parents=True,exist_ok=True)
(out/"livro").mkdir(exist_ok=True)
(out/"dados").mkdir(exist_ok=True)

with csv_path.open("r",encoding="utf-8-sig",newline="") as f:
    rows=list(csv.DictReader(f))
if not rows: raise SystemExit("CSV vazio.")

required=["ISBN","Autor","Titulo","Editora","Ano","Estante","Preco","Peso","Idioma","Capa","Paginas","Dimensoes"]
missing=[c for c in required if c not in rows[0]]
if missing: raise SystemExit("Colunas ausentes no CSV: "+", ".join(missing))

def clean(v): return str(v or "").strip()
def esc(v): return html.escape(str(v or ""),quote=True)
def norm(v):
    return " ".join("".join(c for c in unicodedata.normalize("NFKD",str(v or "")) if not unicodedata.combining(c)).lower().split())
def slug_text(v):
    s=norm(v).replace("&"," e ")
    s=re.sub(r"[^a-z0-9]+","-",s).strip("-")
    return s
def price(v):
    try: return f"R$ {float(v):,.2f}".replace(",","X").replace(".",",").replace("X",".")
    except: return str(v or "")
def stable_key(r):
    isbn=norm(r["ISBN"])
    if isbn and isbn not in {"nd","n/d","na","n/a","sem isbn"}:
        return "isbn:"+isbn
    return "bib:"+"|".join(norm(r[c]) for c in ("Titulo","Autor","Editora","Ano"))
def suffix(key):
    return hashlib.sha1(key.encode("utf-8")).hexdigest()[:8]
def make_slug(r,key):
    isbn=clean(r["ISBN"])
    parts=[]
    if isbn and isbn.lower() not in {"nd","n/d","na","n/a","sem isbn"}: parts.append(slug_text(isbn))
    parts += [slug_text(r["Titulo"]),slug_text(r["Autor"]),slug_text(r["Editora"]),slug_text(r["Ano"])]
    parts=[p for p in parts if p]
    return "-".join(parts)+"-"+suffix(key)

if urlmap_path.exists():
    try: urlmap=json.loads(urlmap_path.read_text(encoding="utf-8"))
    except Exception as e: raise SystemExit(f"Não foi possível ler {URLMAP}: {e}")
else:
    urlmap={}
if not isinstance(urlmap,dict): raise SystemExit(f"{URLMAP} precisa conter um objeto JSON.")

used=set()
for r in rows:
    for c in required: r[c]=clean(r.get(c))
    if not r["ISBN"]: r["ISBN"]="ND"
    key=stable_key(r)
    if key in urlmap:
        r["_slug"]=urlmap[key]
    else:
        candidate=make_slug(r,key)
        if candidate in used or candidate in urlmap.values():
            candidate=f"{candidate}-{suffix(key+str(len(urlmap)))}"
        r["_slug"]=candidate
        urlmap[key]=candidate
    used.add(r["_slug"])

urlmap_path.write_text(json.dumps(urlmap,ensure_ascii=False,indent=2,sort_keys=True) + "\n",encoding="utf-8")

search_data=[]
for r in rows:
    search_data.append({"isbn":r["ISBN"],"autor":r["Autor"],"titulo":r["Titulo"],"editora":r["Editora"],"ano":r["Ano"],"preco":r["Preco"],"slug":r["_slug"]})
(out/"dados"/"catalogo.json").write_text(json.dumps(search_data,ensure_ascii=False,separators=(",",":")),encoding="utf-8")

for p in (out/"livro").glob("*.html"): p.unlink()

for r in rows:
    wa_text=f"Olá! Gostaria de receber fotos detalhadas deste exemplar:\n\n{r['Titulo']}, {r['Autor']} — {price(r['Preco'])}"
    wa_url="https://wa.me/5511981350566?text="+urllib.parse.quote(wa_text)
    book_url=f"{base_url}/livro/{r['_slug']}.html"
    page=f'''<!doctype html><html lang="pt-BR"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>{esc(r["Titulo"])} — {esc(r["Autor"])} | Sebo Menos Telas</title>
<meta name="description" content="{esc(r["Titulo"])} — {esc(r["Autor"])}, {esc(r["Editora"])}, {esc(r["Ano"])}. Exemplar usado disponível no Sebo Menos Telas.">
<meta name="robots" content="index,follow"><link rel="canonical" href="{esc(book_url)}">
<script type="application/ld+json">{json.dumps({"@context":"https://schema.org","@type":"Book","name":r["Titulo"],"author":{"@type":"Person","name":r["Autor"]},"publisher":{"@type":"Organization","name":r["Editora"]},"isbn":r["ISBN"] if r["ISBN"] not in {"ND",""} else None,"datePublished":r["Ano"] if r["Ano"].isdigit() else None,"inLanguage":r["Idioma"],"numberOfPages":int(r["Paginas"]) if r["Paginas"].isdigit() else None,"url":book_url},ensure_ascii=False,separators=(",",":"))}</script>
<style>:root{{color-scheme:light dark}}*{{box-sizing:border-box}}body{{max-width:760px;margin:0 auto;padding:28px 16px 40px;font-family:system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;color:#222;background:#fff;line-height:1.5}}a{{color:inherit}}.voltar{{display:inline-block;margin-bottom:24px}}h1{{margin:0 0 4px;font-size:clamp(1.5rem,6vw,2.2rem);line-height:1.2}}.autor{{margin:0 0 20px;font-weight:650}}.preco{{font-size:1.25rem;font-weight:750;margin:0 0 20px}}table{{width:100%;border-collapse:collapse}}th,td{{padding:9px 0;border-bottom:1px solid #ddd;text-align:left;vertical-align:top}}th{{width:36%;font-weight:650}}.acao{{display:block;margin-top:24px;padding:13px 16px;border-radius:6px;background:#222;color:#fff;text-align:center;text-decoration:none;font-weight:700}}footer{{margin-top:36px;padding-top:18px;border-top:1px solid #ddd;color:#666;font-size:.9rem;text-align:center}}@media(prefers-color-scheme:dark){{body{{color:#eee;background:#111}}th,td,footer{{border-color:#333}}.acao{{background:#eee;color:#111}}footer{{color:#aaa}}}}</style>
</head><body><a class="voltar" href="/">← Buscar outros livros</a><main><h1>{esc(r["Titulo"])}</h1><p class="autor">{esc(r["Autor"])}</p><p class="preco">{esc(price(r["Preco"]))}</p><table><tbody>
<tr><th>Título</th><td>{esc(r["Titulo"])}</td></tr><tr><th>Autor</th><td>{esc(r["Autor"])}</td></tr><tr><th>Editora</th><td>{esc(r["Editora"])}</td></tr><tr><th>Ano</th><td>{esc(r["Ano"])}</td></tr><tr><th>ISBN</th><td>{esc(r["ISBN"])}</td></tr><tr><th>Idioma</th><td>{esc(r["Idioma"])}</td></tr><tr><th>Capa</th><td>{esc(r["Capa"])}</td></tr><tr><th>Páginas</th><td>{esc(r["Paginas"])}</td></tr><tr><th>Dimensões</th><td>{esc(r["Dimensoes"])}</td></tr><tr><th>Peso</th><td>{esc(r["Peso"])} g</td></tr>
</tbody></table><a class="acao" href="{esc(wa_url)}" target="_blank" rel="noopener noreferrer nofollow">Pedir fotos detalhadas pelo WhatsApp</a></main><footer>Desde 2017 · São Paulo, SP · Sebo Menos Telas</footer></body></html>'''
    (out/"livro"/f'{r["_slug"]}.html').write_text(page,encoding="utf-8")

shutil.copy2(index_template, out/"index.html")
if sobre_template.exists():
    shutil.copy2(sobre_template, out/"sobre.html")

urls=[f"{base_url}/", f"{base_url}/sobre.html"]+[f'{base_url}/livro/{r["_slug"]}.html' for r in rows]
sitemap='<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n'+"\n".join(f"  <url><loc>{esc(u)}</loc></url>" for u in urls)+'\n</urlset>\n'
(out/"sitemap.xml").write_text(sitemap,encoding="utf-8")
(out/"robots.txt").write_text(f"User-agent: *\nAllow: /\n\nSitemap: {base_url}/sitemap.xml\n",encoding="utf-8")

zip_path=out.parent/(out.name+".zip")
if zip_path.exists(): zip_path.unlink()
with zipfile.ZipFile(zip_path,"w",zipfile.ZIP_DEFLATED) as z:
    for p in sorted(out.rglob("*")):
        if p.is_file(): z.write(p,p.relative_to(out).as_posix())
print(f"Gerado: {out}")
print(f"Livros: {len(rows)}")
print(f"URL map: {urlmap_path}")
print(f"Sitemap: {out/'sitemap.xml'}")
print(f"Robots: {out/'robots.txt'}")
print(f"ZIP: {zip_path}")
PY
