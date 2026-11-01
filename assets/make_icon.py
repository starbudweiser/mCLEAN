"""Dessine l'icône de mCLEAN (1024 px, couleurs Socle) puis produit icon.icns avec iconutil.
Une barrette de mémoire dans un anneau de jauge : la RAM et son niveau."""
import os, subprocess, sys, tempfile
from PyQt6.QtCore import QPointF, QRectF, Qt
from PyQt6.QtGui import QColor, QGuiApplication, QImage, QLinearGradient, QPainter, QPen

here = os.path.dirname(os.path.abspath(__file__))
GREEN = QColor("#34d399")  # couleur du logo : le « m » du nom dans l'appli

app = QGuiApplication(sys.argv)
img = QImage(1024, 1024, QImage.Format.Format_ARGB32)
img.fill(Qt.GlobalColor.transparent)
p = QPainter(img)
p.setRenderHint(QPainter.RenderHint.Antialiasing)
p.setPen(Qt.PenStyle.NoPen)

tile = QRectF(100, 100, 824, 824)
g = QLinearGradient(tile.topLeft(), tile.bottomLeft())
g.setColorAt(0, QColor("#2c2f34"))
g.setColorAt(1, QColor("#1b1d21"))
p.setBrush(g)
p.drawRoundedRect(tile, 180, 180)

# anneau de jauge, 75 % rempli
ring = QRectF(262, 262, 500, 500)
pen = QPen(QColor("#3a3d43"), 64); pen.setCapStyle(Qt.PenCapStyle.RoundCap)
p.setPen(pen); p.setBrush(Qt.BrushStyle.NoBrush)
p.drawArc(ring, 0, 360 * 16)
pen.setColor(GREEN)
p.setPen(pen)
p.drawArc(ring, 90 * 16, -270 * 16)

# barrette de RAM au centre
p.setPen(Qt.PenStyle.NoPen)
p.setBrush(QColor("#f2f2f2"))
p.drawRoundedRect(QRectF(372, 420, 280, 184), 28, 28)
p.setBrush(QColor("#1b1d21"))
for i in range(3):
    p.drawRoundedRect(QRectF(396 + i * 82, 446, 62, 70), 10, 10)
p.setBrush(GREEN)
for i in range(6):
    p.drawRect(QRectF(390 + i * 40, 604, 24, 30))
p.end()

img.save(os.path.join(here, "icon.png"))
with tempfile.TemporaryDirectory() as tmp:
    iconset = os.path.join(tmp, "icon.iconset"); os.mkdir(iconset)
    for s in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            n = f"icon_{s}x{s}{'@2x' if scale == 2 else ''}.png"
            img.scaled(s * scale, s * scale, Qt.AspectRatioMode.KeepAspectRatio,
                       Qt.TransformationMode.SmoothTransformation).save(os.path.join(iconset, n))
    subprocess.run(["iconutil", "-c", "icns", iconset, "-o", os.path.join(here, "icon.icns")], check=True)
print("icon.icns OK")
