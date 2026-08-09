-- Patch: perfil do mercado (o próprio cliente troca nome da loja e senha)
-- Rode UMA vez no SQL Editor do Supabase, depois do supabase-schema.sql

create or replace function public.fiado_mercado_atualizar_perfil(
  p_token text,
  p_nome text default null,
  p_senha_atual text default null,
  p_senha_nova text default null
)
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
  if s.role <> 'user' then
    raise exception 'Só o próprio mercado';
  end if;
  select * into m from mercados where id = s.mercado_id;
  if not found then
    raise exception 'Mercado não encontrado';
  end if;

  if p_senha_nova is not null and trim(p_senha_nova) <> '' then
    if length(trim(p_senha_nova)) < 4 then
      return json_build_object('ok', false, 'erro', 'Nova senha muito curta (mín. 4).');
    end if;
    if m.senha_hash <> crypt(coalesce(p_senha_atual, ''), m.senha_hash) then
      return json_build_object('ok', false, 'erro', 'Senha atual incorreta.');
    end if;
    update mercados set senha_hash = crypt(trim(p_senha_nova), gen_salt('bf')) where id = m.id;
  end if;

  if p_nome is not null and trim(p_nome) <> '' then
    update mercados set nome = trim(p_nome) where id = m.id;
    m.nome := trim(p_nome);
  end if;

  return json_build_object('ok', true, 'nome', m.nome);
end;
$$;

grant execute on function public.fiado_mercado_atualizar_perfil(text, text, text, text) to anon, authenticated;
