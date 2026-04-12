`timescale 1ns/1ns

//------------------------------------------------------------------------------
// 模块名称 : sobel
// 模块功能 : 对二值图做 3x3 Sobel 边缘检测，输出 1bit 边缘结果。
// 设计说明 :
// 1. 这里输入已经是二值图，因此硬件资源很省。
// 2. 使用 |Gx| + |Gy| 近似梯度强度，再用固定阈值判断是否为边缘点。
// 3. 控制信号与结果同步延迟 4 拍输出。
//------------------------------------------------------------------------------
module sobel(
    input           clk,
    input           rst_n,
    input           din,
    input           din_sop,
    input           din_eop,
    input           din_vld,
    output          dout,
    output          dout_sop,
    output          dout_eop,
    output          dout_vld
);

wire            taps0;
wire            taps1;
wire            taps2;
reg             line0_0;
reg             line0_1;
reg             line0_2;
reg             line1_0;
reg             line1_1;
reg             line1_2;
reg             line2_0;
reg             line2_1;
reg             line2_2;
reg     [3:0]   sop;
reg     [3:0]   eop;
reg     [3:0]   vld;
reg     [2:0]   x0_sum;
reg     [2:0]   x2_sum;
reg     [2:0]   y0_sum;
reg     [2:0]   y2_sum;
reg     [3:0]   x_abs;
reg     [3:0]   y_abs;
reg     [3:0]   g;

// 3 行缓存，形成当前像素所在的 3x3 窗口。
sobel_line_buf sobel_line_buf_inst (
    .aclr(~rst_n),
    .clken(din_vld),
    .clock(clk),
    .shiftin(din),
    .shiftout(),
    .taps0x(taps0),
    .taps1x(taps1),
    .taps2x(taps2)
);

// 第一拍：拼出 3x3 邻域的 9 个点。
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        line0_0 <= 1'b0; line0_1 <= 1'b0; line0_2 <= 1'b0;
        line1_0 <= 1'b0; line1_1 <= 1'b0; line1_2 <= 1'b0;
        line2_0 <= 1'b0; line2_1 <= 1'b0; line2_2 <= 1'b0;
    end
    else if(vld[0]) begin
        line0_0 <= taps0;  line0_1 <= line0_0; line0_2 <= line0_1;
        line1_0 <= taps1;  line1_1 <= line1_0; line1_2 <= line1_1;
        line2_0 <= taps2;  line2_1 <= line2_0; line2_2 <= line2_1;
    end
end

// 第二拍：分别计算左右列、上下行的加权和。
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        x0_sum <= 3'd0;
        x2_sum <= 3'd0;
        y0_sum <= 3'd0;
        y2_sum <= 3'd0;
    end
    else if(vld[1]) begin
        x0_sum <= {2'd0, line0_0} + {1'd0, line0_1, 1'd0} + {2'd0, line0_2};
        x2_sum <= {2'd0, line2_0} + {1'd0, line2_1, 1'd0} + {2'd0, line2_2};
        y0_sum <= {2'd0, line0_0} + {1'd0, line1_0, 1'd0} + {2'd0, line2_0};
        y2_sum <= {2'd0, line0_2} + {1'd0, line1_2, 1'd0} + {2'd0, line2_2};
    end
end

// 第三拍：求 Gx/Gy 的绝对值。
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        x_abs <= 4'd0;
        y_abs <= 4'd0;
    end
    else if(vld[2]) begin
        x_abs <= (x0_sum >= x2_sum) ? (x0_sum - x2_sum) : (x2_sum - x0_sum);
        y_abs <= (y0_sum >= y2_sum) ? (y0_sum - y2_sum) : (y2_sum - y0_sum);
    end
end

// 第四拍：合成梯度强度。
always @(posedge clk or negedge rst_n) begin
    if(!rst_n)
        g <= 4'd0;
    else if(vld[3])
        g <= x_abs + y_abs;
end

// 控制信号同步打拍。
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        sop <= 4'b0000;
        eop <= 4'b0000;
        vld <= 4'b0000;
    end
    else begin
        sop <= {sop[2:0], din_sop};
        eop <= {eop[2:0], din_eop};
        vld <= {vld[2:0], din_vld};
    end
end

// 梯度达到阈值则认为当前点是边缘点。
assign dout     = (g >= 4'd3);
assign dout_sop = sop[3];
assign dout_eop = eop[3];
assign dout_vld = vld[3];

endmodule
