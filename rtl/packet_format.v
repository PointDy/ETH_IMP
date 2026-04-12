`timescale 1ns/1ns

module packet_format
#(
    parameter [15:0] FRAME_WIDTH  = 16'd640,
    parameter [15:0] FRAME_HEIGHT = 16'd480,
    parameter [7:0]  FORMAT_CODE  = 8'h04
)
(
    input   wire            eth_mii_clk    ,
    input   wire            sys_rst_n      ,
    input   wire            read_data_req  ,
    input   wire            send_end       ,

    output  reg             send_en        ,
    output  reg     [31:0]  send_data      ,
    output  reg     [15:0]  send_data_num  ,
    output  reg             format_done
);

// 直接参考 image_format 的思路：
// 上电后先发送一次固定格式包，告诉上位机当前视频参数
localparam [2:0] ST_IDLE    = 3'd0;
localparam [2:0] ST_SENDREQ = 3'd1;
localparam [2:0] ST_SEND    = 3'd2;
localparam [2:0] ST_DONE    = 3'd3;

localparam [31:0] WORD0 = 32'h53_5A_48_59;
localparam [31:0] WORD1 = {8'h00, 8'h11, 8'h00, 8'h00};
localparam [31:0] WORD2 = {8'h00, 8'h01, FORMAT_CODE, FRAME_WIDTH[15:8]};
localparam [31:0] WORD3 = {FRAME_WIDTH[7:0], FRAME_HEIGHT, 8'h7C};
localparam [31:0] WORD4 = {8'h0B, 24'h000000};

reg [2:0] state;
reg [2:0] word_idx;

always @(posedge eth_mii_clk or negedge sys_rst_n)
begin
    if(sys_rst_n == 1'b0)
    begin
        state         <= ST_IDLE;
        word_idx      <= 3'd0;
        send_en       <= 1'b0;
        send_data     <= 32'd0;
        send_data_num <= 16'd17;
        format_done   <= 1'b0;
    end
    else
    begin
        send_en <= 1'b0;

        case(state)
            ST_IDLE:
            begin
                word_idx      <= 3'd0;
                send_data_num <= 16'd17;
                state         <= ST_SENDREQ;
            end

            ST_SENDREQ:
            begin
                send_en <= 1'b1;
                state   <= ST_SEND;
            end

            ST_SEND:
            begin
                if(read_data_req == 1'b1)
                begin
                    case(word_idx)
                        3'd0: send_data <= WORD0;
                        3'd1: send_data <= WORD1;
                        3'd2: send_data <= WORD2;
                        3'd3: send_data <= WORD3;
                        default: send_data <= WORD4;
                    endcase

                    if(word_idx < 3'd4)
                        word_idx <= word_idx + 3'd1;
                end

                if(send_end == 1'b1)
                    state <= ST_DONE;
            end

            ST_DONE:
            begin
                format_done <= 1'b1;
            end

            default:
                state <= ST_IDLE;
        endcase
    end
end

endmodule
