-- Patch planos — rode UMA vez no SQL Editor do Supabase.
-- Planos: mensal flexível (cliente escolhe 1 a 12 meses), trimestral, anual e vitalício.

create table if not exists public.planos (
  codigo text primary key,
  nome text not null,
  dias int,              -- dias de validade por unidade (null = vitalício)
  valor numeric(12,2),   -- preço por unidade (null = ainda sem preço)
  flexivel boolean not null default false,  -- true = cliente escolhe a quantidade de meses
  ativo boolean not null default true
);

alter table public.planos add column if not exists flexivel boolean not null default false;

alter table public.planos enable row level security;

insert into public.planos (codigo, nome, dias, valor, flexivel) values
  ('mensal', 'Mensal (escolha os meses)', 30, 17, true),
  ('trimestral', 'Plano 3 meses', 90, 59, false),
  ('anual', 'Plano anual', 365, 197, false),
  ('vitalicio', 'Plano vitalício', null, 497, false)
on conflict (codigo) do update
  set nome = excluded.nome,
      dias = excluded.dias,
      valor = excluded.valor,
      flexivel = excluded.flexivel;

-- Guarda qual plano foi pago em cada cobrança
alter table public.pagamentos_pix add column if not exists plano text;

-- Lista pública dos planos com preço (sem senha)
create or replace function public.fiado_listar_planos()
returns json
language sql
security definer
set search_path = public
as $$
  select json_build_object(
    'ok', true,
    'planos', coalesce(
      (select json_agg(json_build_object(
                'codigo', p.codigo,
                'nome', p.nome,
                'dias', p.dias,
                'valor', p.valor,
                'flexivel', p.flexivel
              ) order by p.valor)
         from planos p
        where p.ativo and p.valor is not null),
      '[]'::json)
  );
$$;

grant execute on function public.fiado_listar_planos() to anon, authenticated;

-- Validade do mercado logado + data do último pagamento aprovado
create or replace function public.fiado_mercado_validade(p_token text)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  s sessoes;
  m mercados;
  ultimo timestamptz;
begin
  s := _sessao_ok(p_token);
  select * into m from mercados where id = _mercado_ativo(s);
  if not found then
    return json_build_object('ok', false, 'erro', 'Nenhum mercado selecionado');
  end if;

  select max(pago_em) into ultimo
    from pagamentos_pix
   where mercado_id = m.id and status = 'approved';

  return json_build_object(
    'ok', true,
    'pago', m.pago,
    'pagoAte', m.pago_ate,
    'trialInicio', m.trial_inicio,
    'ultimoPagamento', ultimo
  );
end;
$$;

-- Para mudar um preço depois, por exemplo:
--   update planos set valor = 19 where codigo = 'mensal';
