# Backup diario do Fiado rodando no GitHub Actions (nao depende do PC ligado).
# Config vem do segredo FIADO_BACKUP_CONFIG = conteudo inteiro de backup-config.json.
# Nao imprime dados de cliente no log nem salva arquivo no repositorio: so manda por e-mail.
import json
import os
import smtplib
import urllib.request
from datetime import datetime, timedelta, timezone
from email.message import EmailMessage

cfg = json.loads(os.environ["FIADO_BACKUP_CONFIG"])


def rpc(nome, corpo):
    req = urllib.request.Request(
        f"{cfg['supabaseUrl']}/rest/v1/rpc/{nome}",
        data=json.dumps(corpo).encode("utf-8"),
        headers={
            "apikey": cfg["anonKey"],
            "Authorization": f"Bearer {cfg['anonKey']}",
            "Content-Type": "application/json",
        },
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=120) as r:
        return json.loads(r.read().decode("utf-8"))


login = rpc("fiado_login", {"p_usuario": cfg["adminUsuario"], "p_senha": cfg["adminSenha"]})
if not login.get("ok"):
    raise SystemExit("Login admin falhou")

bk = rpc("fiado_admin_backup", {"p_token": login["token"]})
if not bk.get("ok"):
    raise SystemExit("Backup falhou")

stamp = datetime.now(timezone(timedelta(hours=-3))).strftime("%Y%m%d-%H%M")
mercados = len(bk.get("mercados") or [])
clientes = len(bk.get("clientes") or [])
movs = len(bk.get("movimentos") or [])

msg = EmailMessage()
msg["From"] = cfg["emailPara"]
msg["To"] = cfg["emailPara"]
msg["Subject"] = f"Backup Fiado {stamp} - {mercados} mercados, {clientes} clientes, {movs} lancamentos"
msg.set_content(
    "Backup diario em anexo (feito pelo GitHub, nao precisa do PC ligado).\n"
    f"Mercados: {mercados}\nClientes: {clientes}\nLancamentos: {movs}\nGerado em: {bk.get('geradoEm')}"
)
msg.add_attachment(
    json.dumps(bk, ensure_ascii=False, indent=1).encode("utf-8"),
    maintype="application",
    subtype="json",
    filename=f"backup-fiado-{stamp}.json",
)

with smtplib.SMTP("smtp.gmail.com", 587, timeout=120) as s:
    s.starttls()
    s.login(cfg["emailPara"], cfg["emailAppPassword"])
    s.send_message(msg)

print(f"OK {stamp}: {mercados} mercados, {clientes} clientes, {movs} lancamentos")
