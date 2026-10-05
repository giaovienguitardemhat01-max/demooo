"""Biến ảnh chụp camera trong quán thành video "quán đông khách" kiểu tua nhanh.

Mỗi người trong ảnh được cho cử động nhẹ theo nhịp riêng (gật đầu, nghiêng người,
gắp ăn), nhân viên cúi người phục vụ, đèn tre đung đưa, ánh sáng ngoài cửa kính
thay đổi, máy quay từ từ tiến vào. Chữ "Nest" của camera được xoá.

Chạy:  python3 videos/make_quan_dong.py
       python3 videos/make_quan_dong.py --preview /tmp/xem-thu
"""

import argparse
import math
import os
import subprocess
import sys

import cv2
import numpy as np

from make_videos import HERE, SRC_DIR, sample, smoothstep, tile_noise

NAME = "09-quan-dong-khach"
W_OUT, H_OUT = 1280, 720
FPS = 30
DURATION = 8.0

CROP_X = (110, 1096)       # bỏ viền đen hai bên ảnh chụp màn hình
NEST_BOX = (990, 10, 1082, 58)  # chữ "Nest" (toạ độ ảnh gốc)

# Toạ độ theo ảnh gốc 1206x555.
#   (x, y, bán kính, kiểu cử động)
#   an:    gắp ăn - gật lên xuống
#   noi:   nói chuyện - nghiêng qua lại
#   phuc:  nhân viên phục vụ - cúi người, tay đưa bát
PEOPLE = [
    (497, 97, 10, "noi"),
    (568, 132, 14, "an"),
    (438, 205, 14, "noi"),
    (462, 222, 16, "phuc"),
    (482, 270, 22, "phuc"),
    (452, 335, 16, "phuc"),
    (490, 238, 12, "an"),
    (338, 285, 12, "noi"),
    (305, 332, 15, "noi"),
    (322, 395, 15, "an"),
    (522, 330, 18, "an"),
    (482, 368, 13, "an"),
    (575, 455, 20, "an"),
    (482, 470, 12, "an"),
    (255, 487, 15, "noi"),
    (277, 530, 14, "noi"),
    (618, 230, 16, "an"),
    (614, 282, 12, "an"),
    (663, 282, 15, "an"),
    (660, 150, 13, "an"),
    (613, 115, 10, "noi"),
    (625, 137, 12, "noi"),
    (690, 112, 10, "noi"),
    (718, 117, 10, "an"),
    (753, 115, 10, "noi"),
    (783, 142, 14, "an"),
    (723, 177, 13, "noi"),
    (750, 200, 16, "noi"),
    (823, 210, 15, "noi"),
    (848, 165, 11, "an"),
    (908, 197, 13, "an"),
    (933, 187, 12, "an"),
    (985, 235, 16, "an"),
    (958, 256, 11, "an"),
    (838, 265, 13, "noi"),
    (905, 240, 12, "an"),
    (1068, 450, 18, "noi"),
]

# biên độ (px) ngang, dọc và khoảng thời gian giữa hai lần đổi tư thế (giây)
MOTION = {
    "an": (1.2, 2.0, (0.35, 0.7)),
    "noi": (2.0, 1.0, (0.45, 0.9)),
    "phuc": (3.0, 2.5, (0.4, 0.8)),
}

LAMP = (300, 210, 105, 75)       # đèn tre treo trần
LAMP_PIVOT_Y = 48
WINDOW = (700, 0, 1096, 300)     # vùng cửa kính

CAM = [(1.0, 603, 277.5), (1.12, 610, 270)]


class Wiggle:
    """Chuỗi giá trị ngẫu nhiên mượt trong khoảng -1..1 theo thời gian."""

    def __init__(self, rng, step_range):
        self.times, self.vals = [0.0], [rng.uniform(-1, 1)]
        while self.times[-1] < DURATION + 1:
            self.times.append(self.times[-1] + rng.uniform(*step_range))
            self.vals.append(rng.uniform(-1, 1))

    def __call__(self, t):
        i = np.searchsorted(self.times, t, side="right") - 1
        u = (t - self.times[i]) / (self.times[i + 1] - self.times[i])
        u = u * u * (3 - 2 * u)
        return self.vals[i] + (self.vals[i + 1] - self.vals[i]) * u


def load_source():
    img = cv2.imread(os.path.join(SRC_DIR, NAME + ".jpg"), cv2.IMREAD_COLOR)
    if img is None:
        sys.exit("Không đọc được ảnh " + NAME)
    x0, y0, x1, y1 = NEST_BOX
    gray = cv2.cvtColor(img[y0:y1, x0:x1], cv2.COLOR_BGR2GRAY)
    mask = np.zeros(img.shape[:2], np.uint8)
    mask[y0:y1, x0:x1] = (gray > 185).astype(np.uint8) * 255
    mask = cv2.dilate(mask, np.ones((5, 5), np.uint8))
    img = cv2.inpaint(img, mask, 6, cv2.INPAINT_TELEA)
    img = img[:, CROP_X[0]:CROP_X[1]]
    return cv2.cvtColor(img, cv2.COLOR_BGR2RGB).astype(np.float32) / 255.0


