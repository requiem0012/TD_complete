# 光影随芯 · TD_complete

基于安路 EG4S20BG256 / HX4S20C 的 HDMI 多媒体播放系统。当前发布为 **2026-10-27 三张图片、640×480 BC1、稳定 6 fps 视频版**。

## 功能

- 图片 1→2→3→1 切换，支持上一张、每 3 秒自动轮播；第四张槽位保留但不参与显示。
- 双帧 SDRAM 缓存，约 1.5 秒滑动、立体纸飞机、消散三种切图效果，预加载期间保留旧画面。
- 640×480 BC1 视频，6 fps；48 kHz / 16-bit 单声道 PCM，经 HDMI 左右声道同时输出。
- 视频切换、暂停 / 恢复、重播、当前视频循环，以及读卡校验与异常恢复。
- 图片序号、视频时间戳、模式 / 特效字幕、滚动字幕、亮度调整和实时音频波形。
- 双 HDMI 输出相同内容。实际像素时钟 25 MHz，800×525 时序，刷新率约 59.52 Hz。

媒体由 PC 离线转换，FPGA 不直接解码 MP4 / JPEG，也不读取 FAT 文件系统。

## 目录和配置文件

- `prj/tf_hdmi_display.al`：TangDynasty 工程，顶层 `tf_hdmi_top`。
- **`prj/TD_complete_3photos_20261027.bit`**：当前应下载的 FPGA 配置文件；`prj/TD_complete.bit` 与其内容相同。
- `source_code/rtl/`：SD SPI、加载控制、SDRAM、BC1 显示、HDMI 音视频、交互和特效 RTL。
- `source_code/adc_sdc/`：实际引脚和时钟约束。
- `tools/`：Python 媒体转换、测试脚本，以及两段最新视频媒体。
- `tools/tests/`：Verilog 仿真源和测试数据；`tools/plane_3d_preview/` 为算法参考预览，非实板录像。
- `docs/technical_report_20261026.pdf`：技术文档；该文档形成于三张图片范围修改之前，图片数量以当前源码和本 README 为准。
- `reports/`：最近一次生成的综合资源与布线后时序报告。
- `EXPORT_MANIFEST.json`：原导出文件 SHA256 清单及目录整理说明。

发布 bit SHA256：

```text
27A27793F20797C061B38699557D2A3F01A7521177E557E7E8228791BAA09771
```

本上传副本将原目录的 `prj/prj`、`tools/tools` 整理为常规单层目录，并将工程根路径改为相对路径。RTL、约束、IP、媒体及 bit 均保持原文件字节；原桌面工程未移动、删除或覆盖。

## 操作

- **KEY1**：图片模式复位；视频模式暂停 / 恢复。
- **KEY2 / KEY3**：下一张 / 上一张图片或视频。
- **KEY4**：图片模式选择滑动→纸飞机→消散，下一次切图生效；视频模式从头重播。
- **SW1**：音频波形显示。图片提示音结束后回到水平线。
- **SW2**：图片 / 视频模式。
- **SW3**：亮度设置，KEY2 增大、KEY3 减小，退出设置后恢复翻页。
- **SW4**：图片模式三秒轮播；视频模式当前片段循环。

## 下载与编译

使用 TangDynasty 6.2（本机编译版本 6.2.3.210850），打开 `prj/tf_hdmi_display.al`。PLL、ADC、SDC 必须实际加载。

从项目根目录运行：

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\build_native.ps1
```

脚本内 TD 安装路径需按本机调整。脚本会检查新生成文件和 setup / hold 结果，成功后更新 `prj/TD_complete.bit`。它不会写 TF 卡或烧板。

BitWriter 的 Program SRAM 用于临时下载；需要掉电保留时使用 Program Flash 并执行 Verify Flash。FPGA 配置 Flash 与 TF 卡媒体是不同存储位置。

## 媒体制作与写入位置

安装 Python 依赖，并在 PATH 配置 FFmpeg（建议同时安装 FFprobe）：

```powershell
python -m pip install -r tools/requirements_hd.txt
python tools/mp4_to_tf_video.py video.mp4 video01.bin --slot 1 --start 0 --duration 10 --fps 6 --quality hq
python tools/mp4_to_tf_video.py video.mp4 video02.bin --slot 2 --start 95 --duration 15 --fps 6 --quality hq
python tools/mp4_to_tf_video.py --inspect video01.bin
```

以上第二条转换命令适用于本次约 110 秒的原始 video.mp4；其他视频需按真实时长选择起点。编码保持比例，黑边填充至 640×480。

仓库已包含：

- `tools/video01_first10s_6fps.bin`：前 10 秒，60 帧，含音频；物理字节偏移 **`0x100000000`**，LBA **8388608**。
- `tools/video02_last15s_6fps.bin`：95–110 秒，90 帧，含音频；物理字节偏移 **`0x120000000`**，LBA **9437184**。

完整 .bin（包括 HXVIDEO3 头部）从对应起点覆盖写入。视频槽位从 4 GiB 起，每槽 512 MiB，最多 32 槽，是原始扇区布局而非文件系统分区。卡必须具有覆盖目标地址的真实可用容量；完整 32 槽需要至少 20 GiB 实际容量。

图片为 HXIMAGE3，前三张分别从 LBA 0、512、1024 开始（每槽 256 KiB）。`tools/TF_NATIVE_4images.img` 是保留的历史四图合并素材，当前逻辑仅读前三张；不必擦除第四张。

**写物理卡会覆盖对应扇区的现有内容。** 先确认目标磁盘身份和偏移；把 .bin 复制到 TF 卡文件夹不会被此工程读取。请勿把媒体 .bin 与 FPGA .bit 配置文件混用。

## 验证与边界

2026-10-27 已生成新 bit：setup WNS +1.731 ns，hold WNS +0.020 ns，TNS 为 0，STA 覆盖 99.97%。仍保留原有局部时钟及外部接口时序约束告警，不代表完整接口签核。

本次三图修改已通过图片序号 / 字模、正反回绕、三秒轮播、慢卡等待、特效 / 视频按键、实际图片加载 5 帧 / 1505 扇区 CRC 和无黑屏仿真。新视频已核对头部、槽位、全部 PCM / 补零及首末帧 HQ BC1 数据。三图新 bit 的最终实板效果仍需使用者下载验收。

本仓库不捆绑 TD、FFmpeg、Icarus 或 Python 环境。测试脚本使用 `tools/.test_deps/icarus/ucrt64/bin`；在 Windows 安装 Icarus 后需调整 `tools/run_native_tests.py` 的 BIN 路径或按其目录布置工具。历史测试和素材不全等同于当前版本的重新验证结果。

## 第三方代码

HDMI 合并核的 MIT 许可保留在 `source_code/rtl/hdmi_audio/LICENSE.txt`。历史加密 DVI IP 保留原样且不属于当前活动发送链；其权利归各自提供方。本仓库未将第三方 IP 或媒体重新声明为统一开源许可。
