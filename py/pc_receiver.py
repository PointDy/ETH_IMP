import math
import socket
import struct
import sys
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Optional, Tuple

import numpy as np
from PySide6.QtCore import QThread, Qt, Signal
from PySide6.QtGui import QImage, QPixmap
from PySide6.QtWidgets import (
    QApplication,
    QCheckBox,
    QComboBox,
    QFormLayout,
    QGridLayout,
    QGroupBox,
    QHBoxLayout,
    QLabel,
    QLineEdit,
    QMainWindow,
    QMessageBox,
    QPushButton,
    QSpinBox,
    QVBoxLayout,
    QWidget,
)


DEFAULT_BIND_IP = "0.0.0.0"
DEFAULT_PORT = 1234
DEFAULT_WIDTH = 640
DEFAULT_HEIGHT = 480
DEFAULT_PACKET_PIXEL_BYTES = 1280
HEADER_SIZE = 8
FORMAT_MAGIC = b"\x53\x5A\x48\x59"
MAX_FRAME_CACHE = 4
CAPTURE_DIR = Path(__file__).resolve().parent / "captures"
DEBUG_FILE = Path(__file__).resolve().parent / "debug.txt"
DEBUG_LOG_ALL_PACKETS = False
DEBUG_LOG_PACKET_EVERY = 64
DEFAULT_COLOR_MODE = "little_no_swap"
COLOR_MODE_OPTIONS = {
    "big_no_swap": ("RGB565 大端", "big", False),
    "big_swap_rb": ("RGB565 大端 + 红蓝交换", "big", True),
    "little_no_swap": ("RGB565 小端", "little", False),
    "little_swap_rb": ("RGB565 小端 + 红蓝交换", "little", True),
}


def list_local_ips() -> str:
    ips = {"127.0.0.1"}
    try:
        hostname = socket.gethostname()
        for item in socket.getaddrinfo(hostname, None, socket.AF_INET, socket.SOCK_DGRAM):
            ips.add(item[4][0])
    except OSError:
        pass
    return ", ".join(sorted(ips))


def rgb565_to_rgb888(
    frame_bytes: bytes,
    width: int,
    height: int,
    endian: str = "big",
    swap_rb: bool = False,
) -> np.ndarray:
    dtype = ">u2" if endian == "big" else "<u2"
    pixels = np.frombuffer(frame_bytes, dtype=dtype).astype(np.uint16)
    if pixels.size != width * height:
        raise ValueError(f"pixel count mismatch: expected {width * height}, got {pixels.size}")

    r = ((pixels >> 11) & 0x1F) << 3
    g = ((pixels >> 5) & 0x3F) << 2
    b = (pixels & 0x1F) << 3

    if swap_rb:
        r, b = b, r

    rgb = np.empty((height, width, 3), dtype=np.uint8)
    rgb[..., 0] = (r | (r >> 5)).reshape(height, width).astype(np.uint8)
    rgb[..., 1] = (g | (g >> 6)).reshape(height, width).astype(np.uint8)
    rgb[..., 2] = (b | (b >> 5)).reshape(height, width).astype(np.uint8)
    return rgb


class DebugLogger:
    def __init__(self, file_path: Path) -> None:
        self.file_path = file_path
        self._lock = threading.Lock()
        self.reset()

    def reset(self) -> None:
        with self._lock:
            self.file_path.write_text("", encoding="utf-8")

    def log(self, message: str) -> None:
        timestamp = time.strftime("%Y-%m-%d %H:%M:%S")
        with self._lock:
            with self.file_path.open("a", encoding="utf-8") as fp:
                fp.write(f"[{timestamp}] {message}\n")


DEBUG_LOGGER = DebugLogger(DEBUG_FILE)


@dataclass
class ReceiverStats:
    total_packets: int = 0
    duplicate_packets: int = 0
    out_of_order_packets: int = 0
    dropped_frames: int = 0
    completed_frames: int = 0
    current_frame_id: int = -1
    fps: float = 0.0


