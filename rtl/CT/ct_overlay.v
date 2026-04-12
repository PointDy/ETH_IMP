`timescale 1ns/1ns

//------------------------------------------------------------------------------
// 模块名称 : ct_overlay
// 模块功能 : 在原始 RGB565 图像上叠加锁定框和目标十字。
// 设计说明 :
// 1. 只覆盖极少数 OSD 像素，原始画面大部分保持不变。
// 2. 未锁定、跟踪、丢锁分别使用不同颜色，便于上位机观察状态。
//------------------------------------------------------------------------------
module ct_overlay(
    input   wire            clk,
    input   wire            rst_n,
    input   wire            algo_enable,
    input   wire            pixel_vld,
    input   wire    [15:0]  pixel_data,
    input   wire    [10:0]  pixel_x,
    input   wire    [10:0]  pixel_y,
    input   wire    [1:0]   lock_state,
    input   wire            target_valid,
    input   wire    [10:0]  target_center_x,
    input   wire    [10:0]  target_center_y,
    input   wire    [10:0]  gate_left,
    input   wire    [10:0]  gate_right,
    input   wire    [10:0]  gate_top,
    input   wire    [10:0]  gate_bottom,

    output  reg             pixel_wr_en,
    output  reg     [15:0]  pixel_wr_data
);

localparam [15:0] COLOR_IDLE  = 16'h07E0;
localparam [15:0] COLOR_TRACK = 16'hF800;
localparam [15:0] COLOR_LOST  = 16'hFFE0;

wire on_box_border;
wire on_cross;
wire [15:0] overlay_color;
wire [10:0] cross_left;
wire [10:0] cross_right;
wire [10:0] cross_top;
wire [10:0] cross_bottom;

// 锁定框只画边框，不填充内部区域。
assign on_box_border = (((pixel_x == gate_left) || (pixel_x == gate_right)) &&
                        (pixel_y >= gate_top) && (pixel_y <= gate_bottom)) ||
                       (((pixel_y == gate_top) || (pixel_y == gate_bottom)) &&
                        (pixel_x >= gate_left) && (pixel_x <= gate_right));

// 目标中心画成小十字，长度固定为左右上下各 4 个像素。
assign cross_left   = (target_center_x > 11'd4) ? (target_center_x - 11'd4) : 11'd0;
assign cross_right  = target_center_x + 11'd4;
assign cross_top    = (target_center_y > 11'd4) ? (target_center_y - 11'd4) : 11'd0;
assign cross_bottom = target_center_y + 11'd4;

assign on_cross = target_valid &&
                  ((((pixel_x >= cross_left) && (pixel_x <= cross_right)) &&
                    (pixel_y == target_center_y)) ||
                   (((pixel_y >= cross_top) && (pixel_y <= cross_bottom)) &&
                    (pixel_x == target_center_x)));

assign overlay_color = (lock_state == 2'd2) ? COLOR_TRACK :
                       (lock_state == 2'd3) ? COLOR_LOST :
                                              COLOR_IDLE;

always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        pixel_wr_en   <= 1'b0;
        pixel_wr_data <= 16'd0;
    end
    else begin
        pixel_wr_en <= pixel_vld;

        // 这里只覆盖锁定框与目标十字，避免把整帧原图破坏掉。
        if(algo_enable && pixel_vld && (on_box_border || on_cross))
            pixel_wr_data <= overlay_color;
        else
            pixel_wr_data <= pixel_data;
    end
end

endmodule