class Busy:
    def __init__(self):
        self.src = load_source()
        self.h, self.w = self.src.shape[:2]
        self.k = min(self.w / W_OUT, self.h / H_OUT)
        ys, xs = np.mgrid[0:self.h, 0:self.w].astype(np.float32)
        xs += CROP_X[0]  # các lớp hiệu ứng dùng toạ độ ảnh gốc
        self.xs, self.ys = xs, ys

        rng = np.random.default_rng(36)
        self.people = []
        for x, y, r, kind in PEOPLE:
            ax, ay, step = MOTION[kind]
            w = np.exp(-(((xs - x) ** 2 + (ys - y) ** 2) / (2 * (1.3 * r) ** 2))).astype(np.float32)
            self.people.append((w, ax, ay, Wiggle(rng, step), Wiggle(rng, step)))

        lx, ly, lrx, lry = LAMP
        r = np.sqrt(((xs - lx) / lrx) ** 2 + ((ys - ly) / lry) ** 2)
        reach = np.clip((ys - LAMP_PIVOT_Y) / (ly - LAMP_PIVOT_Y), 0, 1.2)
        self.lamp_w = ((1 - smoothstep(0.8, 1.15, r)) * reach).astype(np.float32)

        x0, y0, x1, y1 = WINDOW
        self.window_w = (smoothstep(x0 - 40, x0 + 40, xs) * (1 - smoothstep(y1 - 60, y1 + 20, ys))).astype(np.float32)
        self.light_tex = tile_noise(512, 7, cutoff=0.02)

        gx = np.arange(W_OUT, dtype=np.float32) + 0.5 - W_OUT / 2
        gy = np.arange(H_OUT, dtype=np.float32) + 0.5 - H_OUT / 2
        self.gx, self.gy = np.meshgrid(gx, gy)

    def camera_map(self, t):
        (s0, x0, y0), (s1, x1, y1) = CAM
        e = t / DURATION
        e = e - 0.6 * math.sin(2 * math.pi * e) / (2 * math.pi)
        s = 1 / ((1 / s0) + ((1 / s1) - (1 / s0)) * e)
        cx = x0 + (x1 - x0) * e - CROP_X[0]
        cy = y0 + (y1 - y0) * e
        f = self.k / s
        return (cx + f * self.gx - 0.5).astype(np.float32), (cy + f * self.gy - 0.5).astype(np.float32)

    def displacement(self, t):
        dx = np.zeros_like(self.xs)
        dy = np.zeros_like(self.xs)
        for w, ax, ay, fx, fy in self.people:
            dx += w * (ax * fx(t))
            dy += w * (ay * fy(t))
        swing = math.sin(2 * math.pi * t / 3.6)
        dx += self.lamp_w * 1.6 * swing
        dy += self.lamp_w * 0.3 * abs(swing)
        return dx, dy

    def light(self, t):
        n = sample(self.light_tex, self.xs / 2 + t * 25, self.ys / 2 + t * 6)
        flicker = 1.0 + 0.012 * math.sin(2 * math.pi * t / 1.7) * math.sin(2 * math.pi * t / 2.9)
        return (flicker * (1.0 + self.window_w * 0.09 * (2 * n - 1))).astype(np.float32)

    def frame(self, t):
        mx, my = self.camera_map(t)
        dx, dy = self.displacement(t)
        lit = self.src * self.light(t)[..., None]
        mapx = mx + cv2.remap(dx, mx, my, cv2.INTER_LINEAR, borderMode=cv2.BORDER_REPLICATE)
        mapy = my + cv2.remap(dy, mx, my, cv2.INTER_LINEAR, borderMode=cv2.BORDER_REPLICATE)
        img = cv2.remap(lit, mapx, mapy, cv2.INTER_CUBIC, borderMode=cv2.BORDER_REFLECT)
        return (np.clip(img, 0, 1) * 255 + 0.5).astype(np.uint8)


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
    for i in range(int(round(DURATION * FPS))):
        proc.stdin.write(scene.frame(i / FPS).tobytes())
    proc.stdin.close()
    if proc.wait() != 0:
        sys.exit("ffmpeg lỗi khi xuất " + path)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--preview", metavar="DIR", help="chỉ xuất vài khung hình PNG vào thư mục này")
    args = ap.parse_args()

    scene = Busy()
    if args.preview:
        os.makedirs(args.preview, exist_ok=True)
        for t in (0.0, DURATION / 2, DURATION - 1 / FPS):
            cv2.imwrite(os.path.join(args.preview, f"{NAME}_{t:.1f}.png"), cv2.cvtColor(scene.frame(t), cv2.COLOR_RGB2BGR))
        return
    path = os.path.join(HERE, NAME + ".mp4")
    encode(scene, path)
    print("xong", path)


if __name__ == "__main__":
    main()
