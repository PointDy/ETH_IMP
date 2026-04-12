`timescale 1ns/1ns

//------------------------------------------------------------------------------
// 模块名称 : ct_top
// 模块功能 : CT 目标检测与电视锁定功能的总封装顶层。
// 数据通路 :
//   ct_capture -> ct_detect_core -> ct_track_core -> ct_overlay
// 输出结果 :
// 1. 给 SDRAM 写口的叠加后 RGB565 图像。
// 2. 当前锁定状态、目标有效标志、目标中心坐标。
//------------------------------------------------------------------------------
module ct_top
#(
    parameter [10:0] FRAME_WIDTH          = 11'd640,
    parameter [10:0] FRAME_HEIGHT         = 11'd480,
    parameter [10:0] CENTER_GATE_WIDTH    = 11'd128,
    parameter [10:0] CENTER_GATE_HEIGHT   = 11'd128,
    parameter [10:0] TRACK_GATE_WIDTH     = 11'd96,
    parameter [10:0] TRACK_GATE_HEIGHT    = 11'd96,
    parameter [19:0] LOCK_PIXEL_THRESHOLD = 20'd64,
    parameter [19:0] UNLOCK_THRESHOLD     = 20'd24,
    parameter [3:0]  LOST_FRAME_THRESHOLD = 4'd3
)
(
    input   wire            sys_rst_n,
    input   wire            capture_enable,
    input   wire            algo_enable,
    input   wire            ov5640_pclk,
    input   wire            ov5640_vsync,
    input   wire            ov5640_href,
    input   wire    [7:0]   ov5640_data,
    input   wire            lock_key,

    output  wire            pixel_wr_en,
    output  wire    [15:0]  pixel_data,
    output  wire            target_valid,
    output  wire    [10:0]  target_center_x,
    output  wire    [10:0]  target_center_y,
    output  wire    [1:0]   lock_state
);

wire            cap_vld;
wire            cap_sop;
wire            cap_eop;
wire    [15:0]  cap_data;
wire    [10:0]  cap_x;
wire    [10:0]  cap_y;
wire    [31:0]  frame_sum_x;
wire    [31:0]  frame_sum_y;
wire    [19:0]  frame_pixel_cnt;
wire            frame_stat_valid;
wire    [10:0]  gate_left;
wire    [10:0]  gate_right;
wire    [10:0]  gate_top;
wire    [10:0]  gate_bottom;
wire            edge_pixel;
wire            edge_sop;
wire            edge_eop;
wire            edge_vld;
wire    [10:0]  edge_x;
wire    [10:0]  edge_y;

// 采集模块：把 OV5640 原始 8bit 数据整理成算法可消费的逐像素流。
ct_capture #(
    .FRAME_WIDTH(FRAME_WIDTH),
    .FRAME_HEIGHT(FRAME_HEIGHT)
) u_ct_capture(
    .pclk(ov5640_pclk),
    .rst_n(sys_rst_n),
    .enable(capture_enable),
    .vsync(ov5640_vsync),
    .href(ov5640_href),
    .din(ov5640_data),
    .pixel_data(cap_data),
    .pixel_vld(cap_vld),
    .pixel_sop(cap_sop),
    .pixel_eop(cap_eop),
    .pixel_x(cap_x),
    .pixel_y(cap_y)
);

// 检测模块：完成灰度化、二值化、Sobel 和整帧质心统计。
ct_detect_core #(
    .FRAME_WIDTH(FRAME_WIDTH),
    .FRAME_HEIGHT(FRAME_HEIGHT),
    .USE_GAUSS(1'b0),
    .BIN_THRESHOLD(8'd100)
) u_ct_detect_core(
    .clk(ov5640_pclk),
    .rst_n(sys_rst_n),
    .pixel_sop(cap_sop),
    .pixel_eop(cap_eop),
    .pixel_vld(cap_vld),
    .pixel_data(cap_data),
    .pixel_x(cap_x),
    .pixel_y(cap_y),
    .gate_left(gate_left),
    .gate_right(gate_right),
    .gate_top(gate_top),
    .gate_bottom(gate_bottom),
    .edge_pixel(edge_pixel),
    .edge_sop(edge_sop),
    .edge_eop(edge_eop),
    .edge_vld(edge_vld),
    .edge_x(edge_x),
    .edge_y(edge_y),
    .frame_sum_x(frame_sum_x),
    .frame_sum_y(frame_sum_y),
    .frame_pixel_cnt(frame_pixel_cnt),
    .frame_stat_valid(frame_stat_valid)
);

// 跟踪模块：根据整帧统计量更新锁定状态与动态波门位置。
ct_track_core #(
    .FRAME_WIDTH(FRAME_WIDTH),
    .FRAME_HEIGHT(FRAME_HEIGHT),
    .CENTER_GATE_WIDTH(CENTER_GATE_WIDTH),
    .CENTER_GATE_HEIGHT(CENTER_GATE_HEIGHT),
    .TRACK_GATE_WIDTH(TRACK_GATE_WIDTH),
    .TRACK_GATE_HEIGHT(TRACK_GATE_HEIGHT),
    .LOCK_PIXEL_THRESHOLD(LOCK_PIXEL_THRESHOLD),
    .UNLOCK_THRESHOLD(UNLOCK_THRESHOLD),
    .LOST_FRAME_THRESHOLD(LOST_FRAME_THRESHOLD)
) u_ct_track_core(
    .clk(ov5640_pclk),
    .rst_n(sys_rst_n),
    .lock_key(lock_key),
    .frame_stat_valid(frame_stat_valid),
    .frame_sum_x(frame_sum_x),
    .frame_sum_y(frame_sum_y),
    .frame_pixel_cnt(frame_pixel_cnt),
    .lock_state(lock_state),
    .target_valid(target_valid),
    .target_center_x(target_center_x),
    .target_center_y(target_center_y),
    .gate_left(gate_left),
    .gate_right(gate_right),
    .gate_top(gate_top),
    .gate_bottom(gate_bottom)
);

// 叠加模块：在原图上画出锁定框和目标十字，再送往 SDRAM。
ct_overlay u_ct_overlay(
    .clk(ov5640_pclk),
    .rst_n(sys_rst_n),
    .algo_enable(algo_enable),
    .pixel_vld(cap_vld),
    .pixel_data(cap_data),
    .pixel_x(cap_x),
    .pixel_y(cap_y),
    .lock_state(lock_state),
    .target_valid(target_valid),
    .target_center_x(target_center_x),
    .target_center_y(target_center_y),
    .gate_left(gate_left),
    .gate_right(gate_right),
    .gate_top(gate_top),
    .gate_bottom(gate_bottom),
    .pixel_wr_en(pixel_wr_en),
    .pixel_wr_data(pixel_data)
);

endmodule
