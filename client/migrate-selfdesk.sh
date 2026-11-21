#!/usr/bin/env bash
#
# migrate-selfdesk.sh
# Troca o RustDesk pelo SelfDesk num Debian/Ubuntu, MANTENDO O ID, e depois o atualiza.
# Guia: README.md deste repositorio, secao "Migrar e atualizar clientes".
#
# Instalar ou atualizar este script e rodar, num comando (o mesmo vale para as outras opcoes):
#   sudo curl -fsSLo /usr/local/sbin/migrate-selfdesk https://raw.githubusercontent.com/self-labs/selfdesk/master/client/migrate-selfdesk.sh && sudo bash /usr/local/sbin/migrate-selfdesk --update
# Nao funciona como "curl | bash": a migracao se relanca pelo proprio arquivo (veja DETACHED abaixo).
#
# Uso (como root, pelo SSH):
#   sudo bash migrate-selfdesk.sh            # migra, desacoplado do SSH (log em /var/log/migrate-selfdesk.log)
#   sudo bash migrate-selfdesk.sh --check    # so mostra o estado, nao muda nada
#   sudo bash migrate-selfdesk.sh --finalize # depois dos 3 reboots: remove o RustDesk (exige o DISPLAY certo:
#                                            # :1 nos servidores sem monitor do startxfce@, :0 nos demais)
#   sudo bash migrate-selfdesk.sh --rollback # volta para o RustDesk
#   sudo bash migrate-selfdesk.sh --crd-restart # so poe o Restart=on-failure no drop-in do Google
#   sudo bash migrate-selfdesk.sh --update   # ja no SelfDesk: reinstala o .deb da Release mais recente
#                                            # (versao nova do RustDesk ou pacote corrigido), mesmo ID
#   sudo bash migrate-selfdesk.sh --restart  # reinicia o SelfDesk na tela certa (ver restart_on_display)
#
# O que faz, na ordem:
#   1. le o ID do RustDesk como o usuario da sessao grafica (quem roda o --server)
#   2. para E DESABILITA o rustdesk.service (senao ele volta no boot com a mesma
#      identidade copiada e os dois disputam o ID e a tela)
#   3. instala o .deb do SelfDesk da Release mais recente (x86_64 ou aarch64)
#   4. com o SelfDesk parado, copia o RustDesk.toml do root e do usuario para o
#      SelfDesk.toml (ID, chave e senha permanente moram nele)
#   5. leva os drop-ins da ordem de partida para o nome SelfDesk.service
#   6. sobe o SelfDesk e confere que o ID e o mesmo; se nao for, desfaz tudo sozinho
#
# Seguro rodar duas vezes: se o SelfDesk ja estiver com o ID do RustDesk, so confere.
# Configuravel por variavel de ambiente ou /etc/default/migrate-selfdesk:
#   SESSION_USER  usuario da sessao grafica (padrao: o dono do processo --server)
#   DEB_ARCH      x86_64 ou aarch64 (padrao: pela arquitetura do dpkg)

set -Eeuo pipefail
umask 022

CONF_FILE="${MIGRATE_SELFDESK_CONF:-/etc/default/migrate-selfdesk}"
if [[ -r "$CONF_FILE" ]]; then
  # shellcheck source=/dev/null
  source "$CONF_FILE"
fi

RELEASE_URL="https://github.com/self-labs/selfdesk/releases/latest/download"
SD_UNIT="SelfDesk.service"
DROPIN_OLD="/etc/systemd/system/rustdesk.service.d"
DROPIN_NEW="/etc/systemd/system/${SD_UNIT}.d"
CRD_DIR="/etc/systemd/system/chrome-remote-desktop@.service.d"
CRD_OLD="$CRD_DIR/10-after-rustdesk.conf"
CRD_NEW="$CRD_DIR/10-after-selfdesk.conf"

