/**
 * Camada de nuvem do Corpo & Aroma (Supabase RPC).
 * Se EA_CLOUD.enabled for false ou keys inválidas, o app fica no modo local.
 */
(function (global) {
  const cfg = global.EA_CLOUD || { enabled: false };
  const TOKEN_KEY = "ea-cloud-token-v1";
  const META_KEY = "ea-cloud-meta-v1";

  function configured() {
    return !!(
      cfg.enabled &&
      cfg.url &&
      cfg.anonKey &&
      !String(cfg.url).includes("SEU_PROJETO") &&
      !String(cfg.anonKey).includes("COLE_AQUI")
    );
  }

  function getToken() {
    return sessionStorage.getItem(TOKEN_KEY) || localStorage.getItem(TOKEN_KEY) || "";
  }

  function setToken(token, permanente) {
    sessionStorage.removeItem(TOKEN_KEY);
    localStorage.removeItem(TOKEN_KEY);
    if (!token) return;
    if (permanente) localStorage.setItem(TOKEN_KEY, token);
    else sessionStorage.setItem(TOKEN_KEY, token);
  }

  function getMeta() {
    try {
      return JSON.parse(localStorage.getItem(META_KEY) || sessionStorage.getItem(META_KEY) || "null") || {};
    } catch {
      return {};
    }
  }

  function setMeta(meta, permanente) {
    const payload = JSON.stringify(meta || {});
    sessionStorage.removeItem(META_KEY);
    localStorage.removeItem(META_KEY);
    if (permanente) localStorage.setItem(META_KEY, payload);
    else sessionStorage.setItem(META_KEY, payload);
  }

  function clearSession() {
    localStorage.removeItem(TOKEN_KEY);
    sessionStorage.removeItem(TOKEN_KEY);
    localStorage.removeItem(META_KEY);
    sessionStorage.removeItem(META_KEY);
  }

  async function rpc(fn, args) {
    if (!configured()) throw new Error("Nuvem não configurada");
    const res = await fetch(`${cfg.url.replace(/\/$/, "")}/rest/v1/rpc/${fn}`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        apikey: cfg.anonKey,
        Authorization: `Bearer ${cfg.anonKey}`,
      },
      body: JSON.stringify(args || {}),
    });
    const text = await res.text();
    let data;
    try {
      data = text ? JSON.parse(text) : null;
    } catch {
      throw new Error(text || "Erro na nuvem");
    }
    if (!res.ok) {
      const msg =
        (data && (data.message || data.error || data.hint)) ||
        text ||
        `Erro HTTP ${res.status}`;
      throw new Error(msg);
    }
    return data;
  }

  async function login(usuario, senha, permanente) {
    const data = await rpc("ea_login", { p_usuario: usuario, p_senha: senha });
    if (!data || !data.ok) {
      return { ok: false, erro: (data && data.erro) || "Login inválido" };
    }
    setToken(data.token, permanente);
    setMeta({ usuario: data.usuario, nome: data.nome }, permanente);
    return { ok: true, ...data };
  }

  async function logout() {
    const t = getToken();
    try {
      if (t && configured()) await rpc("ea_logout", { p_token: t });
    } catch (_) {
      /* ignore */
    }
    clearSession();
  }

  function num(v) {
    const n = Number(v);
    return Number.isFinite(n) ? n : 0;
  }

  async function carregarTudo() {
    const data = await rpc("ea_carregar", { p_token: getToken() });
    if (!data || !data.ok) throw new Error((data && data.erro) || "Não deu pra carregar");
    setMeta({ usuario: data.usuario, nome: data.nome }, !!localStorage.getItem(TOKEN_KEY));
    return {
      nome: data.nome,
      produtos: (data.produtos || []).map((p) => ({
        id: p.id,
        nome: p.nome,
        categoria: p.categoria || "Outros",
        custo: num(p.custo),
        preco: num(p.preco),
        estoque: num(p.estoque),
        estoqueMin: num(p.estoqueMin),
        obs: p.obs || "",
        ativo: p.ativo !== false,
        criadoEm: p.criadoEm || Date.now(),
      })),
      movs: (data.movimentos || []).map((m) => ({
        id: m.id,
        produtoId: m.produtoId || null,
        produtoNome: m.produtoNome || "",
        tipo: m.tipo,
        qtd: num(m.qtd),
        valorUnit: num(m.valorUnit),
        custoUnit: num(m.custoUnit),
        total: num(m.total),
        nota: m.nota || "",
        dataRef: m.dataRef || null,
        ts: m.ts || Date.now(),
      })),
      despesas: (data.despesas || []).map((d) => ({
        id: d.id,
        descricao: d.descricao,
        categoria: d.categoria || "Outros",
        valor: num(d.valor),
        dataRef: d.dataRef || null,
        ts: d.ts || Date.now(),
      })),
    };
  }

  async function salvarTudo(state) {
    const produtos = (state.produtos || []).map((p) => ({
      id: p.id,
      nome: p.nome,
      categoria: p.categoria || "Outros",
      custo: num(p.custo),
      preco: num(p.preco),
      estoque: num(p.estoque),
      estoqueMin: num(p.estoqueMin),
      obs: p.obs || "",
      ativo: p.ativo !== false,
      criadoEm: p.criadoEm || Date.now(),
    }));
    const movimentos = (state.movs || []).map((m) => ({
      id: m.id,
      produtoId: m.produtoId || null,
      produtoNome: m.produtoNome || "",
      tipo: m.tipo,
      qtd: num(m.qtd),
      valorUnit: num(m.valorUnit),
      custoUnit: num(m.custoUnit),
      total: num(m.total),
      nota: m.nota || "",
      dataRef: m.dataRef || null,
      ts: m.ts || Date.now(),
    }));
    const despesas = (state.despesas || []).map((d) => ({
      id: d.id,
      descricao: d.descricao,
      categoria: d.categoria || "Outros",
      valor: num(d.valor),
      dataRef: d.dataRef || null,
      ts: d.ts || Date.now(),
    }));
    const data = await rpc("ea_salvar", {
      p_token: getToken(),
      p_produtos: produtos,
      p_movimentos: movimentos,
      p_despesas: despesas,
    });
    if (!data || !data.ok) throw new Error("Não deu pra salvar na nuvem");
    return data;
  }

  async function atualizarPerfil(opts) {
    const data = await rpc("ea_atualizar_perfil", {
      p_token: getToken(),
      p_nome: opts.nome ?? null,
      p_senha_atual: opts.senhaAtual ?? null,
      p_senha_nova: opts.senhaNova ?? null,
    });
    if (data && data.ok && data.nome) {
      setMeta({ ...getMeta(), nome: data.nome }, !!localStorage.getItem(TOKEN_KEY));
    }
    return data;
  }

  global.EACloud = {
    configured,
    getToken,
    getMeta,
    setMeta,
    clearSession,
    login,
    logout,
    carregarTudo,
    salvarTudo,
    atualizarPerfil,
  };
})(window);
