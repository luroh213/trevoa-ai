-- Patch financeiro do admin — rode UMA vez no SQL Editor do Supabase.
-- Mostra quanto já foi recebido com PIX, por mês e os últimos pagamentos.

create or replace function public.fiado_admin_financeiro(p_token text)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  s sessoes;
  total numeric;
  quantidade int;
  por_mes json;
  ultimos json;
begin
  s := _sessao_ok(p_token);
  if s.role <> 'admin' then
    raise exception 'Só o administrador pode ver isso';
  end if;

  select coalesce(sum(valor), 0), count(*) into total, quantidade
    from pagamentos_pix
   where status = 'approved';

  select coalesce(json_agg(x order by x.mes desc), '[]'::json) into por_mes
  from (
    select to_char(date_trunc('month', pago_em), 'YYYY-MM') as mes,
           sum(valor) as total,
           count(*) as quantidade
      from pagamentos_pix
     where status = 'approved' and pago_em is not null
     group by 1
     order by 1 desc
     limit 12
  ) x;

  select coalesce(json_agg(y), '[]'::json) into ultimos
  from (
    select p.id,
           p.valor,
           p.plano,
           p.pago_em as "pagoEm",
           m.nome as mercado,
           m.usuario as usuario
      from pagamentos_pix p
      left join mercados m on m.id = p.mercado_id
     where p.status = 'approved'
     order by p.pago_em desc nulls last
     limit 10
  ) y;

  return json_build_object(
    'ok', true,
    'total', total,
    'quantidade', quantidade,
    'porMes', por_mes,
    'ultimos', ultimos
  );
end;
$$;

grant execute on function public.fiado_admin_financeiro(text) to anon, authenticated;
