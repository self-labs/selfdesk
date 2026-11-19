#!/usr/bin/env python3
"""Gera as imagens do cliente SelfDesk a partir do logo.png da Self-Labs.

Uso: python3 build-brand.py <logo.png de origem> <pasta de saída>

Origem: o logo.png 512x512 da Self-Labs (digital em cima, SELF-LABS embaixo, fundo transparente),
o mesmo de cateim/DIY assets/configs/authelia-assets/logo.png.

Saídas (o rdgen aceita só PNG):
  icon.png     256x256, digital num quadrado escuro arredondado (ícone do .exe, atalho, bandeja)
  logo.png     marca na horizontal num selo escuro (tela inicial do app)
  privacy.png  1920x1080, tela do modo privacidade exibida no monitor da máquina acessada

Por que o fundo escuro: o ciano e o verde da marca têm contraste 1,4 sobre o fundo claro do
RustDesk (#EFEFF2) e somem no tema claro; o selo escuro mantém a marca legível nos dois temas.
Por que engrossar o traço do ícone: as linhas finas da digital viram uma mancha apagada em
32 px e 16 px (barra de tarefas, bandeja); com o traço dilatado o ícone continua aceso.

Requer Pillow e a fonte Inter (Debian: fonts-inter).
"""
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

FONT = "/usr/share/fonts/opentype/inter/Inter-Medium.otf"
DARK = (11, 15, 20, 255)            # #0B0F14
PRIVACY_TEXT = (138, 150, 163, 255)  # #8A96A3
PRIVACY_MSG = "Sessão remota em andamento"
ICON_STROKE = 5                      # tamanho do MaxFilter que engrossa o traço do ícone
SS = 4                               # supersampling: desenha em 4x e reduz no fim


def alpha_bbox(im, threshold=20):
    return im.getchannel("A").point(lambda v: 255 if v > threshold else 0).getbbox()


def split_mark(src):
    """Separa a digital do texto pela faixa transparente entre os dois."""
    a = src.getchannel("A")
    w, h = src.size
    rows = [y for y in range(h) if a.crop((0, y, w, y + 1)).getextrema()[1] > 20]
    i = next(i for i in range(len(rows) - 1) if rows[i + 1] - rows[i] > 1)
    finger = src.crop((0, 0, w, rows[i] + 1))
    text = src.crop((0, rows[i + 1], w, h))
    return finger.crop(alpha_bbox(finger)), text.crop(alpha_bbox(text))


def thicken(im, k):
    r, g, b, a = im.split()
    rgb = Image.merge("RGB", (r, g, b)).filter(ImageFilter.MaxFilter(k))
    return Image.merge("RGBA", (*rgb.split(), a.filter(ImageFilter.MaxFilter(k))))


def scale_to(im, w=None, h=None):
    s = (w / im.width) if w else (h / im.height)
    return im.resize((round(im.width * s), round(im.height * s)), Image.LANCZOS)


def dark_tile(content, size, radius, pad):
    """Quadro escuro arredondado com o conteúdo centralizado, desenhado em SS vezes o tamanho."""
    W, H = size[0] * SS, size[1] * SS
    out = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    mask = Image.new("L", (W, H), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, W - 1, H - 1), radius=radius * SS, fill=255)
    out.paste(DARK, (0, 0), mask)
    p = pad * SS
    s = min((W - 2 * p) / content.width, (H - 2 * p) / content.height)
    c = content.resize((round(content.width * s), round(content.height * s)), Image.LANCZOS)
    out.alpha_composite(c, ((W - c.width) // 2, (H - c.height) // 2))
    return out.resize(size, Image.LANCZOS)


def horizontal_mark(finger, text, fh=200, gap=28):
    """Digital à esquerda e SELF-LABS à direita, centralizados na vertical."""
    f = scale_to(finger, h=fh)
    t = scale_to(text, h=round(fh * 0.28))
    out = Image.new("RGBA", (f.width + gap + t.width, fh), (0, 0, 0, 0))
    out.alpha_composite(f, (0, 0))
    out.alpha_composite(t, (f.width + gap, (fh - t.height) // 2))
    return out


def main(src_path, out_dir):
    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)
    src = Image.open(src_path).convert("RGBA")
    finger, text = split_mark(src)

    # icon.png: digital (dobrada de tamanho antes de engrossar, para o traço não empapar).
    big = thicken(scale_to(finger, h=finger.height * 2), ICON_STROKE)
    dark_tile(big, (256, 256), radius=56, pad=30).save(out / "icon.png", optimize=True)

    # logo.png: marca horizontal num selo escuro.
    mark = horizontal_mark(finger, text)
    size = (mark.width + 2 * 36, mark.height + 2 * 30)
    dark_tile(mark, size, radius=36, pad=30).save(out / "logo.png", optimize=True)

    # privacy.png: marca empilhada (a original) no centro e a mensagem abaixo.
    W, H = 1920, 1080
    priv = Image.new("RGBA", (W, H), DARK)
    stacked = scale_to(src.crop(alpha_bbox(src)), h=440)
    font = ImageFont.truetype(FONT, 40)
    d = ImageDraw.Draw(priv)
    tb = d.textbbox((0, 0), PRIVACY_MSG, font=font)
    y0 = (H - (stacked.height + 60 + tb[3] - tb[1])) // 2
    priv.alpha_composite(stacked, ((W - stacked.width) // 2, y0))
    d.text(((W - (tb[2] - tb[0])) // 2 - tb[0], y0 + stacked.height + 60 - tb[1]),
           PRIVACY_MSG, font=font, fill=PRIVACY_TEXT)
    priv.convert("RGB").save(out / "privacy.png", optimize=True)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])
