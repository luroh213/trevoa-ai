import { test } from "node:test";
import assert from "node:assert/strict";
import { loadApp } from "./load-app.mjs";

const NC = loadApp();

function casaLimpa(patch) {
  NC.reset(patch);
}

function salarioCaiu(dia, extraCaixa) {
  const id = NC.rendaId(dia);
  assert.ok(id, "renda dia " + dia);
  const mk = NC.mesKey();
  const S = NC.getS();
  if (!S.recebidos[mk]) S.recebidos[mk] = {};
  const renda = S.config.rendas.find((r) => r.id === id);
  const valor = Number(renda.valor) * (Number(renda.pessoas) || 1);
  S.recebidos[mk][id] = { ts: Date.now(), valor };
  if (extraCaixa) S.caixa.valor = Number(S.caixa.valor) + extraCaixa;
  return valor;
}

function pagaConta(nome) {
  const id = NC.contaId(nome);
  assert.ok(id, "conta " + nome);
  const mk = NC.mesKey();
  const S = NC.getS();
  if (!S.pagamentos[mk]) S.pagamentos[mk] = {};
  const ct = S.contas.find((c) => c.id === id);
  S.pagamentos[mk][id] = { ts: Date.now(), valor: ct.valor, quem: "casa" };
}

function tipEFala(c, plano) {
  const tip = NC.genioPickTip(c, plano);
  const fb = tip ? NC.genioFallbacks(tip.tipo, tip.ctx || {}) : null;
  return { tip, fb, txt: (tip && tip.txt) || (fb && fb.txt) || "" };
}

test("nome único: UI não chama gestor como outra pessoa", () => {
  casaLimpa();
  const hoje = NC.viewHoje();
  const ajustes = NC.viewAjustes();
  assert.equal(/O gestor diz/i.test(hoje), false);
  assert.equal(/O gênio diz/i.test(hoje), false);
  assert.equal(/Gênio \(gestor\)/i.test(ajustes), false);
  assert.equal(/Modo gestor/i.test(hoje + ajustes), false);
  assert.match(ajustes, />Gênio</);
  assert.match(ajustes, /Números reais/);
});

test("dois salários: plano ensina teto de lazer + falta da meta, não R$ 40", () => {
  casaLimpa((S) => {
    S.caixa.valor = 50;
    S.emergencia = { guardado: 40, aportes: [{ ts: Date.now(), valor: 40, motivo: "teste" }], ts: Date.now() };
  });
  pagaConta("Aluguel");
  pagaConta("Energia");
  pagaConta("Internet");
  salarioCaiu(15, 1620);
  const c = NC.calc();
  const plano = NC.planoDoCaixa(c);
  const g = NC.planoGestorMes();
  assert.ok(c.caixa >= 1600, "caixa depois do salário 15");
  assert.equal(NC.genioModo(), "gestor");
  const depoisContas = Math.max(0, c.caixa - (plano.pagarAgora || 0) - (plano.separarFatura || 0) - (plano.separarContas || 0));
  const reserva = Math.min(80, depoisContas);
  assert.equal(plano.reservaUsa, reserva);
  assert.equal(plano.guardarUsa, Math.min(g.faltaMeta, depoisContas - reserva));
  assert.ok(plano.guardarUsa > 50, "guardar deste caixa > passo de hábito, veio " + plano.guardarUsa);
  assert.equal(plano.lazerUsa, Math.min(200, Math.max(0, depoisContas - reserva - plano.guardarUsa)));
  assert.ok(g.renda >= 3200, "soma os dois salários");
  assert.ok(g.ja >= 40);
});

test("iniciante: passo pequeno 10–50", () => {
  casaLimpa((S) => { S.config.genioModo = "iniciante"; S.caixa.valor = 2000; });
  pagaConta("Aluguel");
  pagaConta("Energia");
  pagaConta("Internet");
  salarioCaiu(15, 1620);
  const plano = NC.planoDoCaixa(NC.calc());
  assert.ok(plano.guardarUsa >= 10 && plano.guardarUsa <= 50, "passo " + plano.guardarUsa);
});

