// Edge Function: pix-webhook
// O Mercado Pago chama esta URL quando um pagamento muda de status.
// Não confiamos no corpo da notificação: pegamos o pagamento direto na API
// do Mercado Pago (com o nosso token) e só então liberamos o mercado.
//
// Segredo necessário: MP_ACCESS_TOKEN

import { corsHeaders, json } from "../_shared/http.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const MP_TOKEN = Deno.env.get("MP_ACCESS_TOKEN")!;
const DIAS_LICENCA = 30;

const sbHeaders = {
  apikey: SERVICE_KEY,
  Authorization: `Bearer ${SERVICE_KEY}`,
  "Content-Type": "application/json",
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: corsHeaders });

  const url = new URL(req.url);
  let body: { type?: string; action?: string; data?: { id?: string | number } } = {};
  try {
    body = await req.json();
  } catch {
    /* alguns avisos chegam só pela query string */
  }

  // O Mercado Pago manda o id no corpo (data.id) ou na query (data.id=...)
  const paymentId =
    body?.data?.id ?? url.searchParams.get("data.id") ?? url.searchParams.get("id");
  const tipo = body?.type ?? url.searchParams.get("type") ?? url.searchParams.get("topic");
  if (!paymentId || (tipo && tipo !== "payment")) {
    return json({ ok: true, ignorado: true });
  }

  try {
    // 1) Confere o pagamento direto na API do Mercado Pago
    const mpRes = await fetch(`https://api.mercadopago.com/v1/payments/${paymentId}`, {
      headers: { Authorization: `Bearer ${MP_TOKEN}` },
    });
    if (!mpRes.ok) return json({ ok: false, erro: "Pagamento não encontrado" }, 502);
    const pago = await mpRes.json();

    const mercadoId = pago.external_reference;
    if (!mercadoId) return json({ ok: true, ignorado: true });

    // 2) Atualiza o registro da cobrança
    await fetch(`${SUPABASE_URL}/rest/v1/pagamentos_pix?id=eq.${pago.id}`, {
      method: "PATCH",
      headers: { ...sbHeaders, Prefer: "return=minimal" },
      body: JSON.stringify({
        status: pago.status,
        pago_em: pago.status === "approved" ? new Date().toISOString() : null,
      }),
    });

    // 3) Se foi aprovado, libera o mercado pelo prazo da licença
    if (pago.status === "approved") {
      const ate = new Date(Date.now() + DIAS_LICENCA * 86400000).toISOString();
      const libRes = await fetch(`${SUPABASE_URL}/rest/v1/mercados?id=eq.${mercadoId}`, {
        method: "PATCH",
        headers: { ...sbHeaders, Prefer: "return=minimal" },
        body: JSON.stringify({ pago: true, bloqueado: false, pago_ate: ate }),
      });
      if (!libRes.ok) return json({ ok: false, erro: "Falha ao liberar" }, 500);
    }

    return json({ ok: true, status: pago.status });
  } catch (err) {
    // 500 faz o Mercado Pago tentar de novo depois
    return json({ ok: false, erro: String(err) }, 500);
  }
});
