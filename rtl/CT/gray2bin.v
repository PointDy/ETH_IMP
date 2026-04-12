`timescale 1ns/1ns

//------------------------------------------------------------------------------
// 模块名称 : gray2bin
// 模块功能 : 对灰度图做固定阈值二值化。
// 设计说明 :
// 1. 灰度值大于阈值输出 1，否则输出 0。
// 2. 该模块主要用于把灰度图转换成适合 Sobel 边缘检测的二值输入。
//------------------------------------------------------------------------------
module gray2bin
#(
    parameter [7:0] THRESHOLD = 8'd100
)
(
    input           clk,
    input           rst_n,
    input           din_sop,
    input           din_eop,
    input           din_vld,
    input   [7:0]   din,
    output          dout_sop,
    output          dout_eop,
    output          dout_vld,
    output          dout
);

reg binary;
reg binary_sop;
reg binary_eop;
reg binary_vld;

// 二值化本身是 1 拍寄存输出，控制信号与数据同步传递。
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        binary     <= 1'b0;
        binary_sop <= 1'b0;
        binary_eop <= 1'b0;
        binary_vld <= 1'b0;
    end
    else begin
        binary     <= (din > THRESHOLD);
        binary_sop <= din_sop;
        binary_eop <= din_eop;
        binary_vld <= din_vld;
    end
end

assign dout     = binary;
assign dout_sop = binary_sop;
assign dout_eop = binary_eop;
assign dout_vld = binary_vld;

endmodule
