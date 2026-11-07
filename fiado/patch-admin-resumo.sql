-- Patch do painel admin: data de liberação, resumo por mercado e vencimento editável.
-- Rode UMA vez no SQL Editor do Supabase.

-- 1) Data em que o mercado foi liberado (preenchida sozinha quando vira pago)
alter table public.mercados add column if not exists pago_em timestamptz;

create or replace function public._marcar_pago_em()
returns trigger
language plpgsql
as $$
begin
  if new.pago = true and (old.pago is distinct from true) then
    new.pago_em := now();
  end if;
  return new;
end;
$$;

drop trigger if exists trg_marcar_pago_em on public.mercados;
create trigger trg_marcar_pago_em
  before update on public.mercados
  for each row execute function public._marcar_pago_em();

-- 2) Resumo de todos os mercados para o admin (último acesso, sessões ativas, datas)
create or replace function public.fiado_admin_resumo_mercados(p_token text)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  s sessoes;
  r json;
begin
  s := _sessao_ok(p_token);
  if s.role <> 'admin' then
    raise exception 'Só o administrador pode ver isso';
  end if;

  select coalesce(json_agg(x order by x.nome), '[]'::json) into r
  from (
    select
      m.id,
      m.usuario,
      m.nome,
      m.pago,
      m.bloqueado,
      m.trial_inicio as "trialInicio",
      m.pago_ate as "pagoAte",
      m.pago_em as "pagoEm",
      (select max(se.criado_em) from sessoes se where se.mercado_id = m.id) as "ultimoAcesso",
      (select count(*) from sessoes se where se.mercado_id = m.id and se.expires_at > now()) as "sessoesAtivas"
    from mercados m
  ) x;

  return json_build_object('ok', true, 'mercados', r);
end;
$$;

-- 3) Admin define até quando um mercado está liberado (vencimento editável)
create or replace function public.fiado_admin_definir_validade(
  p_token text,
  p_mercado_id uuid,
  p_ate timestamptz
)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  s sessoes;
begin
  s := _sessao_ok(p_token);
  if s.role <> 'admin' then
    raise exception 'Só o administrador pode ver isso';
  end if;

  update mercados
     set pago_ate = p_ate,
         pago = (p_ate is null or p_ate > now())
   where id = p_mercado_id;

  if not found then
    return json_build_object('ok', false, 'erro', 'Mercado não encontrado');
  end if;
  return json_build_object('ok', true);
end;
$$;

grant execute on function public.fiado_admin_resumo_mercados(text) to anon, authenticated;
grant execute on function public.fiado_admin_definir_validade(text, uuid, timestamptz) to anon, authenticated;