log()  { printf '\033[1;36m[selfdesk]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[selfdesk] AVISO:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[selfdesk] ERRO:\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "rode como root: sudo bash $0 ${1:-}"

# A migracao roda desacoplada do SSH: se o tunel cair entre parar o RustDesk e subir o
# SelfDesk, um bash preso ao terminal morre no SIGHUP sem passar pelo rollback. Aqui ele
# se relanca numa sessao propria e o terminal so acompanha o log.
LOG=/var/log/migrate-selfdesk.log
if [[ ( -z "${1:-}" || "${1:-}" == --update || "${1:-}" == --restart ) && -z "${MIGRATE_SELFDESK_DETACHED:-}" ]]; then
  : >"$LOG"
  MIGRATE_SELFDESK_DETACHED=1 setsid -w bash "$0" "$@" >>"$LOG" 2>&1 </dev/null &
  pid=$!
  echo "rodando desacoplado do SSH; log em $LOG (pode cair a conexao, ele termina sozinho)"
  tail -n +1 --pid="$pid" -f "$LOG"
  wait "$pid"
  exit $?
fi

pkg_installed() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'; }

detect_user() {
  if [[ -n "${SESSION_USER:-}" ]]; then echo "$SESSION_USER"; return; fi
  # dono do processo "--server" do RustDesk ou do SelfDesk (o que captura a tela)
  local u
  u="$(ps -eo user:32,args | awk '/(rustdesk|[Ss]elf[Dd]esk) --server/ && !/sudo|awk/ {print $1; exit}')"
  [[ -n "$u" && "$u" != "root" ]] && { echo "$u"; return; }
  # sem --server rodando: o primeiro usuario comum (UID 1000)
  getent passwd 1000 | cut -d: -f1
}

user_home() { getent passwd "$1" | cut -d: -f6; }

# Tela que o SelfDesk tem de capturar. Os servidores sem monitor sobem um XFCE num
# Xvfb :1 pelo startxfce@<usuario>.service; os demais tem a sessao do monitor no :0.
expected_display() {
  if systemctl is-enabled --quiet "startxfce@$U.service" 2>/dev/null; then echo ':1'; else echo ':0'; fi
}

last_display() { # ultima tela que o SelfDesk escolheu, como ":0"
  local d pid
  # O log leva o nome do binario: SelfDesk_rCURRENT.log ate o .deb de 20/11/2026, selfdesk_ depois.
  d="$(grep -o 'DISPLAY: *:*[0-9][0-9]*' "$(ls -t /root/.local/share/logs/SelfDesk/service/{selfdesk,SelfDesk}_rCURRENT.log 2>/dev/null | head -1)" 2>/dev/null \
    | tail -1 | grep -o '[0-9][0-9]*$' | sed 's/^/:/' || true)"
  # O log troca de arquivo quando o --server reinicia (sem sessao ele reinicia sozinho), e o novo
  # pode ainda nao ter a linha: entao vale o DISPLAY do --server que esta rodando.
  if [[ -z "$d" ]]; then
    pid="$(pgrep -u "$U" -f 'SelfDesk/[Ss]elf[Dd]esk --server' | head -1 || true)"
    [[ -n "$pid" ]] && d="$(tr '\0' '\n' <"/proc/$pid/environ" 2>/dev/null | sed -n 's/^DISPLAY=//p' | head -1 || true)"
  fi
  echo "$d"
}

server_display() { # DISPLAY do --server que esta rodando agora, como ":0"
  local pid
  pid="$(pgrep -u "$U" -f 'SelfDesk/[Ss]elf[Dd]esk --server' | head -1 || true)"
  [[ -n "$pid" ]] && tr '\0' '\n' <"/proc/$pid/environ" 2>/dev/null | sed -n 's/^DISPLAY=//p' | head -1
  return 0
}

# Com o Chrome Remote Desktop no ar, o --server que reinicia ve tambem a tela :20 do Google e fica
# com ela (domjose, emanuellistofel e pelle depois do --update de 20/11/2026: DISPLAY=:20). No boot
# os drop-ins poem o SelfDesk antes do Google, entao so existe o :0. Aqui repete essa ordem: para o
# Chrome Remote Desktop, reinicia o SelfDesk, espera a tela certa e sobe o Google de novo.
restart_on_display() {
  local crd=() u d=""
  mapfile -t crd < <(systemctl list-units --state=active --no-legend --plain 'chrome-remote-desktop@*.service' | awk '{print $1}')
  for u in "${crd[@]}"; do log "parando $u (volta em seguida)"; systemctl stop "$u" || true; done
  systemctl restart "$SD_UNIT"
  for _ in $(seq 1 30); do
    sleep 2
    d="$(server_display)"
    [[ "$d" == "$DISP" ]] && break
  done
  for u in "${crd[@]}"; do systemctl start "$u" || warn "$u nao voltou: sudo systemctl start $u"; done
  if [[ "$d" == "$DISP" ]]; then
    log "SelfDesk na tela $d"
  else
    warn "o SelfDesk ficou na tela '${d:-nenhuma}', o certo e $DISP: reinicie a maquina (no boot a ordem acerta)"
    return 1
  fi
}

get_id_as() { # $1 comando (rustdesk|selfdesk)
  timeout 20 sudo -u "$U" -H "$1" --get-id 2>/dev/null | tr -d '[:space:]' || true
}

show_state() {
  log "usuario da sessao: $U ($UHOME)"
  log "rustdesk: $(pkg_installed rustdesk && echo instalado || echo ausente), $(systemctl is-active rustdesk 2>/dev/null || true), $(systemctl is-enabled rustdesk 2>/dev/null || true)"
  log "selfdesk: $(pkg_installed selfdesk && echo instalado || echo ausente), $(systemctl is-active "$SD_UNIT" 2>/dev/null || true), $(systemctl is-enabled "$SD_UNIT" 2>/dev/null || true)"
  if [[ "$DISP" == ":1" ]]; then
    log "tela virtual :1 (startxfce@$U.service): o drop-in do :0 nao se aplica"
  else
    [[ -f "$DROPIN_NEW/10-wait-for-x0.conf" ]] && log "drop-in do :0 em $DROPIN_NEW" || warn "sem drop-in do :0 em $DROPIN_NEW"
  fi
  [[ -f "$CRD_NEW" ]] && log "Chrome Remote Desktop: $(grep -E '^(After|Restart)=' "$CRD_NEW" | tr '\n' ' ')" || warn "sem $CRD_NEW"
  log "ultimo DISPLAY do SelfDesk: DISPLAY: $(last_display) (o certo nesta maquina e $DISP)"
  pkg_installed selfdesk && log "ID do SelfDesk: $(get_id_as selfdesk)"
}

# O Chrome Remote Desktop varre os processos ao subir e morre com psutil.NoSuchProcess se um
# deles some no meio, o que acontece no boot logo depois do SelfDesk (visto num cliente em 19/11/2026). A unit
# dele nao tem Restart=, entao ficava parado ate alguem religar. Tenta de novo a cada 30 s, no
# maximo 5 vezes em 10 minutos, para um CRD sem host configurado nao ficar em loop eterno.
ensure_crd_restart() {
  [[ -f "$CRD_NEW" ]] || return 0
  grep -q '^Restart=' "$CRD_NEW" && return 0
  cat >>"$CRD_NEW" <<'EOF'
StartLimitIntervalSec=600
StartLimitBurst=5

[Service]
Restart=on-failure
RestartSec=30
EOF
  log "Chrome Remote Desktop: Restart=on-failure em $CRD_NEW"
}

move_dropins_to_selfdesk() {
  if [[ -f "$DROPIN_OLD/10-wait-for-x0.conf" ]]; then
    mkdir -p "$DROPIN_NEW"
    mv "$DROPIN_OLD/10-wait-for-x0.conf" "$DROPIN_NEW/"
    rmdir "$DROPIN_OLD" 2>/dev/null || true
    log "drop-in do :0 movido para $DROPIN_NEW"
  elif [[ "$DISP" != ":1" && ! -f "$DROPIN_NEW/10-wait-for-x0.conf" ]]; then
    warn "nenhum drop-in do :0 encontrado: o SelfDesk pode capturar a tela do Chrome Remote Desktop"
  fi
  if [[ -f "$CRD_OLD" ]]; then
    mv "$CRD_OLD" "$CRD_NEW"
    sed -i 's/^After=rustdesk\.service$/After=SelfDesk.service/' "$CRD_NEW"
    log "Chrome Remote Desktop agora espera o $SD_UNIT"
  elif [[ ! -f "$CRD_NEW" ]]; then
    warn "nenhum drop-in do Chrome Remote Desktop encontrado"
  fi
  ensure_crd_restart
  systemctl daemon-reload
}

move_dropins_to_rustdesk() {
  if [[ -f "$DROPIN_NEW/10-wait-for-x0.conf" ]]; then
    mkdir -p "$DROPIN_OLD"
    mv "$DROPIN_NEW/10-wait-for-x0.conf" "$DROPIN_OLD/"
    rmdir "$DROPIN_NEW" 2>/dev/null || true
  fi
  if [[ -f "$CRD_NEW" ]]; then
    mv "$CRD_NEW" "$CRD_OLD"
    sed -i 's/^After=SelfDesk\.service$/After=rustdesk.service/' "$CRD_OLD"
  fi
  systemctl daemon-reload
}

rollback() {
  warn "voltando para o RustDesk"
  systemctl disable --now "$SD_UNIT" 2>/dev/null || true
  move_dropins_to_rustdesk
  systemctl enable --now rustdesk
  sleep 8
  log "RustDesk de volta, ID $(get_id_as rustdesk). O SelfDesk ficou instalado e desabilitado."
}

# Baixa o .deb da Release mais recente para $DEB e confere o sha256 com o SHA256SUMS dela.
fetch_deb() {
  case "${DEB_ARCH:-$(dpkg --print-architecture)}" in
    amd64|x86_64) DEB_ARCH=x86_64 ;;
    arm64|aarch64) DEB_ARCH=aarch64 ;;
    *) die "arquitetura sem .deb do SelfDesk: $(dpkg --print-architecture)" ;;
  esac
  TMPD="$(mktemp -d)"
  trap 'rm -rf "$TMPD"' EXIT
  DEB="$TMPD/selfdesk-$DEB_ARCH.deb"
  log "baixando $RELEASE_URL/selfdesk-$DEB_ARCH.deb"
  curl -fsSL -o "$DEB" "$RELEASE_URL/selfdesk-$DEB_ARCH.deb" || die "download falhou (DNS? rede?); nada foi alterado"
  curl -fsSL -o "$TMPD/SHA256SUMS" "$RELEASE_URL/SHA256SUMS" || die "download do SHA256SUMS falhou; nada foi alterado"
  (cd "$TMPD" && grep " selfdesk-$DEB_ARCH.deb\$" SHA256SUMS | sha256sum -c --quiet) \
    || die "sha256 do .deb nao confere com o SHA256SUMS da Release; nada foi alterado"
}

