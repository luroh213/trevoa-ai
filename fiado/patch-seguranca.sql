-- Patch segurança — rode UMA vez no SQL Editor do Supabase
-- Resolve os avisos do linter: helpers internos fechados + search_path fixo

-- 1) _mercado_ativo com search_path fixo (aviso "Function Search Path Mutable")
create or replace function public._mercado_ativo(p_sess sessoes)
returns uuid
language plpgsql
stable
set search_path = public, extensions
as $$
begin
  if p_sess.role = 'admin' and p_sess.acting_mercado_id is not null then
    return p_sess.acting_mercado_id;
  end if;
  return p_sess.mercado_id;
end;
$$;

-- 2) Helpers internos: só as outras funções (security definer) chamam eles.
--    Tirar o EXECUTE de fora NÃO quebra o app — as chamadas internas rodam
--    como dono da função, não como anon.
revoke execute on function public._nova_sessao(text, uuid, uuid) from public, anon, authenticated;
revoke execute on function public._sessao_ok(text) from public, anon, authenticated;

-- Obs.: os avisos sobre fiado_* / estoque_* executáveis pelo anon são do
-- desenho do app (sem Supabase Auth — cada função valida o token da sessão).
-- Podem ser marcados como "resolvido/ignorado" no painel.
