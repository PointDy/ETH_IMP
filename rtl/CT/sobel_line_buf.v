// megafunction wizard: %Shift register (RAM-based)%
// GENERATION: STANDARD
// VERSION: WM1.0
// MODULE: ALTSHIFT_TAPS
//
// 用途说明：
// 这是 Sobel 模块使用的 1bit 行缓冲 IP 包装。
// tap_distance 设置为 640，对应当前工程 640 像素一行。

`timescale 1 ps / 1 ps
module sobel_line_buf (
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
    input [0:0] shiftin;
    output [0:0] shiftout;
    output [0:0] taps0x;
    output [0:0] taps1x;
    output [0:0] taps2x;

    tri1 aclr;
    tri1 clken;

    wire [0:0] sub_wire0;
    wire [2:0] sub_wire1;

    assign shiftout = sub_wire0;
    assign taps0x   = sub_wire1[0:0];
    assign taps1x   = sub_wire1[1:1];
    assign taps2x   = sub_wire1[2:2];

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
        ALTSHIFT_TAPS_component.width = 1;

endmodule
