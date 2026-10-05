"""Biến ảnh món ăn tĩnh thành video chuyển động ngắn (cinemagraph).

Hiệu ứng cho từng ảnh:
  - máy quay chậm (zoom/pan kiểu Ken Burns)
  - hơi nóng bốc lên từ bát nước dùng
  - mặt nước dùng / nước chấm gợn nhẹ
  - rau thơm lay nhẹ như có gió
  - ánh nắng trên bàn chuyển động nhẹ

Chạy:  pip install numpy opencv-python-headless
       python3 videos/make_videos.py            # xuất tất cả + video tổng hợp
       python3 videos/make_videos.py --preview  # chỉ xuất ảnh khung hình để xem thử
"""

import argparse
import math
import os
import subprocess
import sys

import cv2
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
SRC_DIR = os.path.join(HERE, "source")

W_OUT, H_OUT = 1080, 1350  # 4:5, chuẩn bài đăng Facebook/Instagram
FPS = 30
DURATION = 6.0
Q = 3  # các lớp hiệu ứng (hơi nước, ánh sáng, gợn nước) tính ở độ phân giải 1/Q


# Mọi toạ độ tính theo pixel của ảnh gốc 1122x1402.
#   cam:    (zoom, tâm x, tâm y, xoay độ) ở đầu và cuối clip
#   steam:  (cx, cy, rx, ry, độ cao bốc lên, cường độ) - vùng mặt nước dùng
#   liquid: (cx, cy, rx, ry) - vùng chất lỏng gợn sóng
#   sway:   (cx, cy, rx, ry) - vùng rau lay
SCENES = [
    {
        "name": "01-ga",
        "cam": [(1.0, 561, 701, 0.0), (1.13, 575, 640, 0.0)],
        "steam": [(575, 440, 340, 270, 330, 1.0)],
        "liquid": [(578, 470, 360, 275)],
        "sway": [(560, 280, 330, 120)],
        "steam_gain": 0.95,
        "light_amp": 0.05,
    },
    {
        "name": "02-luon",
        "cam": [(1.04, 545, 690, 0.0), (1.17, 530, 620, 1.2)],
        "steam": [(525, 480, 340, 290, 300, 1.0)],
        "liquid": [(530, 520, 370, 310)],
        "sway": [(700, 330, 210, 170), (260, 440, 130, 190)],
        "steam_gain": 0.95,
        "light_amp": 0.05,
    },
    {
        "name": "03-nem",
        "cam": [(1.2, 470, 760, 0.0), (1.12, 612, 640, 0.0)],
        "steam": [(310, 600, 170, 260, 220, 0.5)],
        "liquid": [(645, 910, 190, 180)],
        "sway": [(770, 400, 330, 320), (950, 690, 190, 150)],
        "steam_gain": 0.6,
        "light_amp": 0.07,
    },
    {
        "name": "04-chan-gio",
        "cam": [(1.0, 561, 701, 0.0), (1.11, 560, 700, 0.0)],
        "steam": [(560, 700, 430, 400, 260, 1.0)],
        "liquid": [(560, 760, 470, 440)],
        "sway": [(560, 640, 380, 360)],
        "steam_gain": 0.85,
        "light_amp": 0.04,
    },
    {
        "name": "05-toan-canh",
        "cam": [(1.35, 700, 520, 0.0), (1.0, 561, 701, 0.0)],
        "steam": [
            (835, 330, 180, 125, 190, 0.85),
            (637, 610, 175, 150, 160, 0.6),
            (968, 585, 110, 75, 150, 0.85),
            (930, 870, 160, 130, 160, 0.8),
            (660, 1180, 195, 170, 210, 1.0),
        ],
        "liquid": [
            (835, 340, 165, 115),
            (968, 590, 100, 70),
            (930, 880, 150, 120),
            (660, 1190, 180, 165),
        ],
        "sway": [(150, 700, 170, 140)],
        "steam_gain": 0.85,
        "light_amp": 0.05,
    },
]

MONTAGE_ORDER = ["01-ga", "02-luon", "04-chan-gio", "03-nem", "05-toan-canh"]
MONTAGE_XFADE = 0.6


