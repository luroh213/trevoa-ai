// Edge Function: pix-criar
// Gera uma cobrança PIX no Mercado Pago para o mercado logado, para o plano escolhido.
// Chamada pelo app: POST { token, plano } → devolve o código copia-e-cola e o QR.
//
// Segredos (Supabase → Edge Functions → Secrets):
//   MP_ACCESS_TOKEN   → Access Token do Mercado Pago (NUNCA no site)
//   PIX_PAYER_EMAIL   → e-mail usado na cobrança (exigido pelo Mercado Pago)
// SUPABASE_URL e SUPABASE_SERVICE_ROLE_KEY o Supabase já injeta sozinho.

import { corsHeaders, json } from "../_shared/http.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const MP_TOKEN = Deno.env.get("MP_ACCESS_TOKEN")!;
const PAYER_EMAIL = Deno.env.get("PIX_PAYER_EMAIL") || "pagamento@fiado.app";

const sbHeaders = {
  apikey: SERVICE_KEY,
  Authorization: `Bearer ${SERVICE_KEY}`,
  "Content-Type": "application/json",
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: corsHeaders });
  if (req.method !== "POST") return json({ ok: false, erro: "Método inválido" }, 405);

  let body: { token?: string; plano?: string; meses?: number };
  try {
    body = await req.json();
  } catch {
    return json({ ok: false, erro: "Corpo inválido" }, 400);
  }
  if (!body.token) return json({ ok: false, erro: "Sem sessão" }, 401);

  // 1) Descobre o mercado pela sessão (token válido e não expirado)
  const agora = new Date().toISOString();
  const sRes = await fetch(
    `${SUPABASE_URL}/rest/v1/sessoes?token=eq.${encodeURIComponent(body.token)}&expires_at=gt.${agora}&select=mercado_id,acting_mercado_id,role`,
    { headers: sbHeaders },
  );
  const sessoes = await sRes.json();
  const sessao = Array.isArray(sessoes) ? sessoes[0] : null;
  if (!sessao) return json({ ok: false, erro: "Sessão inválida ou expirada" }, 401);
  const mercadoId = sessao.acting_mercado_id || sessao.mercado_id;
  if (!mercadoId) return json({ ok: false, erro: "Nenhum mercado selecionado" }, 400);

  // 2) Plano escolhido e preço (definido no banco)
  const codigo = body.plano || "anual";
  const pRes = await fetch(
    `${SUPABASE_URL}/rest/v1/planos?codigo=eq.${encodeURIComponent(codigo)}&ativo=eq.true&select=codigo,nome,valor,flexivel`,
    { headers: sbHeaders },
  );
  const [plano] = await pRes.json();
  if (!plano) return json({ ok: false, erro: "Plano não encontrado" }, 400);
  const precoUnit = Number(plano.valor);
  if (!(precoUnit > 0)) return json({ ok: false, erro: "Este plano ainda não tem preço definido" }, 400);

  // Plano flexível: o cliente escolhe de 1 a 12 meses. Os outros planos são sempre 1 pacote.
  let meses = 1;
  if (plano.flexivel) {
    meses = Math.floor(Number(body.meses) || 1);
    if (meses < 1 || meses > 12) return json({ ok: false, erro: "Escolha de 1 a 12 meses" }, 400);
  }
  const valor = Math.round(precoUnit * meses * 100) / 100;

  // 3) Nome do mercado (só para a descrição da cobrança)
  const mRes = await fetch(
    `${SUPABASE_URL}/rest/v1/mercados?id=eq.${mercadoId}&select=nome`,
    { headers: sbHeaders },
  );
  const [mercado] = await mRes.json();

  // 4) Cria o pagamento PIX no Mercado Pago. external_reference = "mercado|plano"
  const webhook = `${SUPABASE_URL}/functions/v1/pix-webhook`;
  const mpRes = await fetch("https://api.mercadopago.com/v1/payments", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${MP_TOKEN}`,
      "Content-Type": "application/json",
      "X-Idempotency-Key": crypto.randomUUID(),
    },
    body: JSON.stringify({
      transaction_amount: valor,
      description: `${plano.nome}${plano.flexivel ? ` (${meses} mes${meses > 1 ? "es" : ""})` : ""} — ${mercado?.nome || "Fiado"}`,
      payment_method_id: "pix",
      payer: { email: PAYER_EMAIL },
      external_reference: `${mercadoId}|${codigo}|${meses}`,
      notification_url: webhook,
    }),
  });
  const pago = await mpRes.json();
  if (!mpRes.ok || !pago.id) {
    return json({ ok: false, erro: pago.message || "Não deu pra gerar o PIX" }, 502);
  }

  // 5) Guarda a cobrança para o webhook conferir depois
  await fetch(`${SUPABASE_URL}/rest/v1/pagamentos_pix`, {
    method: "POST",
    headers: { ...sbHeaders, Prefer: "return=minimal" },
    body: JSON.stringify({
      id: String(pago.id),
      mercado_id: mercadoId,
      valor,
      plano: codigo,
      status: pago.status || "pending",
    }),
  });

  const tx = pago.point_of_interaction?.transaction_data || {};
  return json({
    ok: true,
    pagamentoId: String(pago.id),
    plano: codigo,
    meses,
    valor,
    copiaECola: tx.qr_code || "",
    qrBase64: tx.qr_code_base64 || "",
  });
});
