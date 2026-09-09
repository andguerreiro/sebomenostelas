#!/bin/sh
set -eu

# Gera o site estático completo a partir do CSV principal.
# Uso:
#   ./gerar_site.sh catalogo.csv site
#
# Requer apenas Python 3 (Debian 13 já fornece).
# O terceiro argumento é opcional: se existir, o index.html é copiado para o site.

CSV="${1:-catalogo.csv}"
OUT="${2:-site}"
INDEX_TEMPLATE="index.html"

python3 - "$CSV" "$OUT" "$INDEX_TEMPLATE" <<'PY'
import csv, html, os, re, shutil, sys
from pathlib import Path
from collections import defaultdict

csv_path = Path(sys.argv[1]).expanduser().resolve()
out = Path(sys.argv[2]).expanduser().resolve()
index_template = Path(sys.argv[3]).expanduser().resolve()

if not csv_path.exists():
    raise SystemExit(f"CSV não encontrado: {csv_path}")

out.mkdir(parents=True, exist_ok=True)
(out / "livro").mkdir(exist_ok=True)
(out / "js").mkdir(exist_ok=True)
(out / "dados").mkdir(exist_ok=True)

with csv_path.open("r", encoding="utf-8-sig", newline="") as f:
    rows = list(csv.DictReader(f))

if not rows:
    raise SystemExit("CSV vazio.")

required = ["ID", "ISBN", "Autor", "Titulo", "Editora", "Ano", "Estante", "Preco", "Peso", "Idioma", "Capa", "Paginas", "Dimensoes"]
missing = [c for c in required if c not in rows[0]]
if missing:
    raise SystemExit("Colunas ausentes no CSV: " + ", ".join(missing))

# Normalização simples: ISBN vazio vira ND.
for r in rows:
    for c in required:
        r[c] = (r.get(c) or "").strip()
    if not r["ISBN"]:
        r["ISBN"] = "ND"

by_id = {r["ID"]: r for r in rows}


def esc(x):
    return html.escape(str(x or ""), quote=True)


def js_str(x):
    # String JS segura para os dados pequenos usados nos botões.
    return json.dumps(str(x or ""), ensure_ascii=False)


def slug_id(r):
    return re.sub(r"[^A-Za-z0-9_-]", "-", r["ID"])


def price(v):
    try:
        return f"R$ {float(v):.2f}".replace(".", ",")
    except Exception:
        return f"R$ {v}"


def norm(s):
    import unicodedata
    s = unicodedata.normalize("NFKD", str(s or ""))
    return "".join(ch for ch in s if not unicodedata.combining(ch)).lower()


def author_key(s):
    # Para autores compostos, usamos a string completa normalizada.
    return norm(s).strip()


def infer_tags(r):
    tags = []
    cat = norm(r["Estante"])
    lang = norm(r["Idioma"])
    title = norm(r["Titulo"])
    author = norm(r["Autor"])

    if r["Estante"]:
        tags.append(r["Estante"].strip().lower())
    if r["Idioma"]:
        tags.append("idioma:" + r["Idioma"].strip().lower())

    # Sinais conservadores: só acrescenta temas quando há indicação clara no catálogo.
    if any(x in title for x in ["aventura", "misterio", "mistério", "detective", "detetive", "sherlock"]):
        tags.append("aventura e mistério")
    if any(x in title for x in ["romance", "amor", "paixao", "paixão", "casamento", "marido", "esposa"]):
        tags.append("romance")
    if "fantasia" in title or "dragao" in title or "dragão" in title or "brumas de avalon" in title:
        tags.append("fantasia")
    if "conto" in title or "contos" in cat:
        tags.append("contos")
    if "poesia" in cat:
        tags.append("poesia")
    if "teatro" in cat:
        tags.append("teatro")

    # Alguns agrupamentos úteis já evidentes no acervo.
    if "infanto" in cat:
        tags.append("infantojuvenil")
    if author in {"monteiro lobato"}:
        tags.append("classicos infantis")
    if author in {"machado de assis", "jose de alencar", "jose de alencar"}:
        tags.append("classicos")
    if any(x in author for x in ["p. c. cast", "kristin cast", "alyson noel"]):
        tags.append("jovem")
    if any(x in author for x in ["agatha christie", "arthur conan doyle"]):
        tags.append("misterio")

    # Remove duplicatas preservando ordem.
    seen=set(); out=[]
    for t in tags:
        t=t.strip()
        if t and t not in seen:
            seen.add(t); out.append(t)
    return out


