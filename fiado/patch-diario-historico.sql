-- Fiado — Diário guarda mais histórico + busca por dia.
-- Rode no SQL Editor do Supabase (uma vez). Pode rodar de novo sem problema.
-- Antes: só os 500 registros mais novos por mercado (~1 semana num mercado movimentado).
-- Agora: 50.000 por mercado (~1 ano). ~150 bytes cada.

create or replace function public.fiado_registrar_diario(
  p_token text,
  p_id uuid,
  p_texto text,
  p_ts bigint
)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  s sessoes;
  mid uuid;
begin
  s := _sessao_ok(p_token);
  mid := _mercado_ativo(s);
  if mid is null then
    return json_build_object('ok', false, 'erro', 'Mercado não definido');
  end if;
  if p_id is null or coalesce(trim(p_texto), '') = '' then
    return json_build_object('ok', false, 'erro', 'Dados inválidos');
  end if;

  insert into diario_eventos(id, mercado_id, texto, ts)
  values (p_id, mid, trim(p_texto), coalesce(p_ts, (extract(epoch from now()) * 1000)::bigint))
  on conflict (id) do nothing;

  delete from diario_eventos d
  where d.mercado_id = mid
    and d.id not in (
      select id from diario_eventos
      where mercado_id = mid
      order by ts desc
      limit 50000
    );

  return json_build_object('ok', true);
end;
$$;

create or replace function public.fiado_listar_diario_periodo(
  p_token text,
  p_de bigint,
  p_ate bigint
)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  s sessoes;
  mid uuid;
  result json;
begin
  s := _sessao_ok(p_token);
  mid := _mercado_ativo(s);
  if mid is null then
    return json_build_object('ok', false, 'erro', 'Mercado não definido');
  end if;

  select coalesce(json_agg(row_to_json(t) order by t.ts desc), '[]'::json)
  into result
  from (
    select d.id, d.texto, d.ts
    from diario_eventos d
    where d.mercado_id = mid
      and d.ts >= p_de
      and d.ts < p_ate
    order by d.ts desc
    limit 3000
  ) t;

  return json_build_object('ok', true, 'eventos', result);
end;
$$;

grant execute on function public.fiado_registrar_diario(text, uuid, text, bigint) to anon, authenticated;
grant execute on function public.fiado_listar_diario_periodo(text, bigint, bigint) to anon, authenticated;
