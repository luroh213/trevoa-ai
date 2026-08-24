# Fiado na nuvem — setup (uma vez)

1. Crie um projeto em [supabase.com](https://supabase.com) (plano gratuito).
2. Abra **SQL Editor** → cole o conteúdo de `supabase-schema.sql` → **Run**.
3. Em **Project Settings → API**, copie:
   - **Project URL**
   - **anon public** key
4. Edite `config.js`:

```js
window.FIADO_CLOUD = {
  enabled: true,
  url: "https://xxxxx.supabase.co",
  anonKey: "eyJhbGciOi...",
};
```

5. Publique o site (GitHub Pages). Com `enabled: false`, o app continua só no celular (modo antigo).

6. **Diário na nuvem:** se o banco já existia, rode também `patch-diario-nuvem.sql` no SQL Editor. Assim o dono acompanha lançamentos no PC (botão **Diário**, mesmo login do mercado).

7. **Lixeira (recuperar apagados):** rode também `patch-lixeira.sql` no SQL Editor. Cria a tabela `movimentos_lixeira`, o trigger que guarda cada lançamento apagado e a RPC que alimenta o botão **Lixeira** no app (restaurar devolve o item pro caderno). Sem isso, o botão Lixeira mostra erro ao abrir.

## Contas padrão (depois do SQL)

| Quem | Usuário | Senha |
|------|---------|-------|
| Você (admin) | `admin` | `admin123` |
| Demo balcão | `mercado` | `fiado123` |

Troque a senha do admin no painel. Crie cada loja em **Mercados na nuvem**.

## Fluxo de venda

1. Admin cria mercado (`seuluiz` + senha).
2. De casa: **Abrir caderno** → cadastra clientes (fotos da caderneta).
3. Na loja: abre o link do Fiado → login do mercado → caderno já está na nuvem.
