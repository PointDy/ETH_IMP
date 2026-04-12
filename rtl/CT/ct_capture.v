`timescale 1ns/1ns

//------------------------------------------------------------------------------
// 模块名称 : ct_capture
// 模块功能 : 在 OV5640 的 pclk 时钟域内，把 8bit 并口数据拼成 RGB565，
//            同时输出逐像素有效信号、帧首/帧尾标志以及像素坐标。
// 设计说明 :
// 1. OV5640 每两个 8bit 数据组成一个 16bit RGB565 像素。
// 2. 这里直接在采集入口生成算法所需的流接口，便于后级做灰度化、Sobel、
//    统计质心和叠加显示。
//------------------------------------------------------------------------------
module ct_capture
#(
    parameter [10:0] FRAME_WIDTH  = 11'd640,
    parameter [10:0] FRAME_HEIGHT = 11'd480
)
(
    input   wire            pclk,
    input   wire            rst_n,
    input   wire            enable,
    input   wire            vsync,
    input   wire            href,
    input   wire    [7:0]   din,

    output  reg     [15:0]  pixel_data,
    output  reg             pixel_vld,
    output  reg             pixel_sop,
    output  reg             pixel_eop,
    output  reg     [10:0]  pixel_x,
    output  reg     [10:0]  pixel_y
);

reg     [1:0]   vsync_r;
reg             frame_active;
reg             byte_phase;
reg     [7:0]   byte_buf;
reg     [10:0]  x_cnt;
reg     [10:0]  y_cnt;

// vsync 下降沿作为新一帧开始的参考触发点。
wire vsync_nedge;
// 当前像素是否是整帧最后一个像素。
wire last_pixel;

assign vsync_nedge = vsync_r[1] & ~vsync_r[0];
assign last_pixel  = (x_cnt == (FRAME_WIDTH - 11'd1)) && (y_cnt == (FRAME_HEIGHT - 11'd1));

always @(posedge pclk or negedge rst_n) begin
    if(!rst_n)
        vsync_r <= 2'b00;
    else
        vsync_r <= {vsync_r[0], vsync};
end

always @(posedge pclk or negedge rst_n) begin
    if(!rst_n) begin
        frame_active <= 1'b0;
        byte_phase   <= 1'b0;
        byte_buf     <= 8'd0;
        pixel_data   <= 16'd0;
        pixel_vld    <= 1'b0;
        pixel_sop    <= 1'b0;
        pixel_eop    <= 1'b0;
        pixel_x      <= 11'd0;
        pixel_y      <= 11'd0;
        x_cnt        <= 11'd0;
        y_cnt        <= 11'd0;
    end
    else begin
        pixel_vld <= 1'b0;
        pixel_sop <= 1'b0;
        pixel_eop <= 1'b0;

        // 在摄像头像素时钟域内直接生成 RGB565 及帧坐标。
        if(enable && vsync_nedge) begin
            frame_active <= 1'b1;
            byte_phase   <= 1'b0;
            x_cnt        <= 11'd0;
            y_cnt        <= 11'd0;
        end
        else if(!enable) begin
            frame_active <= 1'b0;
            byte_phase   <= 1'b0;
            x_cnt        <= 11'd0;
            y_cnt        <= 11'd0;
        end
        else if(frame_active && href) begin
            // href 有效期间表示当前正在输出一行有效像素。
            byte_phase <= ~byte_phase;
            byte_buf   <= din;

            if(byte_phase) begin
                // 第二个字节到来时完成一个 RGB565 像素拼接。
                pixel_data <= {din, byte_buf};
                pixel_vld  <= 1'b1;
                pixel_sop  <= (x_cnt == 11'd0) && (y_cnt == 11'd0);
                pixel_eop  <= last_pixel;
                pixel_x    <= x_cnt;
                pixel_y    <= y_cnt;

                if(last_pixel) begin
                    // 到达整帧末尾后停止本帧采集，等待下一次 vsync 重新开始。
                    frame_active <= 1'b0;
                    x_cnt        <= 11'd0;
                    y_cnt        <= 11'd0;
                end
                else if(x_cnt == (FRAME_WIDTH - 11'd1)) begin
                    // 行尾换行。
                    x_cnt <= 11'd0;
                    y_cnt <= y_cnt + 11'd1;
                end
                else begin
                    // 行内像素递增。
                    x_cnt <= x_cnt + 11'd1;
                end
            end
        end
        else if(!href) begin
            // 离开有效行后，重新回到字节对齐起点。
            byte_phase <= 1'b0;
        end
    end
end

endmodule
