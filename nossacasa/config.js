/* ═══════════════════════════════════════════════════════════
   CONFIG NUVEM — Nossa Casa
   Usa o MESMO projeto Supabase do fiado/corpoearoma.
   Antes de ligar: SQL Editor → rode supabase-schema.sql → Run.
   NUNCA cole a chave secret/service_role do Supabase aqui.
   IA: veja config.secrets.js (não vai pro Git; configure no aparelho se precisar).
   ═══════════════════════════════════════════════════════════ */
window.NC_CLOUD = {
  enabled: true,
  url: "https://ramxxdumwtlnpyytmpiy.supabase.co",
  anonKey: "sb_publishable_mKcIU9aNr6ONuxZxjNd_rQ_b0Qy2qGV",
};

window.NC_AI = window.NC_AI || {
  enabled: true,
  provider: "groq",
  apiKey: "",
};