# Por cima de um SelfDesk instalado: o pacote nao toca na identidade (/root/.config/selfdesk e
# ~/.config/selfdesk), nem nos drop-ins em SelfDesk.service.d. dpkg -i e nao apt: com o mesmo
# numero de versao (pacote reempacotado) o apt diz que ja esta atualizado e nao reinstala.
update_selfdesk() {
  local old_id new_id
  pkg_installed selfdesk || die "o SelfDesk nao esta instalado: rode sem opcao para migrar do RustDesk"
  old_id="$(get_id_as selfdesk)"
  [[ "$old_id" =~ ^[0-9]{6,}$ ]] || die "nao consegui ler o ID do SelfDesk (obtido: '$old_id')"
  log "ID do SelfDesk: $old_id, versao instalada $(dpkg-query -W -f='${Version}' selfdesk)"
  fetch_deb
  log "instalando por cima (o servico para e volta sozinho)"
  DEBIAN_FRONTEND=noninteractive dpkg -i "$DEB" >/dev/null
  systemctl daemon-reload
  restart_on_display || true
  new_id="$(get_id_as selfdesk)"
  [[ "$new_id" == "$old_id" ]] \
    || die "o SelfDesk voltou com o ID '$new_id', esperado '$old_id': confira /root/.config/selfdesk/SelfDesk.toml"
  log "OK: SelfDesk $(dpkg-query -W -f='${Version}' selfdesk) com o mesmo ID ($new_id)"
  show_state
}

