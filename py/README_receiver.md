# BISHE 上位机图像接收程序

这个目录下的 `pc_receiver.py` 是 FPGA 图像 UDP 接收上位机。

## 功能

- 监听默认 `0.0.0.0:1234`
- 按自定义包头 `frame_id + packet_id + valid_pixel_bytes + flags` 重组图像
- 支持乱序包重组
- 实时显示 `RGB565 -> RGB888` 图像
- 显示 `frame_id`、FPS、累计包数、重复包、乱序包、丢帧数
- 保存当前帧为 `PNG`

## 默认协议

- 图像分辨率：`640x480`
- 像素格式：`RGB565`
- 每包像素区：`1024` 字节
- 包头长度：`8` 字节
- 包头格式：
  - `word0 = {frame_id[15:0], packet_id[15:0]}`
  - `word1 = {valid_pixel_bytes[15:0], flags[15:0]}`
  - `flags[15] = sof`
  - `flags[14] = eof`

## 运行

先安装依赖：

```bash
python -m pip install -r requirements.txt
```

启动程序：

```bash
python pc_receiver.py
```

## 打包 exe

安装依赖后执行：

```bash
build_exe.bat
```

成功后会在 `dist\BISHE_Image_Receiver.exe` 生成可执行文件。

## 保存目录

保存图片时会自动创建：

```text
BISHE\captures\
```

## 常见问题

1. 看不到图像
   检查 FPGA 端 UDP 目标端口是否为 `1234`，并确认 PC 防火墙没有拦截。

2. 能收到包但图像异常
   检查 FPGA 端分辨率、RGB565 字节顺序、每包像素字节数是否与界面参数一致。

3. 程序无法绑定端口
   说明端口已被其他程序占用，换一个端口或关闭占用程序。