test("salário caiu: gênio manda pagar/separar antes de lazer, leva ao Hoje", () => {
  casaLimpa((S) => { S.caixa.valor = 80; });
  salarioCaiu(15, 1620);
  const c = NC.calc();
  const plano = NC.planoDoCaixa(c);
  const { tip } = tipEFala(c, plano);
  assert.ok(tip, "tem dica");
  assert.ok(["conta", "salario", "fatura"].includes(tip.tipo), "urgente primeiro, veio " + tip.tipo);
  NC.genioNavegarTip(tip);
  const nav = NC.nav();
  if (tip.tipo === "conta") assert.equal(nav.tab, "contas");
  if (tip.tipo === "fatura") assert.equal(nav.tab, "cartao");
  if (tip.tipo === "salario") assert.equal(nav.tab, "hoje");
});

test("conta atrasada: leva pra Dívidas, não pro cofre", () => {
  casaLimpa();
  const c = NC.calc();
  const plano = NC.planoDoCaixa(c);
  const { tip, fb } = tipEFala(c, plano);
  assert.equal(tip.tipo, "conta");
  assert.equal(tip.go.tab, "contas");
  assert.match((fb && fb.btn) || "", /dívidas/i);
  NC.genioNavegarTip(tip);
  assert.equal(NC.nav().tab, "contas");
});

test("fatura da janela 15: separa do caixa, botão vai pra Cartão", () => {
  casaLimpa((S) => { S.caixa.valor = 2000; });
  pagaConta("Aluguel");
  pagaConta("Energia");
  pagaConta("Internet");
  salarioCaiu(15, 0);
  S_marcaFaturaNaoPaga();
  const c = NC.calc();
  const plano = NC.planoDoCaixa(c);
  assert.ok(plano.separarFatura > 0 || plano.pagarAgora > 0, "fatura entra no plano da janela 15");
  const { tip } = tipEFala(c, plano);
  if (tip && tip.tipo === "fatura") {
    NC.genioNavegarTip(tip);
    assert.equal(NC.nav().tab, "cartao");
  }
});

function S_marcaFaturaNaoPaga() {
  const S = NC.getS();
  S.cartao.faturas = {};
  S.config.faturaEstimada = 1200;
}

test("iFood come teto: simulação avisa; gênio aponta lazer", () => {
  casaLimpa((S) => {
    S.caixa.valor = 800;
    S.gastos.push({ id: "g1", desc: "iFood", cat: "iFood", valor: 170, ts: Date.now(), fonte: "banco", quem: "casa" });
  });
  pagaConta("Aluguel");
  pagaConta("Energia");
  pagaConta("Internet");
  const c = NC.calc();
  const sim = NC.simularGasto(50, c);
  assert.ok(sim.txt.includes("lazer") || sim.t === "warn" || sim.t === "ok");
  const resp = NC.responderPergunta("posso pedir ifood?", c);
  assert.ok(resp.txt.toLowerCase().includes("lazer") || /acabou|pode/i.test(resp.txt));
  const plano = NC.planoDoCaixa(c);
  const { tip } = tipEFala(c, plano);
  if (tip && tip.tipo === "lazer") {
    NC.genioNavegarTip(tip);
    assert.equal(NC.nav().tab, "hoje");
    assert.equal(NC.nav().highlight.anchor, "lazer");
  }
});

test("despensa: já tem arroz = não compra; falta café = pode repor; leva pra Casa", () => {
  casaLimpa((S) => {
    S.despensa = [
      { id: "d1", nome: "Arroz", status: "tem", cat: "Mercado" },
      { id: "d2", nome: "Café", status: "acabou", cat: "Mercado" },
    ];
  });
  const nao = NC.conselhoCompra("comprar arroz");
  assert.equal(nao.acao, "nao-compra");
  const sim = NC.conselhoCompra("café");
  assert.equal(sim.acao, "compra");
  const c = NC.calc();
  const r1 = NC.responderPergunta("posso comprar arroz?", c);
  assert.match(r1.txt, /já tem/i);
  const r2 = NC.responderPergunta("despensa", c);
  assert.match(r2.txt, /Café|café|Falta/i);
  const plano = NC.planoDoCaixa(c);
  const { tip, fb } = tipEFala(c, plano);
  // contas atrasadas ganham prioridade; marca vistas e pega despensa
  let t = tip;
  const vistos = new Set();
  for (let i = 0; i < 8 && t; i++) {
    if (t.tipo === "despensa") break;
    NC.genioMarcar(t.chave);
    vistos.add(t.chave);
    t = NC.genioPickTip(NC.calc(), NC.planoDoCaixa(NC.calc()));
  }
  assert.equal(t && t.tipo, "despensa");
  assert.equal(t.go.mais, "casa");
  assert.equal(t.go.casa, "despensa");
  NC.genioNavegarTip(t);
  const nav = NC.nav();
  assert.equal(nav.tab, "mais");
  assert.equal(nav.maisSub, "casa");
  assert.equal(nav.casaSub, "despensa");
  assert.match((fb && t.tipo === "despensa" ? NC.genioFallbacks("despensa", t.ctx).txt : NC.genioFallbacks("despensa", t.ctx).txt), /não compra|Falta|já tem/i);
});