def smoothstep(a, b, x):
    t = np.clip((x - a) / (b - a), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


def tile_noise(n, seed, cutoff, aniso=(1.0, 1.0), beta=2.0):
    """Nhiễu mượt, lặp liền mạch (tạo bằng lọc phổ FFT), giá trị 0..1."""
    rng = np.random.default_rng(seed)
    white = rng.standard_normal((n, n))
    fy = np.fft.fftfreq(n)[:, None] * aniso[1]
    fx = np.fft.fftfreq(n)[None, :] * aniso[0]
    f = np.sqrt(fx ** 2 + fy ** 2)
    f[0, 0] = 1.0
    amp = f ** (-beta / 2.0) * np.exp(-((f / cutoff) ** 2))
    amp[0, 0] = 0.0
    out = np.real(np.fft.ifft2(np.fft.fft2(white) * amp))
    lo, hi = np.percentile(out, [1, 99])
    return np.clip((out - lo) / (hi - lo), 0.0, 1.0).astype(np.float32)


def sample(tex, u, v):
    n = tex.shape[0]
    return cv2.remap(tex, np.mod(u, n).astype(np.float32), np.mod(v, n).astype(np.float32),
                     cv2.INTER_LINEAR, borderMode=cv2.BORDER_WRAP)


class Noise:
    def __init__(self):
        n = 1024
        self.steam = tile_noise(n, 1, cutoff=0.035, aniso=(1.0, 3.0))  # sợi dọc
        self.swirl = tile_noise(n, 2, cutoff=0.01)
        self.ripple = tile_noise(n, 3, cutoff=0.03)
        self.light = tile_noise(n, 4, cutoff=0.006)
        self.phase = tile_noise(n, 5, cutoff=0.008)


def ellipse_mask(xs, ys, cx, cy, rx, ry, feather=0.18):
    r = np.sqrt(((xs - cx) / rx) ** 2 + ((ys - cy) / ry) ** 2)
    return 1.0 - smoothstep(1.0 - feather, 1.0, r)


def ease(t):
    return t - 0.6 * math.sin(2 * math.pi * t) / (2 * math.pi)


class Scene:
    def __init__(self, cfg, noise):
        self.cfg = cfg
        self.noise = noise
        img = cv2.imread(os.path.join(SRC_DIR, cfg["name"] + ".webp"), cv2.IMREAD_COLOR)
        if img is None:
            sys.exit("Không đọc được ảnh " + cfg["name"])
        self.src = cv2.cvtColor(img, cv2.COLOR_BGR2RGB).astype(np.float32) / 255.0
        self.h, self.w = self.src.shape[:2]
        self.k = min(self.w / W_OUT, self.h / H_OUT)

        # lưới toạ độ (theo pixel ảnh gốc) cho các lớp hiệu ứng độ phân giải thấp
        self.lw, self.lh = math.ceil(self.w / Q), math.ceil(self.h / Q)
        xs = (np.arange(self.lw, dtype=np.float32) + 0.5) * Q
        ys = (np.arange(self.lh, dtype=np.float32) + 0.5) * Q
        self.xs, self.ys = np.meshgrid(xs, ys)

        self.liquid_mask = np.zeros_like(self.xs)
        for cx, cy, rx, ry in cfg["liquid"]:
            self.liquid_mask = np.maximum(self.liquid_mask, ellipse_mask(self.xs, self.ys, cx, cy, rx, ry))
        self.sway_mask = np.zeros_like(self.xs)
        for cx, cy, rx, ry in cfg["sway"]:
            self.sway_mask = np.maximum(self.sway_mask, ellipse_mask(self.xs, self.ys, cx, cy, rx, ry, 0.5))
        self.sway_phase = sample(noise.phase, self.xs / 2.0, self.ys / 2.0) * 2 * math.pi

        gx = np.arange(W_OUT, dtype=np.float32) + 0.5 - W_OUT / 2
        gy = np.arange(H_OUT, dtype=np.float32) + 0.5 - H_OUT / 2
        self.gx, self.gy = np.meshgrid(gx, gy)

    # ---------- máy quay ----------
    def camera(self, t):
        (s0, x0, y0, r0), (s1, x1, y1, r1) = self.cfg["cam"]
        e = ease(t / DURATION)
        z = (1 / s0) + ((1 / s1) - (1 / s0)) * e  # nội suy 1/zoom để khung luôn nằm trong ảnh
        return 1 / z, x0 + (x1 - x0) * e, y0 + (y1 - y0) * e, math.radians(r0 + (r1 - r0) * e)

    def camera_map(self, t):
        s, cx, cy, rot = self.camera(t)
        c, sn = math.cos(rot), math.sin(rot)
        f = self.k / s
        mx = cx + f * (c * self.gx - sn * self.gy) - 0.5
        my = cy + f * (sn * self.gx + c * self.gy) - 0.5
        return mx, my

    # ---------- các lớp hiệu ứng (toạ độ ảnh gốc, độ phân giải thấp) ----------
    def displacement(self, t):
        nz, xs, ys = self.noise, self.xs, self.ys
        a = 1.4
        rdx = (sample(nz.ripple, xs + t * 14, ys + t * 6) - 0.5) * 2 * a
        rdy = (sample(nz.ripple, xs + 411 - t * 10, ys + 733 + t * 8) - 0.5) * 2 * a
        b = 2.2
        w = 2 * math.pi * t / 3.0
        sdx = b * np.sin(w + self.sway_phase)
        sdy = 0.35 * b * np.sin(1.3 * w + self.sway_phase + 1.0)
        dx = rdx * self.liquid_mask + sdx * self.sway_mask
        dy = rdy * self.liquid_mask + sdy * self.sway_mask
        return dx.astype(np.float32), dy.astype(np.float32)

    def steam(self, t):
        nz, xs, ys = self.noise, self.xs, self.ys
        rise = 70.0  # px/giây
        swirl = (sample(nz.swirl, xs / 3.0, ys / 3.0 + t * 10) - 0.5) * 90
        u = xs + swirl
        v = ys + rise * t
        n = 0.65 * sample(nz.steam, u, v) + 0.35 * sample(nz.steam, 1.9 * u + 300, 1.9 * (ys + 1.25 * rise * t) + 500)
        dens = smoothstep(0.42, 0.82, n) * 0.9 + 0.1 * n

        mask = np.zeros_like(xs)
        for cx, cy, rx, ry, height, strength in self.cfg["steam"]:
            base = cy + 0.45 * ry
            h = (base - ys) / (ry * 1.4 + height)
            prof = smoothstep(0.0, 0.15, h) * (1.0 - smoothstep(0.65, 1.0, h))
            hc = np.clip(h, 0.0, 1.0)
            sig = rx * (0.5 + 0.45 * hc)
            drift = rx * (0.1 * hc + 0.08 * np.sin(2 * math.pi * t / 5.0 + hc * 3.0))
            g = np.exp(-0.5 * ((xs - cx - drift) / sig) ** 2)
            mask += prof * g * strength
        alpha = np.clip(dens * np.clip(mask, 0, 1) * self.cfg["steam_gain"], 0.0, 0.8)
        return cv2.GaussianBlur(alpha.astype(np.float32), (0, 0), 1.0)

    def light(self, t):
        n = sample(self.noise.light, self.xs / 2.0 + t * 7, self.ys / 2.0 + t * 4)
        return (1.0 + self.cfg["light_amp"] * (2 * n - 1)).astype(np.float32)

    # ---------- dựng khung hình ----------
    def frame(self, t):
        mx, my = self.camera_map(t)
        lx, ly = mx / Q - 0.5, my / Q - 0.5  # toạ độ trên lưới độ phân giải thấp

        def up(layer):
            return cv2.remap(layer, lx, ly, cv2.INTER_LINEAR, borderMode=cv2.BORDER_REPLICATE)

        dx, dy = self.displacement(t)
        img = cv2.remap(self.src, mx + up(dx), my + up(dy), cv2.INTER_CUBIC, borderMode=cv2.BORDER_REFLECT)
        img *= up(self.light(t))[..., None]
        a = up(self.steam(t))[..., None]
        steam_col = np.array([1.0, 0.97, 0.92], dtype=np.float32)
        img = 1.0 - (1.0 - np.clip(img, 0, 1)) * (1.0 - a * steam_col)
        return (np.clip(img, 0, 1) * 255 + 0.5).astype(np.uint8)

    def check_bounds(self):
        worst = 0.0
        for i in range(0, int(DURATION * FPS) + 1, 5):
            mx, my = self.camera_map(i / FPS)
            for xx, yy in ((mx[0, 0], my[0, 0]), (mx[0, -1], my[0, -1]), (mx[-1, 0], my[-1, 0]), (mx[-1, -1], my[-1, -1])):
                worst = max(worst, -xx, -yy, xx - (self.w - 1), yy - (self.h - 1))
        if worst > 1.0:
            print(f"  ! {self.cfg['name']}: khung hình lệch ra ngoài ảnh {worst:.1f}px")


def encode(scene, path):
    cmd = [
        "ffmpeg", "-y", "-loglevel", "error",
        "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", f"{W_OUT}x{H_OUT}", "-r", str(FPS), "-i", "-",
        "-vf", "scale=out_color_matrix=bt709:out_range=tv",
        "-c:v", "libx264", "-preset", "slow", "-crf", "20", "-pix_fmt", "yuv420p",
        "-colorspace", "bt709", "-color_primaries", "bt709", "-color_trc", "bt709",
        "-movflags", "+faststart", path,
    ]
    proc = subprocess.Popen(cmd, stdin=subprocess.PIPE)
    n = int(round(DURATION * FPS))
    for i in range(n):
        proc.stdin.write(scene.frame(i / FPS).tobytes())
    proc.stdin.close()
    if proc.wait() != 0:
        sys.exit("ffmpeg lỗi khi xuất " + path)


def montage(paths, out):
    inputs = []
    for p in paths:
        inputs += ["-i", p]
    chain, last = [], "[0:v]"
    for i in range(1, len(paths)):
        offset = i * (DURATION - MONTAGE_XFADE)
        tag = f"[x{i}]"
        chain.append(f"{last}[{i}:v]xfade=transition=fade:duration={MONTAGE_XFADE}:offset={offset:.3f}{tag}")
        last = tag
    total = len(paths) * DURATION - (len(paths) - 1) * MONTAGE_XFADE
    chain.append(f"{last}fade=t=in:st=0:d=0.4,fade=t=out:st={total - 0.6:.3f}:d=0.6[out]")
    cmd = ["ffmpeg", "-y", "-loglevel", "error", *inputs,
           "-filter_complex", ";".join(chain), "-map", "[out]",
           "-c:v", "libx264", "-preset", "slow", "-crf", "20", "-pix_fmt", "yuv420p",
           "-colorspace", "bt709", "-color_primaries", "bt709", "-color_trc", "bt709",
           "-movflags", "+faststart", out]
    subprocess.run(cmd, check=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--preview", metavar="DIR", help="chỉ xuất vài khung hình PNG vào thư mục này")
    ap.add_argument("--only", help="chỉ xử lý ảnh có tên này (vd 01-ga)")
    args = ap.parse_args()

    noise = Noise()
    out_dir = HERE
    scenes = [c for c in SCENES if not args.only or c["name"] == args.only]
    for cfg in scenes:
        scene = Scene(cfg, noise)
        scene.check_bounds()
        if args.preview:
            os.makedirs(args.preview, exist_ok=True)
            for t in (0.0, DURATION / 2, DURATION - 1 / FPS):
                rgb = scene.frame(t)
                cv2.imwrite(os.path.join(args.preview, f"{cfg['name']}_{t:.1f}.png"), cv2.cvtColor(rgb, cv2.COLOR_RGB2BGR))
            print("preview", cfg["name"])
            continue
        path = os.path.join(out_dir, cfg["name"] + ".mp4")
        encode(scene, path)
        print("xong", path)

    if not args.preview and not args.only:
        montage([os.path.join(out_dir, n + ".mp4") for n in MONTAGE_ORDER], os.path.join(out_dir, "tong-hop.mp4"))
        print("xong tong-hop.mp4")


if __name__ == "__main__":
    main()
