-- Fiado — LIXEIRA (recuperar lançamentos apagados)
-- Rode no SQL Editor do Supabase DEPOIS do supabase-schema.sql (uma vez).
--
-- Como funciona:
-- 1) Trigger copia cada movimento deletado para public.movimentos_lixeira.
-- 2) fiado_salvar_caderno (regravado abaixo) limpa da lixeira o que voltou
--    pro caderno — sobram só os apagados de verdade.
-- 3) fiado_listar_lixeira devolve os apagados pro app (botão Lixeira).
-- 4) Restaurar é pelo app: o item volta pro caderno e o save seguinte
--    tira ele da lixeira automaticamente.
-- Custo: ~200 bytes por item, poda em 1000 por mercado. Irrelevante no free tier.

create table if not exists public.movimentos_lixeira (
  mov_id uuid not null,
  mercado_id uuid not null,
  cliente_id uuid,
  cliente_nome text not null default '',
  tipo text not null,
  valor numeric(12,2) not null,
  nota text default '',
  data_ref date,
  forma text,
  ts timestamptz,
  apagado_em timestamptz not null default now(),
  primary key (mov_id, apagado_em)
);

create index if not exists lixeira_mercado_idx
  on public.movimentos_lixeira(mercado_id, apagado_em desc);

-- ─── Trigger: copia antes de apagar ─────────────────────
create or replace function public._lixeira_guardar()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  vn text;
begin
  select nome into vn from public.clientes where id = old.cliente_id;
  insert into public.movimentos_lixeira
    (mov_id, mercado_id, cliente_id, cliente_nome, tipo, valor, nota, data_ref, forma, ts)
  values
    (old.id, old.mercado_id, old.cliente_id, coalesce(vn, ''), old.tipo, old.valor,
     old.nota, old.data_ref, old.forma, old.ts);
  return old;
end;
$$;

drop trigger if exists movimentos_lixeira_del on public.movimentos;
create trigger movimentos_lixeira_del
  before delete on public.movimentos
  for each row execute function public._lixeira_guardar();

-- ─── salvar_caderno: mesma lógica + limpeza da lixeira ──
create or replace function public.fiado_salvar_caderno(p_token text, p_clientes json)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  s sessoes;
  mid uuid;
  cli json;
  mov json;
  cid uuid;
  mid_mov uuid;
begin
  s := _sessao_ok(p_token);
  mid := _mercado_ativo(s);
  if mid is null then
    raise exception 'Selecione um mercado';
  end if;

  -- Substitui o caderno inteiro (simples e confiável pro app atual)
  delete from movimentos where mercado_id = mid;
  delete from clientes where mercado_id = mid;

  for cli in select * from json_array_elements(p_clientes)
  loop
    cid := coalesce((cli->>'id')::uuid, gen_random_uuid());
    insert into clientes(id, mercado_id, nome, fone, obs, limite, criado_em)
    values (
      cid,
      mid,
      coalesce(cli->>'nome', 'Sem nome'),
      coalesce(cli->>'fone', ''),
      coalesce(cli->>'obs', ''),
      nullif(cli->>'limite', '')::numeric,
      case
        when cli->>'criadoEm' is not null and cli->>'criadoEm' <> ''
          then to_timestamp((cli->>'criadoEm')::double precision / 1000.0)
        else now()
      end
    );

    if cli->'movs' is not null and json_typeof(cli->'movs') = 'array' then
      for mov in select * from json_array_elements(cli->'movs')
      loop
        mid_mov := coalesce((mov->>'id')::uuid, gen_random_uuid());
        insert into movimentos(id, mercado_id, cliente_id, tipo, valor, nota, data_ref, forma, ts)
        values (
          mid_mov,
          mid,
          cid,
          mov->>'tipo',
          (mov->>'valor')::numeric,
          coalesce(mov->>'nota', ''),
          nullif(mov->>'dataRef', '')::date,
          nullif(mov->>'forma', ''),
          case
            when mov->>'ts' is not null and mov->>'ts' <> ''
              then to_timestamp((mov->>'ts')::double precision / 1000.0)
            else now()
          end
        );
      end loop;
    end if;
  end loop;

  -- Lixeira: o que voltou pro caderno não é mais "apagado"
  delete from movimentos_lixeira l
  where l.mercado_id = mid
    and exists (select 1 from movimentos m where m.id = l.mov_id);

  -- Poda: no máx 1000 itens por mercado
  delete from movimentos_lixeira l
  where l.mercado_id = mid
    and (l.mov_id, l.apagado_em) not in (
      select mov_id, apagado_em from movimentos_lixeira
      where mercado_id = mid order by apagado_em desc limit 1000
    );

  return json_build_object('ok', true, 'qtd', json_array_length(p_clientes));
end;
$$;

-- ─── Listar lixeira (app, botão Lixeira) ────────────────
create or replace function public.fiado_listar_lixeira(p_token text, p_limite int default 300)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  s sessoes;
  mid uuid;
  lim int := greatest(1, least(coalesce(p_limite, 300), 1000));
  result json;
begin
  s := _sessao_ok(p_token);
  mid := _mercado_ativo(s);
  if mid is null then
    raise exception 'Selecione um mercado';
  end if;

  select coalesce(json_agg(json_build_object(
    'movId', t.mov_id,
    'clienteId', t.cliente_id,
    'clienteNome', t.cliente_nome,
    'tipo', t.tipo,
    'valor', t.valor,
    'nota', t.nota,
    'dataRef', t.data_ref,
    'forma', t.forma,
    'ts', extract(epoch from t.ts) * 1000,
    'apagadoEm', extract(epoch from t.apagado_em) * 1000
  ) order by t.apagado_em desc), '[]'::json)
  into result
  from (
    select * from movimentos_lixeira
    where mercado_id = mid
    order by apagado_em desc
    limit lim
  ) t;

  return json_build_object('ok', true, 'itens', result);
end;
$$;

-- ─── Permissões ─────────────────────────────────────────
grant execute on function public.fiado_listar_lixeira(text, int) to anon, authenticated;
grant execute on function public.fiado_salvar_caderno(text, json) to anon, authenticated;
revoke execute on function public._lixeira_guardar() from public, anon, authenticated;
alter table public.movimentos_lixeira enable row level security;
-- Sem policies: ninguém lê a lixeira direto, só via RPC acima.
