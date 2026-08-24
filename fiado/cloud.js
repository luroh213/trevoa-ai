/**
 * Camada de nuvem do Fiado (Supabase RPC).
 * Se FIADO_CLOUD.enabled for false ou keys inválidas, o app fica no modo local.
 */
(function (global) {
  const cfg = global.FIADO_CLOUD || { enabled: false };
  const TOKEN_KEY = "fiado-cloud-token-v1";
  const META_KEY = "fiado-cloud-meta-v1";

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
    setToken("", false);
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
    const data = await rpc("fiado_login", { p_usuario: usuario, p_senha: senha });
    if (!data || !data.ok) {
      return { ok: false, erro: (data && data.erro) || "Login inválido" };
    }
    setToken(data.token, permanente);
    setMeta(
      {
        role: data.role,
        usuario: data.usuario,
        mercadoId: data.mercadoId || null,
        nome: data.nome,
        pago: !!data.pago,
        bloqueado: !!data.bloqueado,
        trialInicio: data.trialInicio || null,
        valorLicenca: data.valorLicenca,
        chavePix: data.chavePix,
        trialDias: data.trialDias,
        codigoLiberacao: data.codigoLiberacao,
        seuWhatsapp: data.seuWhatsapp,
      },
      permanente
    );
    return { ok: true, ...data };
  }

  async function logout() {
    const t = getToken();
    try {
      if (t && configured()) await rpc("fiado_logout", { p_token: t });
    } catch (_) {
      /* ignore */
    }
    clearSession();
  }

  async function carregarCaderno() {
    const data = await rpc("fiado_carregar_caderno", { p_token: getToken() });
    if (!data || !data.ok) throw new Error("Não deu pra carregar o caderno");
    const clientes = (data.clientes || []).map((c) => ({
      id: c.id,
      nome: c.nome,
      fone: c.fone || "",
      obs: c.obs || "",
      limite: c.limite == null ? null : Number(c.limite),
      criadoEm: c.criadoEm || Date.now(),
      movs: (c.movs || []).map((m) => ({
        id: m.id,
        tipo: m.tipo,
        valor: Number(m.valor),
        nota: m.nota || "",
        dataRef: m.dataRef || null,
        forma: m.forma || null,
        ts: m.ts || Date.now(),
      })),
    }));
    return clientes;
  }

  async function salvarCaderno(clientes) {
    const payload = (clientes || []).map((c) => ({
      id: c.id,
      nome: c.nome,
      fone: c.fone || "",
      obs: c.obs || "",
      limite: c.limite == null ? null : c.limite,
      criadoEm: c.criadoEm || Date.now(),
      movs: (c.movs || []).map((m) => ({
        id: m.id,
        tipo: m.tipo,
        valor: m.valor,
        nota: m.nota || "",
        dataRef: m.dataRef || null,
        forma: m.forma || null,
        ts: m.ts || Date.now(),
      })),
    }));
    const data = await rpc("fiado_salvar_caderno", {
      p_token: getToken(),
      p_clientes: payload,
    });
    if (!data || !data.ok) throw new Error("Não deu pra salvar na nuvem");
    return data;
  }

  async function listarMercados() {
    const data = await rpc("fiado_admin_listar_mercados", { p_token: getToken() });
    if (!data || !data.ok) throw new Error("Não deu pra listar mercados");
    return data.mercados || [];
  }

  async function criarMercado(usuario, senha, nome) {
    const data = await rpc("fiado_admin_criar_mercado", {
      p_token: getToken(),
      p_usuario: usuario,
      p_senha: senha,
      p_nome: nome || "Fiado",
    });
    return data;
  }

  async function abrirMercado(mercadoId) {
    const data = await rpc("fiado_admin_abrir_mercado", {
      p_token: getToken(),
      p_mercado_id: mercadoId,
    });
    if (!data || !data.ok) throw new Error("Não deu pra abrir o mercado");
    const meta = getMeta();
    setMeta(
      {
        ...meta,
        actingMercadoId: data.mercadoId,
        nome: data.nome,
        mercadoUsuario: data.usuario,
        pago: !!data.pago,
        bloqueado: !!data.bloqueado,
        trialInicio: data.trialInicio,
        valorLicenca: data.valorLicenca,
        chavePix: data.chavePix,
      },
      !!localStorage.getItem(TOKEN_KEY)
    );
    return data;
  }

  async function atualizarMercado(opts) {
    const data = await rpc("fiado_admin_atualizar_mercado", {
      p_token: getToken(),
      p_mercado_id: opts.id,
      p_nome: opts.nome ?? null,
      p_senha: opts.senha ?? null,
      p_pago: opts.pago ?? null,
      p_bloqueado: opts.bloqueado ?? null,
      p_valor: opts.valor ?? null,
      p_pix: opts.pix ?? null,
      p_reiniciar_trial: !!opts.reiniciarTrial,
    });
    return data;
  }

  async function trocarSenhaAdmin(atual, nova) {
    return rpc("fiado_admin_trocar_senha", {
      p_token: getToken(),
      p_atual: atual,
      p_nova: nova,
    });
  }

  async function atualizarPerfil(opts) {
    const data = await rpc("fiado_mercado_atualizar_perfil", {
      p_token: getToken(),
      p_nome: opts.nome ?? null,
      p_senha_atual: opts.senhaAtual ?? null,
      p_senha_nova: opts.senhaNova ?? null,
    });
    if (data && data.ok && data.nome) patchMeta({ nome: data.nome });
    return data;
  }

  async function mercadoInfo() {
    return rpc("fiado_mercado_info", { p_token: getToken() });
  }

  async function liberarComCodigo(codigo) {
    return rpc("fiado_liberar_com_codigo", {
      p_token: getToken(),
      p_codigo: codigo,
    });
  }

  async function registrarDiarioEvento(entry) {
    const data = await rpc("fiado_registrar_diario", {
      p_token: getToken(),
      p_id: entry.id,
      p_texto: entry.texto,
      p_ts: entry.ts,
    });
    if (!data || !data.ok) throw new Error("Não deu pra salvar no diário da nuvem");
    return data;
  }

  async function listarDiario(limite) {
    const data = await rpc("fiado_listar_diario", {
      p_token: getToken(),
      p_limite: limite || 120,
    });
    if (!data || !data.ok) throw new Error("Não deu pra carregar o diário");
    return (data.eventos || []).map((e) => ({
      id: e.id,
      texto: e.texto,
      ts: Number(e.ts) || Date.now(),
    }));
  }

  async function listarLixeira(limite) {
    const data = await rpc("fiado_listar_lixeira", {
      p_token: getToken(),
      p_limite: limite || 300,
    });
    if (!data || !data.ok) throw new Error("Não deu pra carregar a lixeira");
    return (data.itens || []).map((m) => ({
      movId: m.movId,
      clienteId: m.clienteId || null,
      clienteNome: m.clienteNome || "",
      tipo: m.tipo,
      valor: Number(m.valor),
      nota: m.nota || "",
      dataRef: m.dataRef || null,
      forma: m.forma || null,
      ts: Number(m.ts) || Date.now(),
      apagadoEm: Number(m.apagadoEm) || Date.now(),
    }));
  }

  function tokenPermanente() {
    return !!localStorage.getItem(TOKEN_KEY);
  }

  function patchMeta(patch) {
    setMeta({ ...getMeta(), ...(patch || {}) }, tokenPermanente());
  }

  global.FiadoCloud = {
    configured,
    getToken,
    getMeta,
    setMeta,
    patchMeta,
    tokenPermanente,
    clearSession,
    login,
    logout,
    carregarCaderno,
    salvarCaderno,
    listarMercados,
    criarMercado,
    abrirMercado,
    atualizarMercado,
    atualizarPerfil,
    trocarSenhaAdmin,
    liberarComCodigo,
    mercadoInfo,
    registrarDiarioEvento,
    listarDiario,
    listarLixeira,
  };
})(window);
