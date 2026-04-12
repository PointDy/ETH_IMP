`timescale 1ns/1ns

//------------------------------------------------------------------------------
// 模块名称 : ct_track_core
// 模块功能 : 根据检测统计量实现“待锁定 -> 锁定 -> 跟踪 -> 丢锁”的状态机。
// 设计说明 :
// 1. 未锁定时，波门固定在屏幕中心。
// 2. 按键触发后在中心波门内尝试首次锁定。
// 3. 锁定成功后，用上一帧质心作为下一帧跟踪波门中心。
// 4. 若连续若干帧目标特征过弱，则认为丢锁并回到初始状态。
//------------------------------------------------------------------------------
module ct_track_core
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
    input   wire            clk,
    input   wire            rst_n,
    input   wire            lock_key,
    input   wire            frame_stat_valid,
    input   wire    [31:0]  frame_sum_x,
    input   wire    [31:0]  frame_sum_y,
    input   wire    [19:0]  frame_pixel_cnt,

    output  reg     [1:0]   lock_state,
    output  reg             target_valid,
    output  reg     [10:0]  target_center_x,
    output  reg     [10:0]  target_center_y,
    output  reg     [10:0]  gate_left,
    output  reg     [10:0]  gate_right,
    output  reg     [10:0]  gate_top,
    output  reg     [10:0]  gate_bottom
);

localparam [1:0] ST_IDLE  = 2'd0;
localparam [1:0] ST_ARM   = 2'd1;
localparam [1:0] ST_TRACK = 2'd2;
localparam [1:0] ST_LOST  = 2'd3;

localparam [10:0] CENTER_X = FRAME_WIDTH  >> 1;
localparam [10:0] CENTER_Y = FRAME_HEIGHT >> 1;
localparam [10:0] HALF_CENTER_W = CENTER_GATE_WIDTH  >> 1;
localparam [10:0] HALF_CENTER_H = CENTER_GATE_HEIGHT >> 1;
localparam [10:0] HALF_TRACK_W  = TRACK_GATE_WIDTH   >> 1;
localparam [10:0] HALF_TRACK_H  = TRACK_GATE_HEIGHT  >> 1;

reg [2:0] lock_key_sync;
reg [3:0] lost_cnt;
reg       lock_req_latched;
wire lock_key_pulse;
wire lock_candidate_valid;
wire track_candidate_valid;
wire [10:0] calc_center_x;
wire [10:0] calc_center_y;

// 带边界保护的减法，防止窗口坐标下溢。
function [10:0] clamp_sub;
    input [10:0] value;
    input [10:0] delta;
    begin
        if(value > delta)
            clamp_sub = value - delta;
        else
            clamp_sub = 11'd0;
    end
endfunction

// 带边界保护的加法，防止窗口坐标越过图像边界。
function [10:0] clamp_add_limit;
    input [10:0] value;
    input [10:0] delta;
    input [10:0] limit_max;
    reg   [11:0] tmp;
    begin
        tmp = value + delta;
        if(tmp > limit_max)
            clamp_add_limit = limit_max;
        else
            clamp_add_limit = tmp[10:0];
    end
endfunction

assign lock_key_pulse        = lock_key_sync[1] & ~lock_key_sync[2];
assign lock_candidate_valid  = (frame_pixel_cnt >= LOCK_PIXEL_THRESHOLD);
assign track_candidate_valid = (frame_pixel_cnt >= UNLOCK_THRESHOLD);
// 直接用整帧统计量求几何质心，除法只在帧统计结果有效时被消费。
assign calc_center_x         = (frame_pixel_cnt != 20'd0) ? (frame_sum_x / frame_pixel_cnt) : CENTER_X;
assign calc_center_y         = (frame_pixel_cnt != 20'd0) ? (frame_sum_y / frame_pixel_cnt) : CENTER_Y;

// 对锁定按键做简单同步，导出单拍脉冲。
always @(posedge clk or negedge rst_n) begin
    if(!rst_n)
        lock_key_sync <= 3'b000;
    else
        lock_key_sync <= {lock_key_sync[1:0], lock_key};
end

// 按键是人手输入，持续时间远大于 1 个像素时钟。
// 这里把单拍脉冲锁存成请求标志，直到帧状态机在 frame_stat_valid 时消耗它，
// 避免“按键脉冲到了，但刚好不在帧尾统计那一拍”而被漏检。
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        lock_req_latched <= 1'b0;
    end
    else begin
        if(lock_key_pulse)
            lock_req_latched <= 1'b1;
        else if(frame_stat_valid &&
                ((lock_state == ST_IDLE) || (lock_state == ST_TRACK)) &&
                lock_req_latched)
            lock_req_latched <= 1'b0;
    end
end

// 主状态机：在每帧统计结果有效时更新目标中心与波门位置。
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        lock_state       <= ST_IDLE;
        target_valid     <= 1'b0;
        target_center_x  <= CENTER_X;
        target_center_y  <= CENTER_Y;
        gate_left        <= CENTER_X - HALF_CENTER_W;
        gate_right       <= CENTER_X + HALF_CENTER_W;
        gate_top         <= CENTER_Y - HALF_CENTER_H;
        gate_bottom      <= CENTER_Y + HALF_CENTER_H;
        lost_cnt         <= 4'd0;
    end
    else begin
        if(frame_stat_valid) begin
            case(lock_state)
                ST_IDLE: begin
                    // 空闲态：中心波门固定在屏幕中央，等待按键触发。
                    target_valid    <= 1'b0;
                    lost_cnt        <= 4'd0;
                    target_center_x <= CENTER_X;
                    target_center_y <= CENTER_Y;
                    gate_left       <= clamp_sub(CENTER_X, HALF_CENTER_W);
                    gate_right      <= clamp_add_limit(CENTER_X, HALF_CENTER_W, FRAME_WIDTH - 11'd1);
                    gate_top        <= clamp_sub(CENTER_Y, HALF_CENTER_H);
                    gate_bottom     <= clamp_add_limit(CENTER_Y, HALF_CENTER_H, FRAME_HEIGHT - 11'd1);
                    if(lock_req_latched)
                        lock_state <= ST_ARM;
                end

                ST_ARM: begin
                    // 准备锁定态：只在中心波门内统计目标。
                    gate_left   <= clamp_sub(CENTER_X, HALF_CENTER_W);
                    gate_right  <= clamp_add_limit(CENTER_X, HALF_CENTER_W, FRAME_WIDTH - 11'd1);
                    gate_top    <= clamp_sub(CENTER_Y, HALF_CENTER_H);
                    gate_bottom <= clamp_add_limit(CENTER_Y, HALF_CENTER_H, FRAME_HEIGHT - 11'd1);
                    if(lock_candidate_valid && (frame_pixel_cnt != 20'd0)) begin
                        target_valid    <= 1'b1;
                        target_center_x <= calc_center_x;
                        target_center_y <= calc_center_y;
                        lock_state      <= ST_TRACK;
                        lost_cnt        <= 4'd0;
                    end
                end

                ST_TRACK: begin
                    // 跟踪态：使用上一帧质心更新波门中心。
                    if(lock_req_latched) begin
                        lock_state   <= ST_IDLE;
                        target_valid <= 1'b0;
                        lost_cnt     <= 4'd0;
                    end
                    else if(track_candidate_valid && (frame_pixel_cnt != 20'd0)) begin
                        target_valid    <= 1'b1;
                        target_center_x <= calc_center_x;
                        target_center_y <= calc_center_y;
                        gate_left       <= clamp_sub(calc_center_x, HALF_TRACK_W);
                        gate_right      <= clamp_add_limit(calc_center_x, HALF_TRACK_W, FRAME_WIDTH - 11'd1);
                        gate_top        <= clamp_sub(calc_center_y, HALF_TRACK_H);
                        gate_bottom     <= clamp_add_limit(calc_center_y, HALF_TRACK_H, FRAME_HEIGHT - 11'd1);
                        lost_cnt        <= 4'd0;
                    end
                    else begin
                        if(lost_cnt >= (LOST_FRAME_THRESHOLD - 4'd1)) begin
                            lock_state   <= ST_LOST;
                            target_valid <= 1'b0;
                            lost_cnt     <= 4'd0;
                        end
                        else begin
                            lost_cnt <= lost_cnt + 4'd1;
                        end
                    end
                end

                ST_LOST: begin
                    // 丢锁态只保留 1 帧提示，下一帧自动回到空闲。
                    target_valid <= 1'b0;
                    lock_state   <= ST_IDLE;
                end

                default: begin
                    lock_state <= ST_IDLE;
                end
            endcase
        end
        else if(lock_state == ST_TRACK) begin
            // 帧与帧之间保持当前跟踪波门，避免无统计周期时窗口乱跳。
            gate_left   <= clamp_sub(target_center_x, HALF_TRACK_W);
            gate_right  <= clamp_add_limit(target_center_x, HALF_TRACK_W, FRAME_WIDTH - 11'd1);
            gate_top    <= clamp_sub(target_center_y, HALF_TRACK_H);
            gate_bottom <= clamp_add_limit(target_center_y, HALF_TRACK_H, FRAME_HEIGHT - 11'd1);
        end
    end
end

endmodule
