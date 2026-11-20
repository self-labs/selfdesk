#!/usr/bin/env bash
#
# repack-deb.sh
# Ajusta o .deb que o rdgen gera para o padrao em minusculas do SelfDesk no Linux.
#
# Uso: scripts/repack-deb.sh <pacote.deb> [exename]
#      (sobrescreve o arquivo; exename padrao: selfdesk; pode rodar de novo no mesmo .deb)
#
# O rdgen da ao binario, ao comando e ao servico o nome do app (SelfDesk). Aqui:
#   - o binario real vira /usr/share/<App>/selfdesk, e <App> fica como link para ele (o porque
#     esta no repack-arch.sh: o RustDesk acha os proprios processos pelo nome em minusculas);
#   - o ExecStop da unit mata pelo caminho real, porque "SelfDesk --" nao casa mais com nada;
#   - entram o comando /usr/bin/selfdesk e o apelido selfdesk.service (o systemctl enable do
#     postinst o cria). /usr/bin/SelfDesk e SelfDesk.service continuam valendo.
# Os scripts do pacote (postinst, prerm) ficam como o rdgen fez: o postinst liga
# /usr/bin/SelfDesk em /usr/share/<App>/<App>, que agora e o link, e poe /usr/bin/ na frente de
# "pkill" na unit (por isso o ExecStop daqui sai sem caminho).
#
# Precisa de dpkg-deb (Debian/Ubuntu).

set -euo pipefail

in="${1:?uso: $0 <pacote.deb> [exename]}"
name="${2:-selfdesk}"
in="$(realpath "$in")"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
pkg="$work/pkg"
dpkg-deb -R "$in" "$pkg"

unit="$(find "$pkg/usr/share" -path '*/files/systemd/*.service' | head -n1)"
[[ -n "$unit" ]] || { echo "erro: $in sem files/systemd/*.service" >&2; exit 1; }
app="$(basename "$unit" .service)"
dir="$pkg/usr/share/$app"
[[ -x "$dir/$app" ]] || { echo "erro: $in sem /usr/share/$app/$app" >&2; exit 1; }
# Sem logo.png, o rdgen nao recebeu as imagens e o pacote saiu com a marca do RustDesk.
[[ -s "$dir/data/flutter_assets/assets/logo.png" ]] \
  || { echo "erro: $in sem a logo da marca: confira iconbase64/logobase64 no selfdesk.json" >&2; exit 1; }

# ---- binario com o nome em minusculas; o nome do app fica como link no mesmo diretorio
if [[ ! -L "$dir/$app" ]]; then
  mv "$dir/$app" "$dir/$name"
  ln -s "$name" "$dir/$app"
fi
ln -sfn "/usr/share/$app/$name" "$pkg/usr/bin/$name"

# ---- unit: ExecStop pelo caminho real e o apelido em minusculas
sed -i "s|^ExecStop=pkill -f \"$app --\"|ExecStop=pkill -f \"/usr/share/$app/$name --\"|" "$unit"
grep -q "^ExecStop=pkill -f \"/usr/share/$app/$name --\"" "$unit" \
  || { echo "erro: ExecStop inesperado em ${unit#"$pkg"}" >&2; exit 1; }
grep -q "^Alias=$name.service" "$unit" || sed -i "/^\[Install\]/a Alias=$name.service" "$unit"

# ---- md5sums e o pacote
(cd "$pkg" && find . -path ./DEBIAN -prune -o -type f -printf '%P\0' | sort -z | xargs -0 md5sum) \
  >"$pkg/DEBIAN/md5sums"
dpkg-deb --root-owner-group --build "$pkg" "$in.new" >/dev/null
mv "$in.new" "$in"

dpkg-deb -c "$in" | grep -q " ./usr/share/$app/$app -> $name\$" \
  || { echo "erro: $in sem o link /usr/share/$app/$app" >&2; exit 1; }
echo "$in: /usr/share/$app/$name (com o link $app), /usr/bin/$name, Alias=$name.service"