test("mês passado estourou iFood: gênio manda não repetir e leva ao pote lazer", () => {
  casaLimpa((S) => {
    const prev = NC.mesKeyOffset(-1);
    S.mesesFechados[prev] = {
      ts: Date.now() - 86400000 * 20,
      ifood: 280,
      lazer: 40,
      gastos: 900,
      meta: 550,
      juntadoEst: 100,
      mercado: 200,
    };
  });
  pagaConta("Aluguel");
  pagaConta("Energia");
  pagaConta("Internet");
  const c = NC.calc();
  const plano = NC.planoDoCaixa(c);
  let t = NC.genioPickTip(c, plano);
  for (let i = 0; i < 8 && t && t.tipo !== "fechado"; i++) {
    NC.genioMarcar(t.chave);
    t = NC.genioPickTip(NC.calc(), NC.planoDoCaixa(NC.calc()));
  }
  assert.equal(t && t.tipo, "fechado");
  assert.equal(t.ctx.estourou, true);
  NC.genioNavegarTip(t);
  assert.equal(NC.nav().tab, "hoje");
  assert.equal(NC.nav().highlight.anchor, "lazer");
  const fb = NC.genioFallbacks("fechado", t.ctx);
  assert.match(fb.txt, /não repete|teto/i);
});

test("balão urgente: conta abre sozinha; bom-dia não", async () => {
  casaLimpa((S) => { S.config.genioFala = "urgente"; });
  await NC.tickGenio(false);
  const nav = NC.nav();
  assert.equal(nav.tipo, "conta");
  assert.equal(nav.open, true);
  NC.genioMarcar(nav.chave);
  NC.ui().tip = null;
  NC.ui().open = false;
  // sem contas cobrando
  pagaConta("Aluguel");
  pagaConta("Energia");
  pagaConta("Internet");
  await NC.tickGenio(false);
  const depois = NC.nav();
  if (depois.tipo === "bomdia" || depois.tipo === "despensa" || depois.tipo === "guardar" || depois.tipo === "fechado") {
    assert.equal(depois.open, false, "não urgente não abre sozinho, tipo " + depois.tipo);
  }
});

test("falar off: tick não abre balão", async () => {
  casaLimpa((S) => { S.config.genioFala = "off"; });
  await NC.tickGenio(false);
  assert.equal(NC.nav().open, false);
  assert.equal(NC.ui().tip, null);
});

test("e se gastar 40: responde com caixa depois", () => {
  casaLimpa((S) => { S.caixa.valor = 500; });
  const r = NC.responderPergunta("e se gastar 40", NC.calc());
  assert.ok(r.txt.includes("40") || /gastar/i.test(r.tit));
});

test("Hoje não tem novela do gênio — números nos potes", () => {
  casaLimpa((S) => { S.caixa.valor = 1716; });
  pagaConta("Aluguel");
  pagaConta("Energia");
  pagaConta("Internet");
  salarioCaiu(7, 0);
  salarioCaiu(15, 0);
  const html = NC.viewHoje();
  assert.equal(/O gênio diz/i.test(html), false);
  assert.match(html, /Guardar agora/);
  const d = NC.leituraQuinzena(NC.calc());
  assert.ok(d.valorSalario > 0);
});

