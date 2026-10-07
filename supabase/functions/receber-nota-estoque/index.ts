// API: o sistema de Estoque (almoxarifado) avisa que recebeu uma nota fiscal.
// Se a nota já existe no Controle de Notas, só vincula (e completa campos vazios); senão cria em "Entradas" com origem "estoque".
// { acao: "obras" }  devolve as obras ativas do Controle, para o estoque escolher a obra da nota.
// { acao: "anexo" }  anexa um arquivo (boleto, CT-e...) a uma nota que veio do estoque.
// Autenticação: o token de login do usuário no Supabase do ESTOQUE (outro projeto), conferido
// na API de auth do estoque; o usuário precisa estar ativo lá. Não há senha fixa no código do front.
// verify_jwt fica desligado de propósito: o token é do outro projeto e é conferido aqui.
// Publicada no projeto Supabase kygainafarusnsstvvhc (verify_jwt = false).
import { createClient } from "jsr:@supabase/supabase-js@2";

const ESTOQUE_URL = "https://qjmqburjyqlgwjihvlgp.supabase.co";
// chave pública (anon) do projeto do estoque — a mesma que já está no index.html dele
const ESTOQUE_ANON = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InFqbXFidXJqeXFsZ3dqaWh2bGdwIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODg4NzU0NzIsImV4cCI6MjEwNDQ1MTQ3Mn0.cOdmVw3W0HCilACqZIVFMCwsr6zxA0g_3CreKIuk9kw";
const ANEXO_BUCKET = "anexos";
const ANEXO_MAX = 15 * 1024 * 1024; // mesmo limite do Controle de Notas
// só estes tipos podem ser anexados; o tipo gravado vem da extensão, não do que o navegador informou
const ANEXO_TIPOS: Record<string, string> = {
  pdf: "application/pdf", jpg: "image/jpeg", jpeg: "image/jpeg", png: "image/png", gif: "image/gif", webp: "image/webp",
  xml: "application/xml", txt: "text/plain",
  doc: "application/msword", docx: "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
  xls: "application/vnd.ms-excel", xlsx: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
};

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, content-type, apikey, x-client-info",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });
// erro interno: detalhe só no log da função; quem chamou recebe mensagem genérica
const falha = (contexto: string, e: unknown) => { console.error(contexto, e); return json({ error: "Erro interno no Controle de Notas (" + contexto + "). Tente de novo ou avise o administrador." }, 500); };
const data = (v: unknown) => (/^\d{4}-\d{2}-\d{2}$/.test(String(v ?? "")) ? String(v) : null);
const txt = (v: unknown, n: number) => (v === undefined || v === null || String(v).trim() === "" ? null : String(v).trim().slice(0, n));
const num = (v: unknown) => (v === undefined || v === null || v === "" || !isFinite(Number(v)) || Number(v) < 0 ? null : String(Number(v)));

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "Use POST." }, 405);

  const token = (req.headers.get("authorization") || "").replace(/^Bearer\s+/i, "");
  if (!token) return json({ error: "Login do estoque ausente." }, 401);

  // 1) confere o login no Supabase do estoque
  const uRes = await fetch(`${ESTOQUE_URL}/auth/v1/user`, { headers: { apikey: ESTOQUE_ANON, Authorization: `Bearer ${token}` } });
  if (!uRes.ok) return json({ error: "Login do estoque inválido ou expirado." }, 401);
  const user = await uRes.json();
  // 2) perfil precisa estar ativo no estoque
  const pRes = await fetch(`${ESTOQUE_URL}/rest/v1/profiles?id=eq.${encodeURIComponent(user.id)}&select=nome,email,ativo`, {
    headers: { apikey: ESTOQUE_ANON, Authorization: `Bearer ${token}` },
  });
  const perfis = pRes.ok ? await pRes.json() : [];
  const perfil = perfis && perfis[0];
  if (!perfil || !perfil.ativo) return json({ error: "Usuário do estoque inativo." }, 403);
  const usuario = String(perfil.nome || perfil.email || user.email || "Estoque").slice(0, 120);

  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { return json({ error: "JSON inválido." }, 400); }
  const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

  if (body.acao === "obras") {
    const { data: obras, error } = await admin.from("obras").select("id,codigo,nome,obra_cnpjs(cnpj)").eq("active", true).order("nome");
    if (error) return falha("obras", error);
    return json({ obras: (obras || []).map((o: any) => ({ id: o.id, codigo: o.codigo, nome: o.nome, cnpjs: (o.obra_cnpjs || []).map((c: any) => c.cnpj) })) });
  }

  if (body.acao === "anexo") {
    // só anexa em nota que veio deste estoque: o id do Controle precisa estar vinculado ao id da nota no estoque
    const notaId = Number(body.notaId);
    const estoqueNotaId = txt(body.estoqueNotaId, 80);
    if (!notaId || !estoqueNotaId) return json({ error: "Nota não informada." }, 400);
    const { data: nota } = await admin.from("notas").select("id").eq("id", notaId).eq("estoque_nota_id", estoqueNotaId).maybeSingle();
    if (!nota) return json({ error: "Nota não encontrada no Controle de Notas (ou não veio do estoque)." }, 404);
    const categoria = body.categoria === "frete" ? "frete" : "nota";
    const nome = (txt(body.nome, 200) || "documento").replace(/[\\/\u0000-\u001f]/g, "_");
    const ext = (nome.includes(".") ? nome.split(".").pop() || "" : "").toLowerCase();
    const mime = ANEXO_TIPOS[ext];
    if (!mime) return json({ error: "Tipo de arquivo não permitido (use PDF, imagem, XML, Word, Excel ou TXT)." }, 400);
    let bytes: Uint8Array;
    try {
      const bin = atob(String(body.base64 || ""));
      bytes = new Uint8Array(bin.length);
      for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
    } catch { return json({ error: "Arquivo inválido." }, 400); }
    if (!bytes.length) return json({ error: "Arquivo vazio." }, 400);
    if (bytes.length > ANEXO_MAX) return json({ error: "Arquivo muito grande (máx. 15 MB)." }, 400);
    const path = `nota_${notaId}/${Date.now()}_${crypto.randomUUID().slice(0, 8)}.${ext}`;
    const { error: upErr } = await admin.storage.from(ANEXO_BUCKET).upload(path, bytes, { contentType: mime, upsert: false });
    if (upErr) return falha("envio do arquivo", upErr);
    const { data: anexo, error: insErr } = await admin.from("anexos").insert({
      nota_id: notaId, categoria, nome_original: nome, mime_type: mime, tamanho: bytes.length, storage_path: path,
    }).select("id").single();
    if (insErr) { await admin.storage.from(ANEXO_BUCKET).remove([path]); return falha("registro do anexo", insErr); }
    await admin.from("audit_log").insert({ user_id: null, user_name: "Estoque: " + usuario, action: "anexo_estoque", entity_type: "nota_fiscal", entity_id: String(notaId), details: { categoria, nome, tamanho: bytes.length } });
    return json({ ok: true, id: anexo.id });
  }

  const frete = body.frete === "sim" || body.frete === "nao" ? body.frete : null;
  const prioridade = ["baixa", "media", "alta"].includes(String(body.prioridade)) ? body.prioridade : null;
  const nota = {
    numero: String(body.numero ?? "").slice(0, 60),
    fornecedor: String(body.fornecedor ?? "").slice(0, 200),
    valor: Number(body.valor) || 0,
    dataEmissao: data(body.dataEmissao),
    chaveAcesso: txt(body.chaveAcesso, 60),
    cnpjEmitente: txt(body.cnpjEmitente, 30),
    cnpjDestinatario: txt(body.cnpjDestinatario, 30),
    destinatario: txt(body.destinatario, 200),
    obraNome: txt(body.obraNome, 200),
    obraId: /^\d+$/.test(String(body.obraId ?? "")) ? String(body.obraId) : null,
    pedidoCompras: txt(body.pedidoCompras, 100),
    vencimento: data(body.vencimento),
    formaPagamento: txt(body.formaPagamento, 40),
    frete,
    prioridade,
    freteCte: txt(body.freteCte, 60),
    freteTransportador: txt(body.freteTransportador, 200),
    freteValor: num(body.freteValor),
    freteFormaPagamento: txt(body.freteFormaPagamento, 40),
    freteVencimento: data(body.freteVencimento),
    descricao: txt(body.descricao, 500),
    estoqueNotaId: txt(body.estoqueNotaId, 80),
    usuario,
  };
  if (!nota.numero.trim() || !nota.fornecedor.trim()) return json({ error: "Informe número e fornecedor." }, 400);

  const { data: r, error } = await admin.rpc("api_receber_nota_estoque", { p: nota });
  if (error) {
    // mensagens de validação da própria função (errcode 22023) podem ir para a tela; o resto fica só no log
    if (error.code === "22023") return json({ error: error.message }, 400);
    return falha("gravação da nota", error);
  }
  return json(r);
});
