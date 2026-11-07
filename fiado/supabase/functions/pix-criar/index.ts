// Edge Function: pix-criar
// Gera uma cobrança PIX no Mercado Pago para o mercado logado.
// Chamada pelo app: POST { token, valor } → devolve o código copia-e-cola e o QR.
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
const VALOR_PADRAO = 97;

const sbHeaders = {
  apikey: SERVICE_KEY,
  Authorization: `Bearer ${SERVICE_KEY}`,
  "Content-Type": "application/json",
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: corsHeaders });
  if (req.method !== "POST") return json({ ok: false, erro: "Método inválido" }, 405);

  let body: { token?: string; valor?: number };
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

  // 2) Valor da licença (o cadastrado no admin, se não vier do app)
  const mRes = await fetch(
    `${SUPABASE_URL}/rest/v1/mercados?id=eq.${mercadoId}&select=valor_licenca,nome`,
    { headers: sbHeaders },
  );
  const [mercado] = await mRes.json();
  const valor = Number(body.valor ?? mercado?.valor_licenca ?? VALOR_PADRAO);
  if (!(valor > 0)) return json({ ok: false, erro: "Valor inválido" }, 400);

  // 3) Cria o pagamento PIX no Mercado Pago
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
      description: `Licença Fiado — ${mercado?.nome || "mercado"}`,
      payment_method_id: "pix",
      payer: { email: PAYER_EMAIL },
      external_reference: mercadoId,
      notification_url: webhook,
    }),
  });
  const pago = await mpRes.json();
  if (!mpRes.ok || !pago.id) {
    return json({ ok: false, erro: pago.message || "Não deu pra gerar o PIX" }, 502);
  }

  // 4) Guarda a cobrança para o webhook conferir depois
  await fetch(`${SUPABASE_URL}/rest/v1/pagamentos_pix`, {
    method: "POST",
    headers: { ...sbHeaders, Prefer: "return=minimal" },
    body: JSON.stringify({
      id: String(pago.id),
      mercado_id: mercadoId,
      valor,
      status: pago.status || "pending",
    }),
  });

  const tx = pago.point_of_interaction?.transaction_data || {};
  return json({
    ok: true,
    pagamentoId: String(pago.id),
    valor,
    copiaECola: tx.qr_code || "",
    qrBase64: tx.qr_code_base64 || "",
  });
});
