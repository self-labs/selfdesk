#!/usr/bin/env bash
#
# repack-arch.sh
# Reempacota o .pkg.tar.zst que o rdgen gera para o Arch no mesmo padrao do .deb do SelfDesk.
#
# Uso: scripts/repack-arch.sh <pacote.pkg.tar.zst> [exename]
#      (sobrescreve o arquivo; exename padrao: selfdesk)
#
# O pacote do rdgen sai com o nome do RustDesk em tudo que nao e o binario:
#   - pkgname "rustdesk", entao o rustdesk do repositorio da distro (o do Omarchy, por exemplo)
#     passa por cima dele no primeiro "pacman -Syu" com versao maior;
#   - o .INSTALL copia um "rustdesk.service" para /etc/systemd/system (fora do controle do pacman);
#   - os .desktop dizem Icon=SelfDesk, mas os icones se chamam rustdesk.png/svg: fica sem icone.
# Aqui ele vira o pacote "selfdesk" (conflita com "rustdesk"), com a unit SelfDesk.service em
# /usr/lib/systemd/system e o apelido selfdesk.service, os .desktop e icones com o nome do app e o
# comando /usr/bin/selfdesk: o mesmo layout do .deb.
#
# Precisa de bsdtar (libarchive-tools) e zstd.

set -euo pipefail

in="${1:?uso: $0 <pacote.pkg.tar.zst> [exename]}"
name="${2:-selfdesk}"
in="$(realpath "$in")"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
bsdtar -xpf "$in" -C "$work"
cd "$work"

grep -q '^pkgname = ' .PKGINFO || { echo "erro: $in sem .PKGINFO" >&2; exit 1; }
unit_src="$(find usr/share -path '*/files/rustdesk.service' | head -n1)"
[[ -n "$unit_src" ]] || { echo "erro: $in sem files/rustdesk.service" >&2; exit 1; }
app="$(basename "$(dirname "$(dirname "$unit_src")")")" # usr/share/<App>/files/rustdesk.service
[[ -x "usr/share/$app/$app" ]] || { echo "erro: sem usr/share/$app/$app" >&2; exit 1; }
files="usr/share/$app/files"

# ---- binario com o nome em minusculas; o nome do app fica como link no mesmo diretorio
# O RustDesk acha os proprios processos procurando "<nome do app em minusculas> --server" (e
# --tray) na saida do ps: is_server_running() em libs/scrap/src/wayland/pipewire.rs e os
# padroes de kill e tray em src/platform/linux.rs. O caminho de um processo e o do arquivo real
# (o link e resolvido), entao com o binario "SelfDesk" nada casa. No Wayland o --server conclui
# que nao e servidor e pede o portal RemoteDesktop em vez do ScreenCast com uinput; no Hyprland,
# sem RemoteDesktop, toda conexao falha com "The desktop portal on the remote device is missing
# a capability" (Omarchy, 20/11/2026). No mesmo diretorio, o binario continua achando data/ e lib/.
if [[ ! -L "usr/share/$app/$app" ]]; then
  mv "usr/share/$app/$app" "usr/share/$app/$name"
  ln -s "$name" "usr/share/$app/$app"
fi
ln -sfn "/usr/share/$app/$name" "usr/bin/$app"

# ---- unit: dentro do pacote, com o nome do app e o apelido em minusculas
mkdir -p usr/lib/systemd/system
sed -e "s/^Description=.*/Description=$app/" \
    -e "s|^ExecStop=pkill -f \"$app --\"|ExecStop=/usr/bin/pkill -f \"/usr/share/$app/$name --\"|" \
    "$unit_src" >"usr/lib/systemd/system/$app.service"
grep -q "^ExecStop=/usr/bin/pkill -f \"/usr/share/$app/$name --\"" "usr/lib/systemd/system/$app.service" \
  || { echo "erro: ExecStop inesperado em $unit_src" >&2; exit 1; }
grep -q "^Alias=$name.service" "usr/lib/systemd/system/$app.service" \
  || sed -i "/^\[Install\]/a Alias=$name.service" "usr/lib/systemd/system/$app.service"
rm -f "$unit_src"

# ---- .desktop e icones com o nome do app (Icon=$app ja vem do rdgen)
mkdir -p usr/share/applications
mv "$files/rustdesk.desktop" "usr/share/applications/$app.desktop"
mv "$files/rustdesk-link.desktop" "usr/share/applications/$app-link.desktop"
for ext in png svg; do
  for f in usr/share/icons/hicolor/*/apps/rustdesk."$ext"; do
    [[ -e "$f" ]] && mv "$f" "$(dirname "$f")/$app.$ext"
  done
done
grep -q "^Icon=$app$" "usr/share/applications/$app.desktop" \
  || { echo "erro: $app.desktop sem Icon=$app" >&2; exit 1; }
rmdir "$files" 2>/dev/null || true

# ---- comando em minusculas
ln -sfn "/usr/share/$app/$name" "usr/bin/$name"

# ---- scripts do pacman: so o systemctl, os arquivos agora sao do pacote
cat >.INSTALL <<EOF
post_install() {
	systemctl daemon-reload
	systemctl enable --now $app.service
	update-desktop-database -q || true
	gtk-update-icon-cache -q -t -f /usr/share/icons/hicolor || true
}

pre_upgrade() {
	systemctl stop $app.service || true
}

post_upgrade() {
	systemctl daemon-reload
	systemctl enable $app.service
	systemctl start $app.service
	update-desktop-database -q || true
	gtk-update-icon-cache -q -t -f /usr/share/icons/hicolor || true
}

pre_remove() {
	systemctl disable --now $app.service || true
}

post_remove() {
	systemctl daemon-reload
	update-desktop-database -q || true
}
EOF

# ---- metadados
size="$(find usr -type f -printf '%s\n' | awk '{s+=$1} END {print s+0}')"
sed -i \
  -e "s/^pkgname = .*/pkgname = $name/" \
  -e "s/^pkgbase = .*/pkgbase = $name/" \
  -e "s/^pkgdesc = .*/pkgdesc = $app, cliente remoto da Self-Labs baseado no RustDesk/" \
  -e "s|^url = .*|url = https://github.com/self-labs/$name|" \
  -e "s/^packager = .*/packager = Self-Labs/" \
  -e "s/^size = .*/size = $size/" \
  .PKGINFO
grep -q '^conflict = rustdesk$' .PKGINFO || echo 'conflict = rustdesk' >>.PKGINFO
[[ -f .BUILDINFO ]] && sed -i -e "s/^pkgname = .*/pkgname = $name/" -e "s/^pkgbase = .*/pkgbase = $name/" .BUILDINFO

# ---- .MTREE e o pacote, como o makepkg faz (dono root em tudo)
meta=(.PKGINFO .INSTALL)
[[ -f .BUILDINFO ]] && meta+=(.BUILDINFO)
rm -f .MTREE
LANG=C bsdtar -czf .MTREE --format=mtree --uid 0 --gid 0 --uname root --gname root \
  --options='!all,use-set,type,uid,gid,mode,time,size,md5,sha256,link' "${meta[@]}" usr
LANG=C bsdtar -cf - --uid 0 --gid 0 --uname root --gname root .MTREE "${meta[@]}" usr \
  | zstd -q -c -T0 -19 >"$in.new"
mv "$in.new" "$in"

echo "$in: pkgname $name, $app.service (Alias=$name.service), /usr/bin/$name, $app.desktop, conflita com rustdesk"