U="$(detect_user)"
UHOME="$(user_home "$U")"
[[ -n "$UHOME" && -d "$UHOME" ]] || die "usuario da sessao '$U' sem home; defina SESSION_USER"
DISP="$(expected_display)"

case "${1:-}" in
  --check) show_state; exit 0 ;;
  --crd-restart) ensure_crd_restart; systemctl daemon-reload; show_state; exit 0 ;;
  --update) update_selfdesk; exit 0 ;;
  --restart) pkg_installed selfdesk || die "o SelfDesk nao esta instalado"; restart_on_display; show_state; exit 0 ;;
  --rollback) pkg_installed rustdesk || die "o RustDesk nao esta mais instalado"; rollback; exit 0 ;;
  --finalize)
    pkg_installed rustdesk || { log "RustDesk ja removido"; exit 0; }
    [[ "$(systemctl is-active "$SD_UNIT")" == active ]] || die "o SelfDesk nao esta ativo; nao removo o RustDesk"
    [[ "$(last_display)" == "$DISP" ]] \
      || die "o ultimo DISPLAY do SelfDesk e '$(last_display)', o certo e $DISP; confira os reboots antes de remover o RustDesk"
    ensure_crd_restart
    systemctl daemon-reload
    apt-get remove -y rustdesk
    log "RustDesk removido. Troque o lancador do painel do XFCE pelo SelfDesk (opcional)."
    exit 0 ;;
  "") ;;
  *) die "opcao desconhecida: $1" ;;