def related_ids(r, limit=8):
    # Prioridade: mesmo autor; depois mesma categoria+idioma; depois mesma categoria;
    # por fim mesmo idioma. O próprio livro nunca entra.
    rid = r["ID"]
    a = author_key(r["Autor"])
    cat = norm(r["Estante"])
    lang = norm(r["Idioma"])
    scored=[]
    for rr in rows:
        if rr["ID"] == rid:
            continue
        ra=author_key(rr["Autor"])
        rc=norm(rr["Estante"])
        rl=norm(rr["Idioma"])
        score=0
        if ra == a and a:
            score += 100
        if rc == cat and cat:
            score += 30
        if rl == lang and lang:
            score += 20
        # Mesmo título/coleção recebe pequeno bônus (sem exigir conhecimento externo).
        t1=norm(r["Titulo"]); t2=norm(rr["Titulo"])
        if t1 and t2 and (t1 in t2 or t2 in t1):
            score += 5
        if score:
            scored.append((score, rr["ID"]))
    scored.sort(key=lambda x: (-x[0], x[1]))
    return [x[1] for x in scored[:limit]]

# Gera tags e relacionados sempre de novo: vender/adicionar um livro e rodar o script
# recalcula automaticamente as relações do acervo atual.
for r in rows:
    r["Tags"] = " | ".join(infer_tags(r))
    r["IDs relacionados"] = " | ".join(related_ids(r))

# O CSV publicado pelo site inclui os campos derivados, mas o CSV de entrada não precisa deles.
out_cols = required + ["Tags", "IDs relacionados"]
with (out / "dados" / "catalogo.csv").open("w", encoding="utf-8-sig", newline="") as f:
    w=csv.DictWriter(f, fieldnames=out_cols)
    w.writeheader(); w.writerows(rows)

# Limpa páginas antigas, importante quando livros forem vendidos/removidos.
for p in (out / "livro").glob("*.html"):
    p.unlink()

css = r'''
:root{color-scheme:light dark}
html{scroll-behavior:smooth}
body{max-width:68ch;margin:2.5em auto;padding:1em;font-family:Georgia,serif;font-size:1.08em;line-height:1.7;color:#333;background:#fdfdfb;text-align:justify;hyphens:auto}
@media(prefers-color-scheme:dark){body{background:#1a1a1a;color:#ccc}}
h1,h2,h3{font-weight:normal;font-style:italic;text-align:center}
h1{border-bottom:1px solid #ccc;padding-bottom:.5em}
a{color:inherit;font-weight:bold}
.nav{display:flex;justify-content:center;gap:.9em;flex-wrap:wrap;margin:0 0 2em;padding:.7em 0;border-bottom:1px solid #ccc;font-size:.95em}
.nav a{text-decoration:none;font-style:italic;font-weight:normal}
.nav a:hover,.nav a:focus{text-decoration:underline}
.acao{display:block;margin:1.4em auto;padding:.8em 1em;border:1px solid #999;text-align:center;text-decoration:none;font-style:italic;font-weight:normal;cursor:pointer;background:transparent;color:inherit;font-family:inherit;font-size:1em}
.acao:hover,.acao:focus{background:#eee}
@media(prefers-color-scheme:dark){.acao:hover,.acao:focus{background:#292929}}
.nota{margin:1.8em 0;padding-left:1em;border-left:2px solid #bbb;font-size:.95em;font-style:italic}
.filtros{display:grid;gap:.7em;margin:2em 0}
input,select{font:inherit;padding:.65em;border:1px solid #aaa;background:transparent;color:inherit;width:100%;box-sizing:border-box}
.lista{display:grid;gap:1.2em}
.livro-card{border-top:1px solid #ccc;padding-top:1em}
.livro-card h2{font-size:1.2em;text-align:left;margin:0 0 .2em}
.livro-card p{margin:.2em 0}
.preco{font-size:1.15em}
.meta{font-size:.9em}
.item-garimpo{display:flex;justify-content:space-between;gap:1em;border-bottom:1px solid #ccc;padding:.8em 0;text-align:left}
.item-garimpo button{font:inherit;background:none;border:0;text-decoration:underline;cursor:pointer;color:inherit}
.total{border-top:1px solid #999;margin-top:1.2em;padding-top:1em;text-align:right;font-size:1.15em}
.vazio{text-align:center;font-style:italic;margin:3em 0}
.sem-resultado{text-align:center;font-style:italic;margin:2em 0}
table{width:100%;border-collapse:collapse;margin:2em 0}td{padding:.35em .2em;border-bottom:1px solid #ddd;vertical-align:top}td:first-child{font-style:italic;width:35%}
footer{margin-top:4em;padding-top:1.5em;border-top:1px solid #eee;text-align:center;font-size:.9em;font-style:italic}
@media(prefers-color-scheme:dark){footer{border-top-color:#333}td{border-bottom-color:#333}}
@media(max-width:560px){body{padding:.8em}.item-garimpo{align-items:flex-start}.nav{gap:.65em}}
'''

