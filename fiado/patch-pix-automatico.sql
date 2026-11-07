-- Patch PIX automático — rode UMA vez no SQL Editor do Supabase
-- Guarda até quando o mercado está pago e registra cada cobrança PIX.
-- As Edge Functions (pix-criar e pix-webhook) usam a service role, então
-- não precisam de RPC nem de permissão para anon.

-- 1) Validade da licença paga
alter table public.mercados add column if not exists pago_ate timestamptz;

-- 2) Registro de cada cobrança PIX
create table if not exists public.pagamentos_pix (
  id text primary key,                       -- id do pagamento no Mercado Pago
  mercado_id uuid references public.mercados(id) on delete cascade,
  valor numeric(12,2) not null,
  status text not null default 'pending',    -- pending | approved | rejected | ...
  criado_em timestamptz not null default now(),
  pago_em timestamptz
);

create index if not exists pagamentos_pix_mercado_idx on public.pagamentos_pix(mercado_id);

-- Só o servidor (service role) mexe nessa tabela
alter table public.pagamentos_pix enable row level security;

-- 3) Licença paga expira sozinha: tira o "pago" de quem passou da validade
--    (o app já lê mercados.pago; quando vira false, volta a mostrar a tela de cobrança)
create or replace function public.pix_expirar_licencas()
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  n int;
begin
  update mercados
     set pago = false
   where pago = true
     and pago_ate is not null
     and pago_ate < now();
  get diagnostics n = row_count;
  return n;
end;
$$;

revoke execute on function public.pix_expirar_licencas() from public, anon, authenticated;