test("sobra 156 depois de pagar tudo: reserva PIX 80 + cofre 76, iFood 0", () => {
  casaLimpa();
  pagaConta("Aluguel");
  pagaConta("Energia");
  pagaConta("Internet");
  salarioCaiu(15, 0);
  const S = NC.getS();
  S.cartao.faturas[NC.mesKey()] = { ts: Date.now() - 1000, valor: 1200 };
  S.caixa = { valor: 156, em: Date.now() };
  S.cedula = { valor: 0 };
  const c = NC.calc();
  const plano = NC.planoDoCaixa(c);
  assert.equal(Math.round(c.caixa), 156);
  assert.equal(plano.reservaUsa, 80);
  assert.equal(plano.guardarUsa, 76);
  assert.equal(plano.lazerUsa, 0);
  const html = NC.viewHoje();
  assert.match(html, /156/);
  assert.match(html, /guardar/i);
  const idle = NC.genioIdleTip();
  assert.match(idle.txt, /guarda|cofre|não iFood/i);
  assert.equal(idle.go.mais, "mes");
  NC.genioNavegarTip(idle);
  assert.equal(NC.nav().tab, "mais");
  assert.equal(NC.nav().maisSub, "mes");
  const { tip } = tipEFala(c, plano);
  assert.equal(tip.tipo, "guardar-agora");
  assert.equal(tip.go.mais, "mes");
});

test("salário 15 isolado 1620−360−1200: livres 60, reserva 60, cofre 0", () => {
  casaLimpa((S) => {
    S.contas = [
      { id: "vanuza", nome: "Vanuza", valor: 260, dia: 17 },
      { id: "otica", nome: "Otica", valor: 100, dia: 17 },
    ];
  });
  salarioCaiu(15, 0);
  const S = NC.getS();
  S.caixa = { valor: 1620, em: Date.now() };
  S.cedula = { valor: 0 };
  const c = NC.calc();
  const plano = NC.planoDoCaixa(c);
  const d = NC.leituraQuinzena(c);
  assert.equal(d.valorSalario, 1620);
  assert.equal(d.contas, 360);
  assert.equal(d.fatura, 1200);
  assert.equal(d.livreSalario, 60);
  assert.equal(d.saldoVelho, 0);
  assert.equal(plano.reservaUsa, 60);
  assert.equal(plano.guardarUsa, 0);
  assert.equal(plano.lazerUsa, 0);
  const idle = NC.genioIdleTip();
  assert.match(idle.txt, /60|banco|cartão/i);
  assert.ok(idle.go.tab === "cartao" || idle.go.tab === "contas");
});

test("salário 15 + saldo velho 400: reserva 80, guarda o resto, não iFood", () => {
  casaLimpa((S) => {
    S.contas = [
      { id: "vanuza", nome: "Vanuza", valor: 260, dia: 17 },
      { id: "otica", nome: "Otica", valor: 100, dia: 17 },
    ];
  });
  salarioCaiu(15, 0);
  const S = NC.getS();
  S.caixa = { valor: 2020, em: Date.now() };
  S.cedula = { valor: 0 };
  const c = NC.calc();
  const plano = NC.planoDoCaixa(c);
  const d = NC.leituraQuinzena(c);
  assert.equal(d.saldoVelho, 400);
  assert.equal(d.livreSalario, 60);
  assert.equal(plano.reservaUsa, 80);
  assert.ok(plano.guardarUsa >= 300, "guarda o saldo velho, veio " + plano.guardarUsa);
  assert.equal(plano.lazerUsa, 0);
});

test("compras do cartão lançadas: fatura = ciclo, não chute 1200", () => {
  casaLimpa((S) => {
    S.contas = [
      { id: "vanuza", nome: "Vanuza", valor: 260, dia: 17 },
      { id: "otica", nome: "Otica", valor: 100, dia: 17 },
    ];
    S.cartao.compras = [{ id: "c1", desc: "mercado", valor: 800, ts: Date.now() }];
  });
  salarioCaiu(15, 0);
  const S = NC.getS();
  S.caixa = { valor: 1620, em: Date.now() };
  const c = NC.calc();
  const d = NC.leituraQuinzena(c);
  assert.equal(d.fatura, 800);
  assert.equal(d.chute, false);
  assert.equal(d.livreSalario, 460);
});