class FrameAssembly:
    def __init__(self, frame_id: int, frame_bytes: int, packet_payload_bytes: int) -> None:
        self.frame_id = frame_id
        self.frame_bytes = frame_bytes
        self.packet_payload_bytes = packet_payload_bytes
        self.expected_packets = math.ceil(frame_bytes / packet_payload_bytes)
        self.buffer = bytearray(frame_bytes)
        self.received: List[bool] = [False] * self.expected_packets
        self.received_count = 0
        self.got_sof = False
        self.got_eof = False
        self.last_packet_id = -1
        self.eof_packet_id: Optional[int] = None
        self.last_update = time.time()

    def add_packet(self, packet_id: int, valid_pixel_bytes: int, flags: int, payload: bytes) -> Tuple[bool, bool]:
        self.last_update = time.time()
        if packet_id < 0 or packet_id >= self.expected_packets:
            return False, False

        is_duplicate = self.received[packet_id]
        is_out_of_order = (self.last_packet_id != -1 and packet_id < self.last_packet_id)
        self.last_packet_id = max(self.last_packet_id, packet_id)

        if flags & 0x8000:
            self.got_sof = True
        if flags & 0x4000:
            self.got_eof = True
            self.eof_packet_id = packet_id

        if is_duplicate:
            return True, is_out_of_order

        effective_valid = valid_pixel_bytes if valid_pixel_bytes != 0 else len(payload)
        copy_len = min(effective_valid, len(payload))
        start = packet_id * self.packet_payload_bytes
        end = min(start + copy_len, self.frame_bytes)
        if start < self.frame_bytes and end > start:
            self.buffer[start:end] = payload[: end - start]

        self.received[packet_id] = True
        self.received_count += 1
        return False, is_out_of_order

    def is_complete(self) -> bool:
        if not (self.got_sof and self.got_eof and self.eof_packet_id is not None):
            return False
        expected = self.eof_packet_id + 1
        if expected != self.expected_packets:
            return False
        return self.received_count == self.expected_packets

    def can_finalize(self) -> bool:
        if not (self.got_sof and self.got_eof and self.eof_packet_id is not None):
            return False
        return (self.eof_packet_id + 1) == self.expected_packets

    def missing_packets(self) -> int:
        return self.expected_packets - self.received_count


