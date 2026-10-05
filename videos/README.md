# Video chuyển động món ăn

Ảnh tĩnh trong `source/` được dựng thành video ngắn 6 giây (1080x1350, tỉ lệ 4:5, 30fps):

| File | Món |
|---|---|
| `01-ga.mp4` | Bát gà, đẩy máy vào gần |
| `02-luon.mp4` | Bát lươn, đẩy máy vào và xoay nhẹ |
| `03-nem.mp4` | Nem rán và rau sống, lia ngang |
| `04-chan-gio.mp4` | Bát chân giò, đẩy máy vào gần |
| `05-toan-canh.mp4` | Toàn cảnh bàn ăn, kéo máy ra |
| `tong-hop.mp4` | Ghép cả 5 clip, chuyển cảnh mờ dần (27,6 giây) |

Hiệu ứng: máy quay chuyển động chậm, hơi nóng bốc lên từ bát, nước dùng gợn nhẹ, rau lay nhẹ, ánh nắng thay đổi nhẹ.

Dựng lại (ví dụ sau khi chỉnh vị trí hơi nóng hoặc thời lượng trong `make_videos.py`):

```
pip install numpy opencv-python-headless   # cần có ffmpeg
python3 videos/make_videos.py --preview /tmp/xem-thu   # xuất vài khung hình để xem trước
python3 videos/make_videos.py                          # xuất toàn bộ video
```