esac

# ------------------------------------------------------------------ migracao
pkg_installed rustdesk || die "o RustDesk nao esta instalado: para maquina nova instale o .deb da Release (sem migracao)"
[[ -f /root/.config/rustdesk/RustDesk.toml ]] || die "sem /root/.config/rustdesk/RustDesk.toml"
[[ -f "$UHOME/.config/rustdesk/RustDesk.toml" ]] || die "sem $UHOME/.config/rustdesk/RustDesk.toml (usuario certo? SESSION_USER=...)"
# O SelfDesk so aceita a senha permanente: sem ela, o ID migra certo e ninguem conecta.
# Confere so a presenca do campo, nunca o valor.
grep -Eq "^password = ['\"].+['\"]" /root/.config/rustdesk/RustDesk.toml \
  || die "o RustDesk desta maquina nao tem senha permanente; defina com: sudo rustdesk --password '...' (nada foi alterado)"

# ID de referencia: com o RustDesk de pe pergunta ao --server; parado, le o arquivo do usuario
OLD_ID="$(get_id_as rustdesk)"
[[ "$OLD_ID" =~ ^[0-9]{6,}$ ]] || die "nao consegui ler o ID do RustDesk (obtido: '$OLD_ID')"
log "ID do RustDesk: $OLD_ID (usuario da sessao: $U)"

if pkg_installed selfdesk && [[ "$(systemctl is-active "$SD_UNIT" 2>/dev/null)" == active ]] \
   && [[ "$(get_id_as selfdesk)" == "$OLD_ID" ]]; then
  log "SelfDesk ja esta com o ID $OLD_ID: nada a migrar"
  show_state
  exit 0
fi

fetch_deb

# A partir daqui qualquer erro desfaz a troca
# shellcheck disable=SC2154  # rc nasce dentro do proprio trap
trap 'rc=$?; warn "falhou na linha $LINENO (codigo $rc)"; rollback; rm -rf "$TMPD"; exit $rc' ERR

log "parando e desabilitando o RustDesk (continua instalado)"
systemctl disable --now rustdesk

log "instalando o SelfDesk"
DEBIAN_FRONTEND=noninteractive apt-get install -y "$DEB" >/dev/null

log "copiando a identidade do RustDesk com o SelfDesk parado"
systemctl stop "$SD_UNIT"
install -d -m 700 /root/.config/selfdesk
cp -p /root/.config/rustdesk/RustDesk.toml /root/.config/selfdesk/SelfDesk.toml
sudo -u "$U" install -d -m 700 "$UHOME/.config/selfdesk"
sudo -u "$U" cp -p "$UHOME/.config/rustdesk/RustDesk.toml" "$UHOME/.config/selfdesk/SelfDesk.toml"

move_dropins_to_selfdesk
systemctl start "$SD_UNIT"
sleep 8

NEW_ID="$(get_id_as selfdesk)"
if [[ "$NEW_ID" != "$OLD_ID" ]]; then
  trap - ERR
  warn "o SelfDesk subiu com o ID '$NEW_ID', esperado '$OLD_ID'"
  rollback
  exit 1
fi
trap - ERR

log "OK: SelfDesk ativo com o mesmo ID ($NEW_ID) e a mesma senha permanente"
show_state
cat <<EOF

Proximos passos:
  1. conecte de outro computador no ID $NEW_ID com a senha permanente de antes
  2. faca 3 reboots; depois de cada um, confira o DISPLAY: $DISP com
       sudo bash $0 --check
  3. com os 3 reboots certos, remova o RustDesk:
       sudo bash $0 --finalize
  Para voltar atras a qualquer momento antes do passo 3:
       sudo bash $0 --rollback
EOF
