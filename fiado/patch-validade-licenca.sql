-- Patch validade da licença paga — rode UMA vez no SQL Editor do Supabase
-- Cria uma função NOVA (não mexe no login nem em nenhuma função existente)
-- que devolve até quando o mercado logado está pago.

create or replace function public.fiado_mercado_validade(p_token text)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  s sessoes;
  m mercados;
begin
  s := _sessao_ok(p_token);
  select * into m from mercados where id = _mercado_ativo(s);
  if not found then
    return json_build_object('ok', false, 'erro', 'Nenhum mercado selecionado');
  end if;
  return json_build_object(
    'ok', true,
    'pago', m.pago,
    'pagoAte', m.pago_ate,
    'trialInicio', m.trial_inicio
  );
end;
$$;

grant execute on function public.fiado_mercado_validade(text) to anon, authenticated;
