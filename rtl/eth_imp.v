`timescale 1ns/1ns

module eth_imp
(
    input   wire            sys_clk        ,
    input   wire            sys_rst_n      ,
    input   wire            lock_key       ,
    input   wire            ov5640_pclk    ,
    input   wire            ov5640_vsync   ,
    input   wire            ov5640_href    ,
    input   wire    [7:0]   ov5640_data    ,
    output  wire            ov5640_rst_n   ,
    output  wire            ov5640_pwdn    ,
    output  wire            sccb_scl       ,
    inout   wire            sccb_sda       ,
    output  wire            sdram_clk      ,
    output  wire            sdram_cke      ,
    output  wire            sdram_cs_n     ,
    output  wire            sdram_ras_n    ,
    output  wire            sdram_cas_n    ,
    output  wire            sdram_we_n     ,
    output  wire    [1:0]   sdram_ba       ,
    output  wire    [1:0]   sdram_dqm      ,
    output  wire    [12:0]  sdram_addr     ,
    inout   wire    [15:0]  sdram_dq       ,
    input   wire            eth_clk        ,
    input   wire            eth_rxdv_r     ,
    input   wire    [1:0]   eth_rx_data_r  ,
    output  wire            eth_tx_en_r    ,
    output  wire    [1:0]   eth_tx_data_r  ,
    output  wire            eth_rst_n
);

localparam [23:0] SDRAM_FRAME_WORDS = 24'd307200;
localparam [23:0] SDRAM_WR_B_ADDR   = 24'd0;
localparam [23:0] SDRAM_WR_E_ADDR   = SDRAM_WR_B_ADDR + SDRAM_FRAME_WORDS;
localparam [23:0] SDRAM_RD_B_ADDR   = 24'd0;
localparam [23:0] SDRAM_RD_E_ADDR   = SDRAM_RD_B_ADDR + SDRAM_FRAME_WORDS;
localparam [9:0]  SDRAM_BURST_LEN   = 10'd512;

wire            pll_clk_100;
wire            pll_clk_100_shift;
wire            pll_clk_25;
wire            pll_locked;
wire            core_rst_n;
wire            sys_init_done;

wire            cam_cfg_done;
wire            cam_wr_en;
wire    [15:0]  cam_data;
wire            ct_wr_en;
wire    [15:0]  ct_data;
wire            ct_target_valid;
wire    [10:0]  ct_target_center_x;
wire    [10:0]  ct_target_center_y;
wire    [1:0]   ct_lock_state;

wire            sdram_init_done;
wire            rd_fifo_rd_req;
wire    [15:0]  rd_fifo_rd_data;
wire    [9:0]   rd_fifo_num;
wire            read_valid;

wire            send_en;
wire    [31:0]  send_data;
wire    [15:0]  send_data_num;
wire            fmt_send_en;
wire    [31:0]  fmt_send_data;
wire    [15:0]  fmt_send_data_num;
wire            fmt_done;
wire            img_send_en;
wire    [31:0]  img_send_data;
wire    [15:0]  img_send_data_num;
wire            send_end;
wire            read_data_req;
wire            packet_busy;
wire            packet_done;

reg             frame_send_start;
reg             mii_clk;

assign core_rst_n    = sys_rst_n & pll_locked;
assign sys_init_done = core_rst_n & sdram_init_done;
assign ov5640_rst_n  = sys_init_done;
assign ov5640_pwdn   = 1'b0;
assign send_en       = (fmt_done == 1'b1) ? img_send_en : fmt_send_en;
assign send_data     = (fmt_done == 1'b1) ? img_send_data : fmt_send_data;
assign send_data_num = (fmt_done == 1'b1) ? img_send_data_num : fmt_send_data_num;

always @(negedge eth_clk or negedge sys_rst_n)
begin
    if(sys_rst_n == 1'b0)
        mii_clk <= 1'b0;
    else
        mii_clk <= ~mii_clk;
end

always @(posedge mii_clk or negedge sys_rst_n)
begin
    if(sys_rst_n == 1'b0)
        frame_send_start <= 1'b0;
    else if(sys_init_done && cam_cfg_done && fmt_done
        && (packet_busy == 1'b0))
        frame_send_start <= 1'b1;
    else
        frame_send_start <= 1'b0;
end

clk_gen clk_gen_inst
(
    .areset (~sys_rst_n       ),
    .inclk0 (sys_clk          ),
    .c0     (pll_clk_100      ),
    .c1     (pll_clk_100_shift),
    .c2     (pll_clk_25       ),
    .locked (pll_locked       )
);

ov5640_top ov5640_top_inst
(
    .sys_clk         (pll_clk_25   ),
    .sys_rst_n       (core_rst_n   ),
    .sys_init_done   (sys_init_done),
    .ov5640_pclk     (ov5640_pclk  ),
    .ov5640_href     (ov5640_href  ),
    .ov5640_vsync    (ov5640_vsync ),
    .ov5640_data     (ov5640_data  ),
    .cfg_done        (cam_cfg_done ),
    .sccb_scl        (sccb_scl     ),
    .sccb_sda        (sccb_sda     ),
    .ov5640_wr_en    (cam_wr_en    ),
    .ov5640_data_out (cam_data     )
);

ct_top ct_top_inst
(
    .sys_rst_n       (core_rst_n                 ),
    .capture_enable  (sys_init_done & cam_cfg_done),
    .algo_enable     (1'b1                       ),
    .ov5640_pclk     (ov5640_pclk                ),
    .ov5640_vsync    (ov5640_vsync               ),
    .ov5640_href     (ov5640_href                ),
    .ov5640_data     (ov5640_data                ),
    .lock_key        (lock_key                   ),
    .pixel_wr_en     (ct_wr_en                   ),
    .pixel_data      (ct_data                    ),
    .target_valid    (ct_target_valid            ),
    .target_center_x (ct_target_center_x         ),
    .target_center_y (ct_target_center_y         ),
    .lock_state      (ct_lock_state              )
);

sdram_top sdram_top_inst
(
    .sys_clk         (pll_clk_100      ),
    .clk_out         (pll_clk_100_shift),
    .sys_rst_n       (core_rst_n       ),
    .wr_fifo_wr_clk  (ov5640_pclk      ),
    .wr_fifo_wr_req  (ct_wr_en         ),
    .wr_fifo_wr_data (ct_data          ),
    .sdram_wr_b_addr (SDRAM_WR_B_ADDR  ),
    .sdram_wr_e_addr (SDRAM_WR_E_ADDR  ),
    .wr_burst_len    (SDRAM_BURST_LEN  ),
    .wr_rst          (~core_rst_n      ),
    .rd_fifo_rd_clk  (mii_clk          ),
    .rd_fifo_rd_req  (rd_fifo_rd_req   ),
    .sdram_rd_b_addr (SDRAM_RD_B_ADDR  ),
    .sdram_rd_e_addr (SDRAM_RD_E_ADDR  ),
    .rd_burst_len    (SDRAM_BURST_LEN  ),
    .rd_rst          (~core_rst_n      ),
    .rd_fifo_rd_data (rd_fifo_rd_data  ),
    .rd_fifo_num     (rd_fifo_num      ),
    .read_valid      (read_valid       ),
    .pingpang_en     (1'b1             ),
    .init_end        (sdram_init_done  ),
    .sdram_clk       (sdram_clk        ),
    .sdram_cke       (sdram_cke        ),
    .sdram_cs_n      (sdram_cs_n       ),
    .sdram_ras_n     (sdram_ras_n      ),
    .sdram_cas_n     (sdram_cas_n      ),
    .sdram_we_n      (sdram_we_n       ),
    .sdram_ba        (sdram_ba         ),
    .sdram_addr      (sdram_addr       ),
    .sdram_dqm       (sdram_dqm        ),
    .sdram_dq        (sdram_dq         )
);

packet_format packet_format_inst
(
    .eth_mii_clk   (mii_clk           ),
    .sys_rst_n     (core_rst_n & sys_init_done & cam_cfg_done),
    .read_data_req (read_data_req & (~fmt_done)),
    .send_end      (send_end          ),
    .send_en       (fmt_send_en       ),
    .send_data     (fmt_send_data     ),
    .send_data_num (fmt_send_data_num ),
    .format_done   (fmt_done          )
);

packet packet_inst
(
    .eth_mii_clk      (mii_clk         ),
    .sys_rst_n        (core_rst_n      ),
    .frame_send_start (frame_send_start),
    .rd_fifo_rd_data  (rd_fifo_rd_data ),
    .rd_fifo_num      (rd_fifo_num     ),
    .read_data_req    (read_data_req   ),
    .send_end         (send_end        ),
    .rd_fifo_rd_req   (rd_fifo_rd_req  ),
    .read_valid       (read_valid      ),
    .send_en          (img_send_en     ),
    .send_data        (img_send_data   ),
    .send_data_num    (img_send_data_num),
    .frame_send_busy  (packet_busy     ),
    .frame_send_done  (packet_done     )
);

eth_udp_rmii eth_udp_rmii_inst
(
    .eth_rmii_clk  (eth_clk       ),
    .eth_mii_clk   (mii_clk       ),
    .sys_rst_n     (core_rst_n    ),
    .rx_dv         (eth_rxdv_r    ),
    .rx_data       (eth_rx_data_r ),
    .send_en       (send_en       ),
    .send_data     (send_data     ),
    .send_data_num (send_data_num ),
    .send_end      (send_end      ),
    .read_data_req (read_data_req ),
    .rec_end       (              ),
    .rec_en        (              ),
    .rec_data      (              ),
    .rec_data_num  (              ),
    .eth_tx_dv     (eth_tx_en_r   ),
    .eth_tx_data   (eth_tx_data_r ),
    .eth_rst_n     (eth_rst_n     )
);

endmodule
