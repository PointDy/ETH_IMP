`timescale 1ns/1ns

module packet
#(
    parameter [15:0] FRAME_WIDTH  = 16'd640,
    parameter [15:0] FRAME_HEIGHT = 16'd480
)
(
    input   wire            eth_mii_clk      ,
    input   wire            sys_rst_n        ,
    input   wire            frame_send_start ,
    input   wire    [15:0]  rd_fifo_rd_data  ,
    input   wire    [9:0]   rd_fifo_num      ,
    input   wire            read_data_req    ,
    input   wire            send_end         ,

    output  reg             rd_fifo_rd_req   ,
    output  wire            read_valid       ,
    output  reg             send_en          ,
    output  wire    [31:0]  send_data        ,
    output  reg     [15:0]  send_data_num    ,
    output  reg             frame_send_busy  ,
    output  reg             frame_send_done
);

// 采用“整包先写入 FIFO，再启动网口发送”的方式，避免边取边发导致的包头错位、
// packet_id 不变化、重复包等问题。当前按一行图像打一包：
// 8B 自定义头 + 1280B 像素数据 = 1288B。
localparam [3:0] ST_IDLE      = 4'd0;
localparam [3:0] ST_FIFO_CLR  = 4'd1;
localparam [3:0] ST_HEADER0   = 4'd2;
localparam [3:0] ST_HEADER1   = 4'd3;
localparam [3:0] ST_LOAD_PIX  = 4'd4;
localparam [3:0] ST_WAIT_PKT  = 4'd5;
localparam [3:0] ST_SEND_REQ  = 4'd6;
localparam [3:0] ST_SEND_PKT  = 4'd7;
localparam [3:0] ST_NEXT_PKT  = 4'd8;

localparam [15:0] PIXEL_BYTES_PER_PACKET = FRAME_WIDTH << 1;
localparam [15:0] PACKET_COUNT_PER_FRAME = FRAME_HEIGHT;
localparam [8:0]  PAYLOAD_WORDS          = FRAME_WIDTH >> 1;
localparam [8:0]  HEADER_WORDS           = 9'd2;
localparam [8:0]  PACKET_WORDS           = PAYLOAD_WORDS + HEADER_WORDS;

reg     [3:0]   state;
reg     [15:0]  frame_id;
reg     [15:0]  packet_id;
reg     [15:0]  pixel_reads_issued;
reg     [8:0]   packet_words_written;
reg             fifo_rd_pending;
reg             pixel_half_valid;
reg     [15:0]  pixel_half_buf;

reg             packet_fifo_aclr;
reg             packet_fifo_wrreq;
wire            packet_fifo_rdreq;
reg     [31:0]  packet_fifo_data;
wire    [31:0]  packet_fifo_q;
wire    [8:0]   packet_fifo_usedw;
wire            packet_fifo_empty;
wire            packet_fifo_full;

wire    [15:0]  packet_flags;
wire    [31:0]  header_word0;
wire    [31:0]  header_word1;

assign read_valid       = frame_send_busy;
assign packet_flags     = {(packet_id == 16'd0), (packet_id == (PACKET_COUNT_PER_FRAME - 16'd1)), 14'd0};
assign header_word0     = {frame_id, packet_id};
assign header_word1     = {PIXEL_BYTES_PER_PACKET, packet_flags};
assign packet_fifo_rdreq = (state == ST_SEND_PKT) && read_data_req;
assign send_data        = packet_fifo_q;

always @(posedge eth_mii_clk or negedge sys_rst_n)
begin
    if(sys_rst_n == 1'b0)
    begin
        state                <= ST_IDLE;
        frame_id             <= 16'd0;
        packet_id            <= 16'd0;
        pixel_reads_issued   <= 16'd0;
        packet_words_written <= 9'd0;
        fifo_rd_pending      <= 1'b0;
        pixel_half_valid     <= 1'b0;
        pixel_half_buf       <= 16'd0;
        packet_fifo_aclr     <= 1'b1;
        packet_fifo_wrreq    <= 1'b0;
        packet_fifo_data     <= 32'd0;
        rd_fifo_rd_req       <= 1'b0;
        send_en              <= 1'b0;
        send_data_num        <= 16'd0;
        frame_send_busy      <= 1'b0;
        frame_send_done      <= 1'b0;
    end
    else
    begin
        rd_fifo_rd_req    <= 1'b0;
        packet_fifo_aclr  <= 1'b0;
        packet_fifo_wrreq <= 1'b0;
        send_en           <= 1'b0;
        frame_send_done   <= 1'b0;

        // 将 SDRAM 读出的两个 16bit 像素拼成一个 32bit 数据字写入发送 FIFO。
        if((state == ST_LOAD_PIX) && (fifo_rd_pending == 1'b1))
        begin
            fifo_rd_pending <= 1'b0;
            if(pixel_half_valid == 1'b0)
            begin
                pixel_half_buf   <= rd_fifo_rd_data;
                pixel_half_valid <= 1'b1;
            end
            else if(packet_fifo_full == 1'b0)
            begin
                packet_fifo_wrreq    <= 1'b1;
                packet_fifo_data     <= {pixel_half_buf, rd_fifo_rd_data};
                packet_words_written <= packet_words_written + 9'd1;
                pixel_half_valid     <= 1'b0;
            end
        end

        case(state)
            ST_IDLE:
            begin
                frame_send_busy <= 1'b0;
                if(frame_send_start == 1'b1)
                begin
                    frame_send_busy      <= 1'b1;
                    packet_id            <= 16'd0;
                    pixel_reads_issued   <= 16'd0;
                    packet_words_written <= 9'd0;
                    fifo_rd_pending      <= 1'b0;
                    pixel_half_valid     <= 1'b0;
                    pixel_half_buf       <= 16'd0;
                    send_data_num        <= PIXEL_BYTES_PER_PACKET + 16'd8;
                    state                <= ST_FIFO_CLR;
                end
            end

            ST_FIFO_CLR:
            begin
                // 每发一包前清空包 FIFO，确保不会残留上一包内容。
                packet_fifo_aclr     <= 1'b1;
                pixel_reads_issued   <= 16'd0;
                packet_words_written <= 9'd0;
                fifo_rd_pending      <= 1'b0;
                pixel_half_valid     <= 1'b0;
                pixel_half_buf       <= 16'd0;
                state                <= ST_HEADER0;
            end

            ST_HEADER0:
            begin
                // 第 1 个 32bit 头：{frame_id, packet_id}
                if(packet_fifo_full == 1'b0)
                begin
                    packet_fifo_wrreq    <= 1'b1;
                    packet_fifo_data     <= header_word0;
                    packet_words_written <= 9'd1;
                    state                <= ST_HEADER1;
                end
            end

            ST_HEADER1:
            begin
                // 第 2 个 32bit 头：{valid_pixel_bytes, flags}
                if(packet_fifo_full == 1'b0)
                begin
                    packet_fifo_wrreq    <= 1'b1;
                    packet_fifo_data     <= header_word1;
                    packet_words_written <= 9'd2;
                    state                <= ST_LOAD_PIX;
                end
            end

            ST_LOAD_PIX:
            begin
                // 一行共 640 个像素，按两个像素拼 1 个 32bit，共 320 个 payload 字。
                if((pixel_reads_issued < FRAME_WIDTH)
                    && (fifo_rd_pending == 1'b0)
                    && (rd_fifo_num != 10'd0))
                begin
                    rd_fifo_rd_req     <= 1'b1;
                    fifo_rd_pending    <= 1'b1;
                    pixel_reads_issued <= pixel_reads_issued + 16'd1;
                end

                if((pixel_reads_issued == FRAME_WIDTH)
                    && (fifo_rd_pending == 1'b0)
                    && (pixel_half_valid == 1'b0)
                    && (packet_words_written == PACKET_WORDS))
                begin
                    state <= ST_WAIT_PKT;
                end
            end

            ST_WAIT_PKT:
            begin
                // 整包都已进入 FIFO 后再启动发送，避免边发边装造成 header 错位。
                if(packet_fifo_usedw == PACKET_WORDS)
                    state <= ST_SEND_REQ;
            end

            ST_SEND_REQ:
            begin
                send_en <= 1'b1;
                state   <= ST_SEND_PKT;
            end

            ST_SEND_PKT:
            begin
                // 发送期间由 eth_udp_rmii 的 read_data_req 直接从包 FIFO 取数。
                if(send_end == 1'b1)
                    state <= ST_NEXT_PKT;
            end

            ST_NEXT_PKT:
            begin
                if(packet_id == (PACKET_COUNT_PER_FRAME - 16'd1))
                begin
                    frame_send_busy <= 1'b0;
                    frame_send_done <= 1'b1;
                    frame_id        <= frame_id + 16'd1;
                    state           <= ST_IDLE;
                end
                else
                begin
                    packet_id <= packet_id + 16'd1;
                    state     <= ST_FIFO_CLR;
                end
            end

            default:
                state <= ST_IDLE;
        endcase
    end
end

packet_fifo packet_fifo_inst
(
    .aclr  ((~sys_rst_n) | packet_fifo_aclr),
    .clock (eth_mii_clk),
    .data  (packet_fifo_data),
    .rdreq (packet_fifo_rdreq),
    .wrreq (packet_fifo_wrreq),
    .empty (packet_fifo_empty),
    .full  (packet_fifo_full),
    .q     (packet_fifo_q),
    .usedw (packet_fifo_usedw)
);

endmodule