# JS compartilhado: "Meu garimpo" funciona como carrinho entre páginas.
# O link do WhatsApp continua sendo o único caminho de compra oferecido pelo site.
js = r'''(() => {
  const KEY = "smt_garimpo";
  const WA = "https://wa.link/ngit7u";
  const WA_PHONE = "5511981350566";
  const getGarimpo = () => JSON.parse(localStorage.getItem(KEY) || "[]");
  const saveGarimpo = p => localStorage.setItem(KEY, JSON.stringify(p));
  const esc = s => String(s ?? "").replace(/[&<>'"]/g, c => ({"&":"&amp;","<":"&lt;",">":"&gt;","'":"&#39;","\"":"&quot;"}[c]));

  function updateCount(){
    const n=getGarimpo().length;
    document.querySelectorAll("[data-garimpo-count]").forEach(el=>el.textContent=n);
  }
  function addBook(book){
    const p=getGarimpo();
    if(!p.some(x=>x.id===book.id)) p.push(book);
    saveGarimpo(p); updateCount(); renderGarimpo(); return p;
  }
  function removeBook(id){
    saveGarimpo(getGarimpo().filter(x=>x.id!==id));
    updateCount(); renderGarimpo();
    document.querySelectorAll(`[data-add-book][data-id="${CSS.escape(id)}"]`).forEach(b=>{b.textContent="Adicionar ao meu garimpo";b.disabled=false;});
  }
  function total(){ return getGarimpo().reduce((s,x)=>s+(Number(x.preco)||0),0); }
  function totalPeso(){ return getGarimpo().reduce((s,x)=>s+(Number(x.peso)||0),0); }
  function waMessage(){
    const p=getGarimpo();
    if(!p.length) return "Olá! Gostaria de ajuda para escolher livros no Sebo Menos Telas.";
    let s="Olá! Gostaria de comprar estes livros no Sebo Menos Telas:\n\n";
    p.forEach((x,i)=>{ s+=`${i+1}. ${x.titulo}, ${x.autor} [${x.id}] — R$ ${Number(x.preco).toFixed(2).replace(".",",")} — ${x.peso} g\n`; });
    s+=`\nTotal dos livros: R$ ${total().toFixed(2).replace('.',',')} (${totalPeso()} g).\n\nGostaria de receber as fotos detalhadas dos exemplares exatos antes de confirmar a compra.`;
    return s;
  }
  function openWhatsApp(){
    const message=waMessage();
    const url=`https://wa.me/${WA_PHONE}?text=${encodeURIComponent(message)}`;
    window.location.href=url;
  }
  function renderGarimpo(){
    const box=document.querySelector("[data-garimpo]");
    const totalBox=document.querySelector("[data-garimpo-total]");
    if(!box) return;
    const p=getGarimpo();
    if(!p.length){
      box.innerHTML='<p class="vazio">Seu garimpo está vazio. <a href="catalogo.html">Volte ao catálogo</a> e escolha alguns livros.</p>';
      if(totalBox) totalBox.textContent="R$ 0,00";
      return;
    }
    box.innerHTML=p.map(x=>`<div class="item-garimpo"><span><strong>${esc(x.titulo)}</strong><br><small>${esc(x.autor)} · R$ ${Number(x.preco).toFixed(2).replace('.',',')} · ${esc(x.id)}</small></span><button type="button" data-remove="${esc(x.id)}">retirar</button></div>`).join("");
    box.querySelectorAll("[data-remove]").forEach(b=>b.addEventListener("click",()=>removeBook(b.dataset.remove)));
    if(totalBox) totalBox.textContent=`R$ ${total().toFixed(2).replace('.',',')}`;
  }

  document.addEventListener("click",e=>{
    const b=e.target.closest("[data-add-book]");
    if(b){
      addBook({id:b.dataset.id,titulo:b.dataset.titulo,autor:b.dataset.autor,preco:b.dataset.preco,peso:b.dataset.peso});
      b.textContent="No meu garimpo"; b.disabled=true;
    }
    const wBook=e.target.closest("[data-whatsapp]");
    if(wBook){
      e.preventDefault();
      const message=`Olá! Gostaria de comprar este livro no Sebo Menos Telas:\n\n${wBook.dataset.titulo}, ${wBook.dataset.autor} [${wBook.dataset.id}] — R$ ${Number(wBook.dataset.preco).toFixed(2).replace(".",",")} — ${wBook.dataset.peso} g\n\nGostaria de receber as fotos detalhadas deste exemplar exato antes de confirmar a compra.`;
      window.location.href=`https://wa.me/${WA_PHONE}?text=${encodeURIComponent(message)}`;
      return;
    }
    const w=e.target.closest("[data-whatsapp-garimpo]");
    if(w){e.preventDefault();openWhatsApp();}
  });

  document.addEventListener("DOMContentLoaded",()=>{
    updateCount(); renderGarimpo();
    const current=getGarimpo().map(x=>x.id);
    document.querySelectorAll("[data-add-book]").forEach(b=>{if(current.includes(b.dataset.id)){b.textContent="No meu garimpo";b.disabled=true;}});

    const search=document.querySelector("[data-search]");
    const category=document.querySelector("[data-category]");
    const language=document.querySelector("[data-language]");
    const cards=[...document.querySelectorAll("[data-book-card]")];
    const empty=document.querySelector("[data-no-results]");
    function filter(){
      const q=(search?.value||"").toLocaleLowerCase("pt-BR").trim();
      const c=category?.value||"";
      const l=language?.value||"";
      let shown=0;
      cards.forEach(card=>{
        const hay=(card.dataset.search||"").toLocaleLowerCase("pt-BR");
        const ok=(!q||hay.includes(q))&&(!c||card.dataset.category===c)&&(!l||card.dataset.language===l);
        card.hidden=!ok; if(ok) shown++;
      });
      if(empty) empty.hidden=shown!==0;
    }
    [search,category,language].filter(Boolean).forEach(el=>el.addEventListener("input",filter));
    filter();
  });
})();
'''
# json é usado pelo JS generator acima
import json
(out / "js" / "catalogo.js").write_text(js, encoding="utf-8")

