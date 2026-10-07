# Quét ổ C – tìm nguyên nhân ổ C bị đầy (CHỈ ĐỌC)

Bộ công cụ này **chỉ đo và báo cáo**. Nó **không xoá, không sửa** file, registry hay cấu hình Windows.
Thứ duy nhất được ghi ra là thư mục báo cáo `BaoCao\` (vài MB) nằm cạnh script.

## Cách chạy (Windows 10/11)

1. Tải 2 file `Scan-CDrive.ps1` và `ChayQuet.cmd` về **cùng một thư mục**
   (hoặc tải cả nhánh dưới dạng ZIP rồi giải nén).
2. Nhấp đúp **`ChayQuet.cmd`** → cửa sổ UAC hiện ra → bấm **Yes**
   (script cần quyền **Administrator** để đọc được thư mục hệ thống, System Restore và WinSxS).
   - Nếu Windows SmartScreen cảnh báo: bấm *More info* → *Run anyway*
     (hoặc chuột phải file → *Properties* → tích *Unblock*).
3. Chờ khoảng **3–20 phút** (tuỳ số lượng file và ổ SSD/HDD). Cuối cùng Notepad sẽ mở `BaoCao-TomTat.txt`.

Cách khác: mở **PowerShell (Run as administrator)**, chuyển vào thư mục chứa script rồi chạy

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Scan-CDrive.ps1
```

`-ExecutionPolicy Bypass` chỉ áp dụng cho lần chạy này, không đổi cấu hình máy.

Các tham số tuỳ chọn:

| Tham số | Ý nghĩa |
|---|---|
| `-RecentDays 3` | Số ngày gần đây dùng để tính "dữ liệu mới ghi" (mặc định 7) |
| `-SkipDism` | Bỏ qua bước DISM phân tích WinSxS (nhanh hơn 1–5 phút) |
| `-OutputDir D:\BaoCao` | Lưu báo cáo ở nơi khác |

## Sau khi chạy

- Mở `BaoCao\<ngày-giờ>\BaoCao-TomTat.txt`, xem lại (báo cáo có tên thư mục/file – bạn có thể che những tên riêng tư), rồi **gửi nội dung cho Claude** để nhận phân tích và phương án xử lý theo 3 mức.
- **Nên chạy lại lần 2 sau vài giờ hoặc 1 ngày dùng máy bình thường.** Mục `[17]` của báo cáo sẽ so sánh với lần trước và chỉ ra chính xác thư mục nào đang phình to.

## Báo cáo gồm những gì

| Mục | Nội dung |
|---|---|
| [0] | Tóm tắt nhanh |
| [1] | Dung lượng tổng / đã dùng / còn trống, sức khoẻ ổ đĩa, số lần Windows cảnh báo "ổ đầy", lỗi NTFS |
| [2] | Top 20 vị trí chiếm dung lượng (không trùng lặp – mỗi byte chỉ tính 1 lần) |
| [3] | Cây thư mục lớn; đánh dấu thư mục lạ ở gốc `C:\` |
| [4] | Top 20 file lớn nhất |
| [5]–[6] | Xếp hạng và chi tiết theo nguyên nhân: Windows Update, Temp, WER/crash dump, thùng rác, Store, trình duyệt, OneDrive, Docker/WSL/máy ảo/giả lập Android, Zalo/Telegram/Teams, CapCut/Adobe, game, cache lập trình/AI… |
| [7] | pagefile.sys, hiberfil.sys, RAM, Hibernate/Fast Startup, cấu hình crash dump |
| [8] | System Restore / Shadow Copies (dung lượng tối đa, số restore point) |
| [9] | Windows Update, WinSxS thật sự (DISM), Reserved Storage, CompactOS |
| [10] | AppData chi tiết theo từng ứng dụng |
| [11]–[12] | Dữ liệu mới ghi gần đây + tiến trình ghi nhiều dữ liệu nhất → tìm ứng dụng đang liên tục làm đầy ổ |
| [13]–[15] | File ổ đĩa ảo/dump/ISO/log lớn, dung lượng theo loại file, phần mềm đã cài (và cài trong 90 ngày gần đây) |
| [16] | Storage Sense, vị trí thư mục Desktop/Documents/Downloads |
| [17] | So sánh với lần quét trước |
| [18] | Ước tính có thể giải phóng + những thứ KHÔNG nên xoá |
| [19] | Ghi chú độ chính xác (thư mục không truy cập được, junction bỏ qua, file chỉ trên cloud) |

Mức phân loại trong báo cáo:

- **A** – an toàn tuyệt đối: cache/tệp tạm, Windows hoặc ứng dụng tự tạo lại; dọn bằng công cụ chính thống.
- **B** – an toàn nhưng cần cân nhắc: mất khả năng quay lại bản Windows cũ, phải tải lại, hoặc là dữ liệu của ứng dụng.
- **C** – không nên đụng vào / chỉ là số tổng để tham khảo.
- **CN** – dữ liệu cá nhân: **không xoá**, chỉ cân nhắc **chuyển** sang ổ khác.

## Độ chính xác của số đo

- Bỏ qua junction/symlink nên không đếm trùng (ví dụ `C:\Documents and Settings`).
- File OneDrive "chỉ trên cloud" không chiếm chỗ trên ổ nên không được tính vào tổng (báo riêng).
- File nén (NTFS, WOF/CompactOS) và file sparse được tính theo dung lượng thật trên đĩa, không theo kích thước danh nghĩa.
- File có nhiều tên (hard link, ví dụ `WinSxS` ↔ `System32`) chỉ được tính một lần; con số chính thức của WinSxS lấy từ DISM ở mục [9].
- Đã chạy thử trên Windows thật (Windows PowerShell 5.1, ~1,2 triệu file): tổng đo được lệch dưới 3% so với "đã dùng" của Windows; phần lệch là metadata NTFS và thư mục hệ thống bị khoá.
- `System Volume Information` (nơi chứa restore point) không đọc trực tiếp được; dung lượng của nó lấy từ `vssadmin` / WMI ở mục [8].

## Lệnh hệ thống được gọi (đều chỉ đọc)

`vssadmin list shadowstorage`, `Dism /Online /Cleanup-Image /AnalyzeComponentStore`,
`Dism /Online /Get-ReservedStorageState`, `powercfg /a`, `fsutil dirty query C:`, `compact /compactos:query`,
cùng các truy vấn WMI/CIM, registry (chỉ đọc) và Event Log.