class FrameReassembler:
    def __init__(
        self,
        width: int,
        height: int,
        packet_payload_bytes: int,
        color_endian: str,
        color_swap_rb: bool,
    ) -> None:
        self.width = width
        self.height = height
        self.packet_payload_bytes = packet_payload_bytes
        self.color_endian = color_endian
        self.color_swap_rb = color_swap_rb
        self.frame_bytes = width * height * 2
        self.frames: Dict[int, FrameAssembly] = {}
        self.stats = ReceiverStats()
        self._fps_times: List[float] = []
        self._waiting_for_sof = True
        self._packet_log_counter = 0

    def reset(
        self,
        width: int,
        height: int,
        packet_payload_bytes: int,
        color_endian: str,
        color_swap_rb: bool,
    ) -> None:
        self.width = width
        self.height = height
        self.packet_payload_bytes = packet_payload_bytes
        self.color_endian = color_endian
        self.color_swap_rb = color_swap_rb
        self.frame_bytes = width * height * 2
        self.frames.clear()
        self.stats = ReceiverStats()
        self._fps_times.clear()
        self._waiting_for_sof = True
        self._packet_log_counter = 0

    def _touch_fps(self) -> None:
        now = time.time()
        self._fps_times.append(now)
        window_start = now - 1.0
        self._fps_times = [t for t in self._fps_times if t >= window_start]
        self.stats.fps = float(len(self._fps_times))

    def _drop_stale_frames(self, incoming_frame_id: int) -> None:
        stale_ids = [fid for fid in self.frames if fid < incoming_frame_id - 1]
        for fid in stale_ids:
            if not self.frames[fid].is_complete():
                self.stats.dropped_frames += 1
                DEBUG_LOGGER.log(f"drop stale frame frame_id={fid}")
            del self.frames[fid]

        while len(self.frames) > MAX_FRAME_CACHE:
            oldest = min(self.frames.keys())
            if not self.frames[oldest].is_complete():
                self.stats.dropped_frames += 1
                DEBUG_LOGGER.log(f"drop cache overflow frame frame_id={oldest}")
            del self.frames[oldest]

    def process_datagram(
        self, datagram: bytes
    ) -> Tuple[Optional[Tuple[bytes, np.ndarray]], ReceiverStats, str]:
        if datagram.startswith(FORMAT_MAGIC):
            DEBUG_LOGGER.log(f"ignore format packet len={len(datagram)}")
            return None, self.stats, "ignored format packet"

        if len(datagram) < HEADER_SIZE:
            DEBUG_LOGGER.log(f"short payload len={len(datagram)}")
            return None, self.stats, "ignored short UDP payload"

        frame_id, packet_id, valid_pixel_bytes, flags = struct.unpack(">HHHH", datagram[:HEADER_SIZE])
        payload = datagram[HEADER_SIZE:]
        has_sof = bool(flags & 0x8000)
        has_eof = bool(flags & 0x4000)
        raw_head = datagram[:16].hex(" ")

        self.stats.total_packets += 1
        self.stats.current_frame_id = frame_id
        self._drop_stale_frames(frame_id)

        if self._waiting_for_sof and not has_sof:
            DEBUG_LOGGER.log(
                f"ignore packet before sof frame_id={frame_id} packet_id={packet_id} flags=0x{flags:04X}"
            )
            return None, self.stats, "waiting for sof"
        if has_sof:
            self._waiting_for_sof = False

        if frame_id not in self.frames:
            self.frames[frame_id] = FrameAssembly(frame_id, self.frame_bytes, self.packet_payload_bytes)
            DEBUG_LOGGER.log(
                f"new frame frame_id={frame_id} expected_packets={self.frames[frame_id].expected_packets}"
            )
        frame = self.frames[frame_id]

        is_duplicate, is_out_of_order = frame.add_packet(packet_id, valid_pixel_bytes, flags, payload)
        if is_duplicate:
            self.stats.duplicate_packets += 1
        if is_out_of_order:
            self.stats.out_of_order_packets += 1

        prev_counter = self._packet_log_counter
        self._packet_log_counter += 1
        if (
            DEBUG_LOG_ALL_PACKETS
            or has_sof
            or has_eof
            or is_duplicate
            or is_out_of_order
            or packet_id == 0
            or packet_id == (frame.expected_packets - 1)
            or (prev_counter % DEBUG_LOG_PACKET_EVERY) == 0
        ):
            DEBUG_LOGGER.log(
                "packet "
                f"frame_id={frame_id} packet_id={packet_id} valid={valid_pixel_bytes} "
                f"flags=0x{flags:04X} sof={(flags >> 15) & 1} eof={(flags >> 14) & 1} "
                f"payload_len={len(payload)} head16={raw_head} duplicate={int(is_duplicate)} "
                f"ooo={int(is_out_of_order)} received_count={frame.received_count}/{frame.expected_packets}"
            )

        status = (
            f"frame={frame_id} packet={packet_id} valid={valid_pixel_bytes} "
                f"sof={1 if flags & 0x8000 else 0} eof={1 if flags & 0x4000 else 0}"
        )

        if frame.can_finalize():
            try:
                rgb = rgb565_to_rgb888(
                    bytes(frame.buffer),
                    self.width,
                    self.height,
                    endian=self.color_endian,
                    swap_rb=self.color_swap_rb,
                )
            except ValueError as exc:
                DEBUG_LOGGER.log(f"frame convert failed frame_id={frame_id} error={exc}")
                return None, self.stats, f"frame {frame_id} convert failed: {exc}"
            missing_packets = frame.missing_packets()
            raw_frame = bytes(frame.buffer)
            if missing_packets == 0:
                self.stats.completed_frames += 1
                DEBUG_LOGGER.log(
                    f"frame complete frame_id={frame_id} completed_frames={self.stats.completed_frames}"
                )
                status_text = f"frame {frame_id} complete"
            else:
                self.stats.dropped_frames += 1
                DEBUG_LOGGER.log(
                    f"frame partial frame_id={frame_id} missing_packets={missing_packets}"
                )
                status_text = f"frame {frame_id} partial, missing={missing_packets}"

            self._touch_fps()
            self._waiting_for_sof = True
            del self.frames[frame_id]
            older = [fid for fid in self.frames if fid < frame_id]
            for fid in older:
                if not self.frames[fid].is_complete():
                    self.stats.dropped_frames += 1
                    DEBUG_LOGGER.log(f"drop older incomplete frame frame_id={fid}")
                del self.frames[fid]
            return (raw_frame, rgb), self.stats, status_text

        return None, self.stats, status