nav = '''<nav class="nav" aria-label="Navegação principal">
<a href="{index}">Início</a>
<a href="{catalogo}">Catálogo</a>
<a href="{garimpo}">Garimpo (<span data-garimpo-count>0</span>)</a>
</nav>'''

cats=sorted({r["Estante"] for r in rows if r["Estante"]})
langs=sorted({r["Idioma"] for r in rows if r["Idioma"]})
cat_options="".join(f'<option value="{esc(c)}">{esc(c)}</option>' for c in cats)
lang_options="".join(f'<option value="{esc(l)}">{esc(l)}</option>' for l in langs)

cards=[]
for r in rows:
    href=f"livro/{slug_id(r)}.html"
    search=" ".join([r["Titulo"],r["Autor"],r["Editora"],r["Idioma"],r["Estante"],r["ISBN"]])
    cards.append(f'''<article class="livro-card" data-book-card data-category="{esc(r['Estante'])}" data-language="{esc(r['Idioma'])}" data-search="{esc(search)}">
<h2><a href="{esc(href)}">{esc(r['Titulo'])}</a></h2>
<p><em>{esc(r['Autor'])}</em></p>
<p class="preco">{esc(price(r['Preco']))}</p>
<p class="meta">{esc(r['Estante'])} · {esc(r['Idioma'])} · {esc(r['Capa'])} · {esc(r['Paginas'])} páginas · {esc(r['Dimensoes'])}</p>
</article>''')

