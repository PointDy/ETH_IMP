`timescale 1ns/1ns

//------------------------------------------------------------------------------
// 模块名称 : rgb2gray
// 模块功能 : 把输入的 RGB565 像素流转换为 8bit 灰度流。
// 设计说明 :
// 1. 先把 RGB565 扩展成近似 RGB888。
// 2. 再按 0.299R + 0.587G + 0.114B 的近似系数做灰度加权。
// 3. sop/eop/vld 与像素数据同步延迟两拍输出。
//------------------------------------------------------------------------------
module rgb2gray(
    input           clk,
    input           rst_n,
    input           din_sop,
    input           din_eop,
    input           din_vld,
    input   [15:0]  din,
    output          dout_sop,
    output          dout_eop,
    output          dout_vld,
    output  [7:0]   dout
);

reg     [7:0]       data_r;
reg     [7:0]       data_g;
reg     [7:0]       data_b;
reg     [17:0]      pixel_r;
reg     [17:0]      pixel_g;
reg     [17:0]      pixel_b;
reg     [19:0]      pixel;
reg     [1:0]       sop;
reg     [1:0]       eop;
reg     [1:0]       vld;

// RGB565 扩展到 8bit 通道，低位用高位补齐，减少色阶断层。
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        data_r <= 8'd0;
        data_g <= 8'd0;
        data_b <= 8'd0;
    end
    else if(din_vld) begin
        data_r <= {din[15:11], din[13:11]};
        data_g <= {din[10:5],  din[6:5]};
        data_b <= {din[4:0],   din[2:0]};
    end
end

// 第一拍：按灰度系数对三通道分别加权。
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        pixel_r <= 18'd0;
        pixel_g <= 18'd0;
        pixel_b <= 18'd0;
    end
    else if(vld[0]) begin
        pixel_r <= data_r * 18'd306;
        pixel_g <= data_g * 18'd601;
        pixel_b <= data_b * 18'd117;
    end
end

// 第二拍：三通道加权和相加，得到灰度值。
always @(posedge clk or negedge rst_n) begin
    if(!rst_n)
        pixel <= 20'd0;
    else if(vld[1])
        pixel <= pixel_r + pixel_g + pixel_b;
end

// 同步打拍控制信号，保证与灰度输出对齐。
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        sop <= 2'b00;
        eop <= 2'b00;
        vld <= 2'b00;
    end
    else begin
        sop <= {sop[0], din_sop};
        eop <= {eop[0], din_eop};
        vld <= {vld[0], din_vld};
    end
end

assign dout     = pixel[17:10];
assign dout_sop = sop[1];
assign dout_eop = eop[1];
assign dout_vld = vld[1];

endmodule
