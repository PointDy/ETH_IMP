`timescale 1ns/1ns

//------------------------------------------------------------------------------
// 模块名称 : ct_detect_core
// 模块功能 : 完成检测链路的主数据通路。
// 处理流程 :
//   RGB565 -> 灰度 -> 可选高斯 -> 二值化 -> Sobel
// 同时功能 :
// 1. 把输入像素坐标按流水延迟对齐到 Sobel 输出。
// 2. 只在当前波门内累计边缘像素的 sum_x / sum_y / pixel_cnt。
// 3. 在帧尾输出整帧统计结果，供跟踪模块计算质心。
//------------------------------------------------------------------------------
module ct_detect_core
#(
    parameter [10:0] FRAME_WIDTH   = 11'd640,
    parameter [10:0] FRAME_HEIGHT  = 11'd480,
    parameter        USE_GAUSS     = 1'b0,
    parameter [7:0]  BIN_THRESHOLD = 8'd100
)
(
    input   wire            clk,
    input   wire            rst_n,
    input   wire            pixel_sop,
    input   wire            pixel_eop,
    input   wire            pixel_vld,
    input   wire    [15:0]  pixel_data,
    input   wire    [10:0]  pixel_x,
    input   wire    [10:0]  pixel_y,
    input   wire    [10:0]  gate_left,
    input   wire    [10:0]  gate_right,
    input   wire    [10:0]  gate_top,
    input   wire    [10:0]  gate_bottom,

    output  wire            edge_pixel,
    output  wire            edge_sop,
    output  wire            edge_eop,
    output  wire            edge_vld,
    output  wire    [10:0]  edge_x,
    output  wire    [10:0]  edge_y,
    output  reg     [31:0]  frame_sum_x,
    output  reg     [31:0]  frame_sum_y,
    output  reg     [19:0]  frame_pixel_cnt,
    output  reg             frame_stat_valid
);

localparam integer PIPE_STAGES = (USE_GAUSS != 0) ? 10 : 7;
integer idx;

wire            gray_sop;
wire            gray_eop;
wire            gray_vld;
wire    [7:0]   gray_data;
wire            gs_sop;
wire            gs_eop;
wire            gs_vld;
wire    [7:0]   gs_data;
wire            bin_sop;
wire            bin_eop;
wire            bin_vld;
wire            bin_data;

reg     [10:0]  x_pipe [0:PIPE_STAGES-1];
reg     [10:0]  y_pipe [0:PIPE_STAGES-1];
reg     [31:0]  sum_x_acc;
reg     [31:0]  sum_y_acc;
reg     [19:0]  pixel_cnt_acc;

// Sobel 输出时对应的坐标是否落在当前波门内。
wire in_gate;
wire [31:0] edge_x_32;
wire [31:0] edge_y_32;

assign edge_x    = x_pipe[PIPE_STAGES-1];
assign edge_y    = y_pipe[PIPE_STAGES-1];
assign edge_x_32 = {21'd0, edge_x};
assign edge_y_32 = {21'd0, edge_y};
assign in_gate   = (edge_x >= gate_left) && (edge_x <= gate_right) &&
                   (edge_y >= gate_top)  && (edge_y <= gate_bottom);

// 灰度化。
rgb2gray u_rgb2gray(
    .clk(clk),
    .rst_n(rst_n),
    .din_sop(pixel_sop),
    .din_eop(pixel_eop),
    .din_vld(pixel_vld),
    .din(pixel_data),
    .dout_sop(gray_sop),
    .dout_eop(gray_eop),
    .dout_vld(gray_vld),
    .dout(gray_data)
);

// 高斯滤波可选旁路，后续如果想增强抗噪能力，只需打开 USE_GAUSS。
generate
if(USE_GAUSS) begin : gen_use_gauss
    gauss_filter u_gauss(
        .clk(clk),
        .rst_n(rst_n),
        .din_sop(gray_sop),
        .din_eop(gray_eop),
        .din_vld(gray_vld),
        .din(gray_data),
        .dout_sop(gs_sop),
        .dout_eop(gs_eop),
        .dout_vld(gs_vld),
        .dout(gs_data)
    );
end
else begin : gen_bypass_gauss
    assign gs_sop  = gray_sop;
    assign gs_eop  = gray_eop;
    assign gs_vld  = gray_vld;
    assign gs_data = gray_data;
end
endgenerate

// 固定阈值二值化。
gray2bin #(
    .THRESHOLD(BIN_THRESHOLD)
) u_gray2bin(
    .clk(clk),
    .rst_n(rst_n),
    .din_sop(gs_sop),
    .din_eop(gs_eop),
    .din_vld(gs_vld),
    .din(gs_data),
    .dout_sop(bin_sop),
    .dout_eop(bin_eop),
    .dout_vld(bin_vld),
    .dout(bin_data)
);

// Sobel 边缘提取。
sobel u_sobel(
    .clk(clk),
    .rst_n(rst_n),
    .din(bin_data),
    .din_sop(bin_sop),
    .din_eop(bin_eop),
    .din_vld(bin_vld),
    .dout(edge_pixel),
    .dout_sop(edge_sop),
    .dout_eop(edge_eop),
    .dout_vld(edge_vld)
);

// 像素坐标跟随算法流水延迟打拍，保证与 edge_pixel 同时有效。
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        for(idx = 0; idx < PIPE_STAGES; idx = idx + 1) begin
            x_pipe[idx] <= 11'd0;
            y_pipe[idx] <= 11'd0;
        end
    end
    else begin
        x_pipe[0] <= pixel_x;
        y_pipe[0] <= pixel_y;
        for(idx = 1; idx < PIPE_STAGES; idx = idx + 1) begin
            x_pipe[idx] <= x_pipe[idx-1];
            y_pipe[idx] <= y_pipe[idx-1];
        end
    end
end

// 对当前波门内的边缘像素做逐帧累计。
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        sum_x_acc        <= 32'd0;
        sum_y_acc        <= 32'd0;
        pixel_cnt_acc    <= 20'd0;
        frame_sum_x      <= 32'd0;
        frame_sum_y      <= 32'd0;
        frame_pixel_cnt  <= 20'd0;
        frame_stat_valid <= 1'b0;
    end
    else begin
        frame_stat_valid <= 1'b0;

        if(edge_vld && edge_sop) begin
            sum_x_acc     <= 32'd0;
            sum_y_acc     <= 32'd0;
            pixel_cnt_acc <= 20'd0;
        end
        else if(edge_vld && edge_pixel && in_gate) begin
            sum_x_acc     <= sum_x_acc + edge_x_32;
            sum_y_acc     <= sum_y_acc + edge_y_32;
            pixel_cnt_acc <= pixel_cnt_acc + 20'd1;
        end

        // 帧尾把当前一帧的统计结果锁存，供质心求解使用。
        if(edge_vld && edge_eop) begin
            frame_sum_x      <= (edge_pixel && in_gate) ? (sum_x_acc + edge_x_32) : sum_x_acc;
            frame_sum_y      <= (edge_pixel && in_gate) ? (sum_y_acc + edge_y_32) : sum_y_acc;
            frame_pixel_cnt  <= (edge_pixel && in_gate) ? (pixel_cnt_acc + 20'd1) : pixel_cnt_acc;
            frame_stat_valid <= 1'b1;
        end
    end
end

endmodule
