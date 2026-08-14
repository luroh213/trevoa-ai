-- Diário do balcão na nuvem (rode no SQL Editor se o projeto já existia antes)
-- Permite acompanhar lançamentos no PC em tempo quase real.

create table if not exists public.diario_eventos (
  id uuid primary key,
  mercado_id uuid not null references public.mercados(id) on delete cascade,
  texto text not null,
  ts bigint not null,
  criado_em timestamptz not null default now()
);

create index if not exists diario_mercado_ts_idx on public.diario_eventos(mercado_id, ts desc);

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
      limit 500
    );

  return json_build_object('ok', true);
end;
$$;

create or replace function public.fiado_listar_diario(
  p_token text,
  p_limite int default 120
)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  s sessoes;
  mid uuid;
  lim int := greatest(1, least(coalesce(p_limite, 120), 500));
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
    order by d.ts desc
    limit lim
  ) t;

  return json_build_object('ok', true, 'eventos', result);
end;
$$;

grant execute on function public.fiado_registrar_diario(text, uuid, text, bigint) to anon, authenticated;
grant execute on function public.fiado_listar_diario(text, int) to anon, authenticated;

alter table public.diario_eventos enable row level security;