catalog_html=f'''<!DOCTYPE html>
<html lang="pt-br"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Catálogo | Sebo Menos Telas</title><style>{css}</style></head>
<body>
<header>{nav.format(index="/",catalogo="/catalogo.html",garimpo="/garimpo.html")}<h1>Catálogo</h1></header>
<main>
<p>Garimpe o acervo por título, autor, categoria ou idioma. Escolha quantos livros quiser e coloque-os no seu garimpo.</p>
<div class="filtros">
<label>Pesquisar<br><input data-search type="search" placeholder="título, autor, editora ou ISBN"></label>
<label>Categoria<br><select data-category><option value="">Todas</option>{cat_options}</select></label>
<label>Idioma<br><select data-language><option value="">Todos</option>{lang_options}</select></label>
</div>
<p class="sem-resultado" data-no-results hidden>Nenhum livro encontrado para sua pesquisa.</p>
<section class="lista">{''.join(cards)}</section>
</main>
<footer><p>Antes de confirmar a compra, peça as fotos detalhadas do exemplar exato pelo WhatsApp.</p></footer>
<script src="/js/catalogo.js"></script></body></html>'''
(out/"catalogo.html").write_text(catalog_html,encoding="utf-8")

# Página separada do "Meu garimpo", funcionando como carrinho.
garimpo_html=f'''<!DOCTYPE html>
<html lang="pt-br"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Garimpo | Sebo Menos Telas</title><style>{css}</style></head>
<body>
<header>{nav.format(index="/",catalogo="/catalogo.html",garimpo="/garimpo.html")}<h1>Garimpo</h1></header>
<main>
<p>Este é o seu carrinho de livros escolhidos enquanto você garimpa o acervo.</p>
<section data-garimpo></section>
<div class="total">Total dos livros: <strong data-garimpo-total>R$ 0,00</strong></div>
<a class="acao" data-whatsapp-garimpo href="https://wa.link/ngit7u" target="_blank" rel="noopener noreferrer nofollow">Enviar meu garimpo pelo WhatsApp</a>
<div class="nota"><strong>Antes de confirmar:</strong> pelo WhatsApp você pode pedir fotos detalhadas dos exemplares exatos — capa, contracapa, lombada e páginas — para ver os sinais de uso antes da compra.<br><br>O valor do frete será informado antes do fechamento do pedido pelo WhatsApp. O pagamento é feito apenas via Pix.</div>
<a class="acao" href="/catalogo.html">Continuar garimpando</a>
</main>
<footer><p>Sebo Menos Telas · Compra direta pelo WhatsApp</p></footer>
<script src="/js/catalogo.js"></script></body></html>'''
(out/"garimpo.html").write_text(garimpo_html,encoding="utf-8")

