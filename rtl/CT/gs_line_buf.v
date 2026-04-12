// megafunction wizard: %Shift register (RAM-based)%
// GENERATION: STANDARD
// VERSION: WM1.0
// MODULE: ALTSHIFT_TAPS
//
// 用途说明：
// 这是高斯滤波模块使用的 3 行行缓冲 IP 包装。
// tap_distance 设置为 640，对应当前工程 640 像素一行。

`timescale 1 ps / 1 ps
module gs_line_buf (
    aclr,
    clken,
    clock,
    shiftin,
    shiftout,
    taps0x,
    taps1x,
    taps2x);

    input       aclr;
    input       clken;
    input       clock;
    input [7:0] shiftin;
    output [7:0] shiftout;
    output [7:0] taps0x;
    output [7:0] taps1x;
    output [7:0] taps2x;

    tri1 aclr;
    tri1 clken;

    wire [7:0] sub_wire0;
    wire [23:0] sub_wire1;

    assign shiftout = sub_wire0;
    assign taps0x   = sub_wire1[7:0];
    assign taps1x   = sub_wire1[15:8];
    assign taps2x   = sub_wire1[23:16];

    altshift_taps ALTSHIFT_TAPS_component (
        .aclr(aclr),
        .clken(clken),
        .clock(clock),
        .shiftin(shiftin),
        .shiftout(sub_wire0),
        .taps(sub_wire1),
        .sclr()
    );
    defparam
        ALTSHIFT_TAPS_component.intended_device_family = "Cyclone IV E",
        ALTSHIFT_TAPS_component.lpm_hint = "RAM_BLOCK_TYPE=M9K",
        ALTSHIFT_TAPS_component.lpm_type = "altshift_taps",
        ALTSHIFT_TAPS_component.number_of_taps = 3,
        ALTSHIFT_TAPS_component.tap_distance = 640,
        ALTSHIFT_TAPS_component.width = 8;

endmodule