class ReceiverThread(QThread):
    frame_ready = Signal(object)
    stats_ready = Signal(dict)
    status_ready = Signal(str)
    error_ready = Signal(str)

    def __init__(self) -> None:
        super().__init__()
        self._stop_event = threading.Event()
        self._socket: Optional[socket.socket] = None
        self.bind_ip = DEFAULT_BIND_IP
        self.port = DEFAULT_PORT
        self.width = DEFAULT_WIDTH
        self.height = DEFAULT_HEIGHT
        self.packet_payload_bytes = DEFAULT_PACKET_PIXEL_BYTES
        _, self.color_endian, self.color_swap_rb = COLOR_MODE_OPTIONS[DEFAULT_COLOR_MODE]
        self.reassembler = FrameReassembler(
            self.width,
            self.height,
            self.packet_payload_bytes,
            self.color_endian,
            self.color_swap_rb,
        )

    def configure(
        self,
        bind_ip: str,
        port: int,
        width: int,
        height: int,
        packet_payload_bytes: int,
        color_mode: str,
    ) -> None:
        self.bind_ip = bind_ip
        self.port = port
        self.width = width
        self.height = height
        self.packet_payload_bytes = packet_payload_bytes
        _, self.color_endian, self.color_swap_rb = COLOR_MODE_OPTIONS[color_mode]
        self.reassembler.reset(
            width,
            height,
            packet_payload_bytes,
            self.color_endian,
            self.color_swap_rb,
        )

    def stop(self) -> None:
        self._stop_event.set()
        if self._socket is not None:
            try:
                self._socket.close()
            except OSError:
                pass
        self.wait(1500)

    def run(self) -> None:
        self._stop_event.clear()
        DEBUG_LOGGER.reset()
        DEBUG_LOGGER.log(
            f"receiver start bind_ip={self.bind_ip} port={self.port} "
            f"width={self.width} height={self.height} packet_bytes={self.packet_payload_bytes}"
        )

        try:
            self._socket = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            self._socket.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4 * 1024 * 1024)
            self._socket.bind((self.bind_ip, self.port))
            self._socket.settimeout(0.2)
            self.status_ready.emit(f"listening on {self.bind_ip}:{self.port}")
            DEBUG_LOGGER.log("socket bind success")
        except OSError as exc:
            DEBUG_LOGGER.log(f"socket bind failed: {exc}")
            self.error_ready.emit(f"socket bind failed: {exc}")
            return

        while not self._stop_event.is_set():
            try:
                datagram, addr = self._socket.recvfrom(2048)
            except socket.timeout:
                continue
            except OSError as exc:
                DEBUG_LOGGER.log(f"socket closed: {exc}")
                break

            if DEBUG_LOG_ALL_PACKETS:
                DEBUG_LOGGER.log(f"udp recv from={addr[0]}:{addr[1]} len={len(datagram)}")

            frame_payload, stats, status = self.reassembler.process_datagram(datagram)
            self.stats_ready.emit(
                {
                    "current_frame_id": stats.current_frame_id,
                    "completed_frames": stats.completed_frames,
                    "fps": stats.fps,
                    "total_packets": stats.total_packets,
                    "duplicate_packets": stats.duplicate_packets,
                    "out_of_order_packets": stats.out_of_order_packets,
                    "dropped_frames": stats.dropped_frames,
                }
            )
            self.status_ready.emit(status)
            if frame_payload is not None:
                self.frame_ready.emit(frame_payload)

        DEBUG_LOGGER.log("receiver stopped")
        self.status_ready.emit("receiver stopped")