# Páginas individuais
for r in rows:
    rel=related_ids(r)
    related_html=[]
    for rid in rel:
        rr=by_id[rid]
        related_html.append(f'<li><a href="../livro/{slug_id(rr)}.html">{esc(rr["Titulo"])}</a> — {esc(rr["Autor"])}</li>')
    page=f'''<!DOCTYPE html>
<html lang="pt-br"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>{esc(r["Titulo"])}, {esc(r["Autor"])} | Sebo Menos Telas</title><meta name="description" content="{esc(r["Titulo"])}, de {esc(r["Autor"])}, por {esc(price(r["Preco"]))}. Livro usado no Sebo Menos Telas."><style>{css}</style></head>
<body>
<header>{nav.format(index="../",catalogo="../catalogo.html",garimpo="../garimpo.html")}<p><a href="../catalogo.html">← Voltar ao catálogo</a></p><h1>{esc(r['Titulo'])}</h1><p style="text-align:center"><em>{esc(r['Autor'])}</em></p></header>
<main>
<p class="preco" style="text-align:center">{esc(price(r['Preco']))}</p>
<table><tbody>
<tr><td>Título</td><td>{esc(r['Titulo'])}</td></tr>
<tr><td>Autor</td><td>{esc(r['Autor'])}</td></tr>
<tr><td>Editora</td><td>{esc(r['Editora'])}</td></tr>
<tr><td>Ano</td><td>{esc(r['Ano'])}</td></tr>
<tr><td>ISBN</td><td>{esc(r['ISBN'])}</td></tr>
<tr><td>Idioma</td><td>{esc(r['Idioma'])}</td></tr>
<tr><td>Capa</td><td>{esc(r['Capa'])}</td></tr>
<tr><td>Páginas</td><td>{esc(r['Paginas'])}</td></tr>
<tr><td>Dimensões</td><td>{esc(r['Dimensoes'])}</td></tr>
<tr><td>Peso</td><td>{esc(r['Peso'])} g</td></tr>
<tr><td>Código</td><td>{esc(r['ID'])}</td></tr>
</tbody></table>
<div class="nota"><strong>As fotos não ficam publicadas no catálogo.</strong> Peça pelo WhatsApp fotos detalhadas deste exemplar exato: capa, contracapa, lombada, páginas e eventuais dedicatórias, grifos, manchas, amarelamento, rasgos ou outros detalhes.</div>
<button class="acao" type="button" data-add-book data-id="{esc(r['ID'])}" data-titulo="{esc(r['Titulo'])}" data-autor="{esc(r['Autor'])}" data-preco="{esc(r['Preco'])}" data-peso="{esc(r['Peso'])}">Adicionar ao meu garimpo</button>
<a class="acao" data-whatsapp data-id="{esc(r['ID'])}" data-titulo="{esc(r['Titulo'])}" data-autor="{esc(r['Autor'])}" data-preco="{esc(r['Preco'])}" data-peso="{esc(r['Peso'])}" href="https://wa.link/ngit7u" target="_blank" rel="noopener noreferrer nofollow">Pedir fotos pelo WhatsApp</a>
<hr>
<h2>Livros relacionados</h2>
<ul>{''.join(related_html) if related_html else '<li>Outros livros do acervo podem ser encontrados no catálogo.</li>'}</ul>
<a class="acao" href="../catalogo.html">Continuar garimpando</a>
</main>
<footer><p>Sebo Menos Telas · Compra direta pelo WhatsApp</p></footer>
<script src="../js/catalogo.js"></script></body></html>'''
    (out/"livro"/(slug_id(r)+".html")).write_text(page,encoding="utf-8")

# index.html: usa a versão editável que fica ao lado do script.
if index_template.exists():
    shutil.copy2(index_template, out / "index.html")
else:
    # Não inventa um novo design se o template não estiver presente.
    print(f"AVISO: template de index não encontrado: {index_template}")
    print("       O restante do site foi gerado normalmente.")

# Gera o ZIP final com o conteúdo do site na raiz do arquivo.
# Assim, ao enviar site.zip ao Cloudflare, index.html fica na raiz.
zip_path = out.parent / (out.name + ".zip")
if zip_path.exists():
    zip_path.unlink()
import zipfile
with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as z:
    for p in sorted(out.rglob("*")):
        if p.is_file():
            z.write(p, p.relative_to(out).as_posix())

print(f"Gerado: {out}")
print(f"Livros: {len(rows)}")
print(f"Páginas individuais: {len(rows)}")
print(f"Tags e IDs relacionados: recalculados automaticamente")
print(f"Catálogo: {out/'catalogo.html'}")
print(f"Garimpo: {out/'garimpo.html'}")
print(f"ZIP: {zip_path}")
PY
