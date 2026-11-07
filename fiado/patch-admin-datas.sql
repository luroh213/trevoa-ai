-- Patch datas do admin — rode UMA vez no SQL Editor do Supabase.
-- Permite ao admin editar a data do pagamento (pago_em) e o vencimento (pago_ate) de cada cliente.

create or replace function public.fiado_admin_definir_datas(
  p_token text,
  p_mercado_id uuid,
  p_pago_em timestamptz,     -- null = não muda
  p_vence_em timestamptz,    -- null = não muda (se p_vitalicio = false)
  p_vitalicio boolean        -- true = sem vencimento
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

  if p_vitalicio then
    update mercados set pago = true, pago_ate = null where id = p_mercado_id;
  elsif p_vence_em is not null then
    update mercados
       set pago_ate = p_vence_em,
           pago = (p_vence_em > now())
     where id = p_mercado_id;
  end if;

  if p_pago_em is not null then
    update mercados set pago_em = p_pago_em where id = p_mercado_id;
  end if;

  if not found then
    return json_build_object('ok', false, 'erro', 'Mercado não encontrado');
  end if;
  return json_build_object('ok', true);
end;
$$;

grant execute on function public.fiado_admin_definir_datas(text, uuid, timestamptz, timestamptz, boolean) to anon, authenticated;
