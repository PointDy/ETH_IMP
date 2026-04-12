`timescale 1ns/1ns

//------------------------------------------------------------------------------
// 模块名称 : gauss_filter
// 模块功能 : 对灰度图做 3x3 高斯平滑滤波。
// 设计说明 :
// 1. 使用 1 2 1 / 2 4 2 / 1 2 1 的核做近似高斯平滑。
// 2. 行缓冲提供 3 行窗口，寄存器链形成 3x3 邻域。
// 3. 该模块在本工程中预留为可选项，默认可旁路不用。
//------------------------------------------------------------------------------
module gauss_filter(
    input           clk,
    input           rst_n,
    input           din_sop,
    input           din_eop,
    input           din_vld,
    input   [7:0]   din,
    output          dout_sop,
    output          dout_eop,
    output          dout_vld,
    output  [7:0]   dout
);

wire    [7:0]   taps0;
wire    [7:0]   taps1;
wire    [7:0]   taps2;

reg     [7:0]   line0_0;
reg     [7:0]   line0_1;
reg     [7:0]   line0_2;
reg     [7:0]   line1_0;
reg     [7:0]   line1_1;
reg     [7:0]   line1_2;
reg     [7:0]   line2_0;
reg     [7:0]   line2_1;
reg     [7:0]   line2_2;
reg     [9:0]   sum_0;
reg     [9:0]   sum_1;
reg     [9:0]   sum_2;
reg     [11:0]  sum;
reg     [2:0]   sop;
reg     [2:0]   eop;
reg     [2:0]   vld;

// 第一拍：由行缓冲和移位寄存器构成 3x3 像素窗口。
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        line0_0 <= 8'd0; line0_1 <= 8'd0; line0_2 <= 8'd0;
        line1_0 <= 8'd0; line1_1 <= 8'd0; line1_2 <= 8'd0;
        line2_0 <= 8'd0; line2_1 <= 8'd0; line2_2 <= 8'd0;
    end
    else if(vld[0]) begin
        line0_0 <= taps0;  line0_1 <= line0_0; line0_2 <= line0_1;
        line1_0 <= taps1;  line1_1 <= line1_0; line1_2 <= line1_1;
        line2_0 <= taps2;  line2_1 <= line2_0; line2_2 <= line2_1;
    end
end

// 第二拍：分别计算三行的加权和。
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        sum_0 <= 10'd0;
        sum_1 <= 10'd0;
        sum_2 <= 10'd0;
    end
    else if(vld[1]) begin
        sum_0 <= {2'd0, line0_0} + {1'd0, line0_1, 1'd0} + {2'd0, line0_2};
        sum_1 <= {1'd0, line1_0, 1'd0} + {line1_1, 2'd0} + {1'd0, line1_2, 1'd0};
        sum_2 <= {2'd0, line2_0} + {1'd0, line2_1, 1'd0} + {2'd0, line2_2};
    end
end

// 第三拍：三行求总和，得到滤波结果。
always @(posedge clk or negedge rst_n) begin
    if(!rst_n)
        sum <= 12'd0;
    else if(vld[2])
        sum <= sum_0 + sum_1 + sum_2;
end

// 打拍控制信号，与滤波结果对齐。
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        sop <= 3'b000;
        eop <= 3'b000;
        vld <= 3'b000;
    end
    else begin
        sop <= {sop[1:0], din_sop};
        eop <= {eop[1:0], din_eop};
        vld <= {vld[1:0], din_vld};
    end
end

assign dout     = sum[11:4];
assign dout_sop = sop[2];
assign dout_eop = eop[2];
assign dout_vld = vld[2];

// 3 行缓存，输出当前像素正上方两行对应位置的数据。
gs_line_buf gs_line_buf_inst (
    .aclr(~rst_n),
    .clken(din_vld),
    .clock(clk),
    .shiftin(din),
    .shiftout(),
    .taps0x(taps0),
    .taps1x(taps1),
    .taps2x(taps2)
);

endmodule