class MainWindow(QMainWindow):
    def __init__(self) -> None:
        super().__init__()
        self.setWindowTitle("BISHE UDP 图像接收器")
        self.resize(1360, 820)

        self.receiver = ReceiverThread()
        self.receiver.frame_ready.connect(self.on_frame_ready)
        self.receiver.stats_ready.connect(self.on_stats_ready)
        self.receiver.status_ready.connect(self.set_status)
        self.receiver.error_ready.connect(self.on_error)

        self.current_qimage: Optional[QImage] = None
        self.current_frame_rgb: Optional[np.ndarray] = None
        self.current_frame_raw: Optional[bytes] = None

        self.ip_edit = QLineEdit(DEFAULT_BIND_IP)
        self.port_spin = QSpinBox()
        self.port_spin.setRange(1, 65535)
        self.port_spin.setValue(DEFAULT_PORT)

        self.width_spin = QSpinBox()
        self.width_spin.setRange(1, 4096)
        self.width_spin.setValue(DEFAULT_WIDTH)
        self.height_spin = QSpinBox()
        self.height_spin.setRange(1, 4096)
        self.height_spin.setValue(DEFAULT_HEIGHT)
        self.packet_bytes_spin = QSpinBox()
        self.packet_bytes_spin.setRange(2, 65535)
        self.packet_bytes_spin.setSingleStep(2)
        self.packet_bytes_spin.setValue(DEFAULT_PACKET_PIXEL_BYTES)
        self.color_mode_combo = QComboBox()
        for mode_key, (label, _, _) in COLOR_MODE_OPTIONS.items():
            self.color_mode_combo.addItem(label, mode_key)
        default_index = self.color_mode_combo.findData(DEFAULT_COLOR_MODE)
        if default_index >= 0:
            self.color_mode_combo.setCurrentIndex(default_index)
        self.mirror_checkbox = QCheckBox("水平镜像显示")
        self.mirror_checkbox.setChecked(False)

        self.start_button = QPushButton("开始接收")
        self.stop_button = QPushButton("停止接收")
        self.save_button = QPushButton("保存当前帧")
        self.stop_button.setEnabled(False)
        self.save_button.setEnabled(False)

        self.local_ips_label = QLabel(list_local_ips())
        self.local_ips_label.setTextInteractionFlags(Qt.TextSelectableByMouse)

        self.preview_label = QLabel("等待图像数据")
        self.preview_label.setAlignment(Qt.AlignCenter)
        self.preview_label.setMinimumSize(820, 620)
        self.preview_label.setStyleSheet(
            "background:#111; color:#ddd; border:1px solid #444; font-size:18px;"
        )

        self.current_frame_label = QLabel("-")
        self.completed_frames_label = QLabel("0")
        self.fps_label = QLabel("0.0")
        self.total_packets_label = QLabel("0")
        self.duplicate_packets_label = QLabel("0")
        self.out_of_order_label = QLabel("0")
        self.dropped_frames_label = QLabel("0")
        self.debug_file_label = QLabel(str(DEBUG_FILE))
        self.status_label = QLabel("idle")
        self.status_label.setWordWrap(True)

        self.start_button.clicked.connect(self.start_receiver)
        self.stop_button.clicked.connect(self.stop_receiver)
        self.save_button.clicked.connect(self.save_current_frame)
        self.color_mode_combo.currentIndexChanged.connect(self.on_color_mode_changed)
        self.mirror_checkbox.toggled.connect(self.on_mirror_toggled)

        self._build_ui()

    def _build_ui(self) -> None:
        control_group = QGroupBox("网络设置")
        control_form = QFormLayout()
        control_form.addRow("本机 IPv4", self.local_ips_label)
        control_form.addRow("监听 IP", self.ip_edit)
        control_form.addRow("端口", self.port_spin)
        control_form.addRow("宽度", self.width_spin)
        control_form.addRow("高度", self.height_spin)
        control_form.addRow("每包像素字节", self.packet_bytes_spin)
        control_form.addRow("颜色模式", self.color_mode_combo)
        control_form.addRow("显示选项", self.mirror_checkbox)

        button_layout = QHBoxLayout()
        button_layout.addWidget(self.start_button)
        button_layout.addWidget(self.stop_button)
        button_layout.addWidget(self.save_button)
        control_form.addRow(button_layout)
        control_group.setLayout(control_form)

        stats_group = QGroupBox("统计信息")
        stats_grid = QGridLayout()
        stats_grid.addWidget(QLabel("当前 frame_id"), 0, 0)
        stats_grid.addWidget(self.current_frame_label, 0, 1)
        stats_grid.addWidget(QLabel("完成帧数"), 1, 0)
        stats_grid.addWidget(self.completed_frames_label, 1, 1)
        stats_grid.addWidget(QLabel("帧率 FPS"), 2, 0)
        stats_grid.addWidget(self.fps_label, 2, 1)
        stats_grid.addWidget(QLabel("累计包数"), 3, 0)
        stats_grid.addWidget(self.total_packets_label, 3, 1)
        stats_grid.addWidget(QLabel("重复包数"), 4, 0)
        stats_grid.addWidget(self.duplicate_packets_label, 4, 1)
        stats_grid.addWidget(QLabel("乱序包数"), 5, 0)
        stats_grid.addWidget(self.out_of_order_label, 5, 1)
        stats_grid.addWidget(QLabel("丢帧数"), 6, 0)
        stats_grid.addWidget(self.dropped_frames_label, 6, 1)
        stats_group.setLayout(stats_grid)

        status_group = QGroupBox("状态信息")
        status_form = QFormLayout()
        status_form.addRow("调试文件", self.debug_file_label)
        status_form.addRow("保存目录", QLabel(str(CAPTURE_DIR)))
        status_form.addRow("最新状态", self.status_label)
        status_group.setLayout(status_form)

        side_layout = QVBoxLayout()
        side_layout.addWidget(control_group)
        side_layout.addWidget(stats_group)
        side_layout.addWidget(status_group)
        side_layout.addStretch(1)

        main_layout = QHBoxLayout()
        main_layout.addWidget(self.preview_label, 5)
        main_layout.addLayout(side_layout, 2)

        central = QWidget()
        central.setLayout(main_layout)
        self.setCentralWidget(central)

    def start_receiver(self) -> None:
        bind_ip = self.ip_edit.text().strip() or DEFAULT_BIND_IP
        if self.receiver.isRunning():
            return

        self.receiver.configure(
            bind_ip=bind_ip,
            port=self.port_spin.value(),
            width=self.width_spin.value(),
            height=self.height_spin.value(),
            packet_payload_bytes=self.packet_bytes_spin.value(),
            color_mode=self.current_color_mode(),
        )
        self.receiver.start()
        self.start_button.setEnabled(False)
        self.stop_button.setEnabled(True)
        self.save_button.setEnabled(False)
        self.set_status("正在启动接收器...")

    def stop_receiver(self) -> None:
        if self.receiver.isRunning():
            self.receiver.stop()
        self.start_button.setEnabled(True)
        self.stop_button.setEnabled(False)
        self.set_status("接收已停止")

    def closeEvent(self, event) -> None:  # type: ignore[override]
        self.stop_receiver()
        super().closeEvent(event)

    def set_status(self, message: str) -> None:
        self.status_label.setText(message)

    def current_color_mode(self) -> str:
        return str(self.color_mode_combo.currentData())

    def on_color_mode_changed(self) -> None:
        if self.current_frame_raw is None:
            return
        mode_key = self.current_color_mode()
        _, endian, swap_rb = COLOR_MODE_OPTIONS[mode_key]
        try:
            frame_rgb = rgb565_to_rgb888(
                self.current_frame_raw,
                self.width_spin.value(),
                self.height_spin.value(),
                endian=endian,
                swap_rb=swap_rb,
            )
        except ValueError as exc:
            self.set_status(f"颜色模式预览失败：{exc}")
            return
        self.current_frame_rgb = frame_rgb
        self._update_preview(frame_rgb)
        self.set_status(f"当前预览颜色模式：{self.color_mode_combo.currentText()}")

    def on_mirror_toggled(self, checked: bool) -> None:
        if self.current_frame_rgb is not None:
            self._update_preview(self.current_frame_rgb)
        self.set_status("已开启水平镜像显示" if checked else "已关闭水平镜像显示")

    def on_error(self, message: str) -> None:
        self.set_status(message)
        self.start_button.setEnabled(True)
        self.stop_button.setEnabled(False)
        QMessageBox.critical(self, "接收错误", message)

    def on_stats_ready(self, stats: dict) -> None:
        self.current_frame_label.setText(str(stats["current_frame_id"]))
        self.completed_frames_label.setText(str(stats["completed_frames"]))
        self.fps_label.setText(f'{stats["fps"]:.1f}')
        self.total_packets_label.setText(str(stats["total_packets"]))
        self.duplicate_packets_label.setText(str(stats["duplicate_packets"]))
        self.out_of_order_label.setText(str(stats["out_of_order_packets"]))
        self.dropped_frames_label.setText(str(stats["dropped_frames"]))

    def on_frame_ready(self, frame_payload: object) -> None:
        raw_frame, frame_rgb = frame_payload  # type: ignore[misc]
        self.current_frame_raw = bytes(raw_frame)
        self.current_frame_rgb = np.array(frame_rgb, copy=True)
        self._update_preview(self.current_frame_rgb)
        self.save_button.setEnabled(True)

    def _apply_display_options(self, frame_rgb: np.ndarray) -> np.ndarray:
        display_rgb = frame_rgb
        if self.mirror_checkbox.isChecked():
            display_rgb = np.flip(display_rgb, axis=1)
        return np.ascontiguousarray(display_rgb)

    def _update_preview(self, frame_rgb: np.ndarray) -> None:
        display_rgb = self._apply_display_options(frame_rgb)
        height, width, _ = display_rgb.shape
        bytes_per_line = width * 3
        image = QImage(display_rgb.data, width, height, bytes_per_line, QImage.Format_RGB888)
        self.current_qimage = image.copy()
        pixmap = QPixmap.fromImage(self.current_qimage)
        self.preview_label.setPixmap(
            pixmap.scaled(self.preview_label.size(), Qt.KeepAspectRatio, Qt.SmoothTransformation)
        )

    def resizeEvent(self, event) -> None:  # type: ignore[override]
        super().resizeEvent(event)
        if self.current_qimage is not None:
            pixmap = QPixmap.fromImage(self.current_qimage)
            self.preview_label.setPixmap(
                pixmap.scaled(self.preview_label.size(), Qt.KeepAspectRatio, Qt.SmoothTransformation)
            )

    def save_current_frame(self) -> None:
        if self.current_qimage is None:
            QMessageBox.information(self, "提示", "当前还没有可保存的完整图像")
            return

        CAPTURE_DIR.mkdir(parents=True, exist_ok=True)
        timestamp = time.strftime("%Y%m%d_%H%M%S")
        frame_id = self.current_frame_label.text()
        save_path = CAPTURE_DIR / f"frame_{frame_id}_{timestamp}.png"
        if not self.current_qimage.save(str(save_path), "PNG"):
            QMessageBox.warning(self, "保存失败", f"无法保存到 {save_path}")
            return

        self.set_status(f"已保存到 {save_path}")
        DEBUG_LOGGER.log(f"saved frame to {save_path}")


def main() -> int:
    app = QApplication(sys.argv)
    window = MainWindow()
    window.show()
    return app.exec()


if __name__ == "__main__":
    raise SystemExit(main())
