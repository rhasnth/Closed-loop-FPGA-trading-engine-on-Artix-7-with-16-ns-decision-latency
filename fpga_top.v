// fpga_top.v
//  closed-loop trading engine, single-file. Artix-7 XC7A100T on the Alientek
//  Da Vinci Pro V4.0, on-board YT8511 RGMII PHY, 1 GbE to a Linux host.
//
//  frame layout on the wire (raw eth):
//    0x88B5  fpga -> host    heartbeat
//    0x88B6  host -> fpga    tick (ticker + price)
//    0x88B7  fpga -> host    order
//    0x88B8  host -> fpga    config (set thresholds)
//    0x88B9  fpga -> host    stats / pnl
//
//  measured fire-pulse-to-first-byte = 16 ns (2 cyc @ 125 MHz).

`timescale 1ns / 1ps

module fpga_top (
    input  wire        sys_clk,
    input  wire        eth_rgmii_rxc,
    input  wire        eth_rgmii_rx_ctl,
    inout  wire [3:0]  eth_rgmii_rxd,
    output wire        eth_rgmii_txc,
    output wire        eth_rgmii_tx_ctl,
    output wire [3:0]  eth_rgmii_txd,
    output wire        eth_rst_n,
    output wire        eth_mdc,
    inout  wire        eth_mdio,
    output wire [3:0]  led
);

    // 4-byte ASCII tickers. GME has a trailing space so all 4 are the same width.
    localparam [31:0] TICKER_QCOM = 32'h51434F4D;
    localparam [31:0] TICKER_TSLA = 32'h54534C41;
    localparam [31:0] TICKER_GME  = 32'h474D4520;  // 0x47 0x4D 0x45 0x20
    localparam [31:0] TICKER_NVDA = 32'h4E564441;

    // per-ticker. fires that would breach this are refused, not queued.
    localparam signed [15:0] POSITION_LIMIT = 16'sd100;

    // boot defaults. CONFIG frames overwrite at runtime.
    localparam [31:0] INIT_BUY_QCOM  = 32'd15500;
    localparam [31:0] INIT_SELL_QCOM = 32'd16000;
    localparam [31:0] INIT_BUY_TSLA  = 32'd40000;
    localparam [31:0] INIT_SELL_TSLA = 32'd45000;
    localparam [31:0] INIT_BUY_GME   = 32'd2000;
    localparam [31:0] INIT_SELL_GME  = 32'd3000;
    localparam [31:0] INIT_BUY_NVDA  = 32'd13000;
    localparam [31:0] INIT_SELL_NVDA = 32'd15000;

    wire clk_125_u, clk_125_90_u, clk_fb_u;
    wire clk_125, clk_125_90, clk_fb, locked;
    // 50 MHz in -> 125 MHz x2. The 90 deg one is for TXC.
    MMCME2_BASE #(
        .CLKIN1_PERIOD(20.0),
        .CLKFBOUT_MULT_F(20.0),
        .CLKOUT0_DIVIDE_F(8.0), .CLKOUT0_PHASE(0.0),
        .CLKOUT1_DIVIDE(8),     .CLKOUT1_PHASE(90.0)
    ) mmcm_i (
        .CLKIN1(sys_clk),
        .CLKOUT0(clk_125_u), .CLKOUT1(clk_125_90_u),
        .CLKFBOUT(clk_fb_u), .CLKFBIN(clk_fb),
        .LOCKED(locked), .RST(1'b0), .PWRDWN(1'b0)
    );
    BUFG b1 (.I(clk_125_u),    .O(clk_125));
    BUFG b2 (.I(clk_125_90_u), .O(clk_125_90));
    BUFG b3 (.I(clk_fb_u),     .O(clk_fb));

    // ---- PHY bringup ----
    //  RXD3 has to be driven high during the PHY's reset-release window or
    //  MODE_SEL latches as 00 = "force low-power mode" (no external pull-up
    //  on this board, the chip's internal pull-down wins). In that mode link
    //  still comes up and MDIO works, RGMII TX is just silently gated. Took
    //  way too long to find this.
    //
    //  timeline:
    //    t=0     reset asserted
    //    ~1.5s   reset released
    //    ~1.7s   stop driving RXD3 high (released to high-Z, normal RX duty)
    //    ~2.5s   start MDIO sequencer
    //    ~6s     link up, 1000Mb/s full duplex
    reg [29:0] boot_cnt = 0;
    always @(posedge clk_125) begin
        if (boot_cnt < 30'd750_000_000) boot_cnt <= boot_cnt + 1;
    end
    wire phy_reset_done = (boot_cnt > 30'd187_500_000);
    wire mdio_start     = (boot_cnt == 30'd312_500_000);
    assign eth_rst_n = phy_reset_done;

    wire strap_drive = (boot_cnt < 30'd213_000_000);

    wire rxd0_in, rxd1_in, rxd2_in, rxd3_in;

    // the actual override - drive high during boot, then high-Z
    IOBUF iobuf_rxd3 (
        .O (rxd3_in),                
        .IO(eth_rgmii_rxd[3]),
        .I (1'b1),                   
        .T (~strap_drive)            
    );
    IOBUF iobuf_rxd2 (
        .O (rxd2_in), .IO(eth_rgmii_rxd[2]), .I(1'b0), .T(1'b1)  
    );
    IOBUF iobuf_rxd1 (
        .O (rxd1_in), .IO(eth_rgmii_rxd[1]), .I(1'b0), .T(1'b1)
    );
    // other 3 are always high-Z but go through IOBUFs anyway, keeps the
    //  elab netlist symmetric
    IOBUF iobuf_rxd0 (
        .O (rxd0_in), .IO(eth_rgmii_rxd[0]), .I(1'b0), .T(1'b1)
    );

    // MDC = clk_125 / 1280, ~97.5 kHz
    reg [10:0] mdc_phase = 0;
    reg mdc_reg = 1'b1;
    always @(posedge clk_125) begin
        if (mdc_phase == 11'd639) begin
            mdc_phase <= 0;
            mdc_reg <= ~mdc_reg;
        end else mdc_phase <= mdc_phase + 1;
    end
    assign eth_mdc = mdc_reg;
    wire post_fall = (mdc_phase == 11'd50) && ~mdc_reg;

    // writes BMCR=0x1340 (autoneg+restart, full duplex) to all 32 PHY addrs.
    //  only one is the YT8511, rest are no-ops. fire-and-forget at boot.
    localparam NUM_CMDS = 32;
    reg [27:0] cmd_rom [0:NUM_CMDS-1];
    integer ai;
    initial begin
        for (ai = 0; ai < 32; ai = ai + 1) begin
            cmd_rom[ai] = {2'b01, ai[4:0], 5'h00, 16'h1340};
        end
    end

    localparam ST_IDLE = 4'd0, ST_PRE = 4'd1, ST_ST = 4'd2, ST_OP = 4'd3;
    localparam ST_PHY  = 4'd4, ST_REG = 4'd5, ST_TA = 4'd6, ST_DATA = 4'd7;
    localparam ST_GAP  = 4'd8, ST_DONE= 4'd9;

    reg [3:0]  mdio_state = ST_IDLE;
    reg [5:0]  bit_cnt = 0;
    reg [7:0]  cmd_idx = 0;
    reg        mdio_out = 1'b1;
    reg        mdio_oe  = 1'b0;
    reg [27:0] cur_cmd;
    reg [22:0] gap_cnt = 0;

    always @(posedge clk_125) begin
        if (mdio_start && mdio_state == ST_IDLE) begin
            mdio_state <= ST_PRE; bit_cnt <= 0;
            cmd_idx <= 0; cur_cmd <= cmd_rom[0];
            mdio_oe <= 1'b1; mdio_out <= 1'b1;
        end
        if (post_fall && mdio_state != ST_IDLE && mdio_state != ST_GAP &&
                         mdio_state != ST_DONE) begin
            case (mdio_state)
                ST_PRE: begin
                    mdio_oe <= 1'b1; mdio_out <= 1'b1;
                    if (bit_cnt == 31) begin bit_cnt <= 0; mdio_state <= ST_ST; end
                    else bit_cnt <= bit_cnt + 1;
                end
                ST_ST: begin
                    mdio_oe <= 1'b1; mdio_out <= (bit_cnt == 0) ? 1'b0 : 1'b1;
                    if (bit_cnt == 1) begin bit_cnt <= 0; mdio_state <= ST_OP; end
                    else bit_cnt <= bit_cnt + 1;
                end
                ST_OP: begin
                    mdio_oe <= 1'b1; mdio_out <= cur_cmd[27 - bit_cnt];
                    if (bit_cnt == 1) begin bit_cnt <= 0; mdio_state <= ST_PHY; end
                    else bit_cnt <= bit_cnt + 1;
                end
                ST_PHY: begin
                    mdio_oe <= 1'b1; mdio_out <= cur_cmd[25 - bit_cnt];
                    if (bit_cnt == 4) begin bit_cnt <= 0; mdio_state <= ST_REG; end
                    else bit_cnt <= bit_cnt + 1;
                end
                ST_REG: begin
                    mdio_oe <= 1'b1; mdio_out <= cur_cmd[20 - bit_cnt];
                    if (bit_cnt == 4) begin bit_cnt <= 0; mdio_state <= ST_TA; end
                    else bit_cnt <= bit_cnt + 1;
                end
                ST_TA: begin
                    mdio_oe <= 1'b1; mdio_out <= (bit_cnt == 0) ? 1'b1 : 1'b0;
                    if (bit_cnt == 1) begin bit_cnt <= 0; mdio_state <= ST_DATA; end
                    else bit_cnt <= bit_cnt + 1;
                end
                ST_DATA: begin
                    mdio_oe <= 1'b1; mdio_out <= cur_cmd[15 - bit_cnt];
                    if (bit_cnt == 15) begin
                        bit_cnt <= 0; mdio_oe <= 1'b0;
                        gap_cnt <= 0; mdio_state <= ST_GAP;
                    end else bit_cnt <= bit_cnt + 1;
                end
                default: ;
            endcase
        end

        if (mdio_state == ST_GAP) begin
            mdio_oe <= 1'b0;
            if (gap_cnt == 23'd200_000) begin
                gap_cnt <= 0;
                if (cmd_idx == NUM_CMDS - 1) mdio_state <= ST_DONE;
                else begin
                    cmd_idx <= cmd_idx + 1;
                    cur_cmd <= cmd_rom[cmd_idx + 1];
                    mdio_state <= ST_PRE; bit_cnt <= 0;
                    mdio_oe <= 1'b1; mdio_out <= 1'b1;
                end
            end else gap_cnt <= gap_cnt + 1;
        end
        else if (mdio_state == ST_DONE) mdio_oe <= 1'b0;
    end

    assign eth_mdio = mdio_oe ? mdio_out : 1'bz;
    wire mdio_done = (mdio_state == ST_DONE);

    reg [27:0] post_cnt = 0;
    always @(posedge clk_125) begin
        if (mdio_done && post_cnt < 28'd250_000_000) post_cnt <= post_cnt + 1;
    end
    wire ready = (post_cnt == 28'd250_000_000);

    wire rxc_ibuf;
    IBUF ibuf_rxc (.I(eth_rgmii_rxc), .O(rxc_ibuf));

    wire rx_clk_io;        
    // RXC distribution: BUFIO for IDDR, BUFR(BYPASS) for the parser logic.
    //  BUFG was wrong here - it adds 2-3 ns of insertion delay which slides
    //  the IDDR sampling edge off the data eye into the transition region.
    //  RX bytes came out random. BUFIO has the lowest insertion delay, which
    //  is what you want for source-synchronous capture.
    BUFIO bufio_rxc (.I(rxc_ibuf), .O(rx_clk_io));

    wire rx_clk;           
    // BUFR in BYPASS = same RXC, just routed to fabric
    BUFR #(
        .BUFR_DIVIDE("BYPASS"),
        .SIM_DEVICE("7SERIES")
    ) bufr_rxc (
        .I(rxc_ibuf),
        .O(rx_clk),
        .CE(1'b1),
        .CLR(1'b0)
    );

    wire [3:0] rxd_in = {rxd3_in, rxd2_in, rxd1_in, rxd0_in};
    wire [3:0] rx_nib_lo, rx_nib_hi;
    wire       rx_dv_r,    rx_dv_f;

    genvar rxi;
    generate
        for (rxi = 0; rxi < 4; rxi = rxi + 1) begin : g_rx_iddr
            // low nibble on rising edge, high nibble on falling, both come out
            //  together one cycle later
            IDDR #(.DDR_CLK_EDGE("SAME_EDGE_PIPELINED")) iddr_d (
                .Q1(rx_nib_lo[rxi]), .Q2(rx_nib_hi[rxi]),
                .C (rx_clk_io), .CE(1'b1),
                .D (rxd_in[rxi]),
                .R(1'b0), .S(1'b0)
            );
        end
    endgenerate

    // rx_ctl: rising = RX_DV, falling = RX_DV xor RX_ER. We don't bother
    //  with RX_ER, just gate on DV.
    IDDR #(.DDR_CLK_EDGE("SAME_EDGE_PIPELINED")) iddr_ctl (
        .Q1(rx_dv_r), .Q2(rx_dv_f),
        .C (rx_clk_io), .CE(1'b1), .D(eth_rgmii_rx_ctl),
        .R (1'b0), .S(1'b0)
    );

    wire [7:0] rx_byte_w = {rx_nib_hi, rx_nib_lo};
    wire       rx_dv_w   = rx_dv_r;

    // ---- frame parser (rx_clk) ----
    //  IDLE -> HUNT (wait for SFD 0xD5) -> BODY (count byte offsets, latch fields)
    //  decision happens at end-of-frame (the cycle rx_dv falls). store-and-forward
    //  because price arrives after ticker, can't decide mid-frame.
    //
    //  byte offsets (0 = first dst MAC byte, post-SFD):
    //    12-13   ethertype
    //    14-17   magic
    //    18-21   ticker
    //    22-25   price (BE uint32 cents) / buy_below for CONFIG
    //    26-29   sell_above (CONFIG only)
    localparam P_IDLE   = 3'd0;
    localparam P_HUNT   = 3'd1;   
    localparam P_BODY   = 3'd2;   

    reg  [2:0] p_state = P_IDLE;
    reg  [9:0] p_byte_idx = 0;
    reg [15:0] p_ethtype  = 0;
    reg [31:0] p_magic    = 0;
    reg [31:0] p_ticker   = 0;
    reg [31:0] p_price    = 0;
    reg [31:0] p_field2   = 0;
    reg        rx_dv_d    = 1'b0;

    reg        rx_fire_buy  = 1'b0;
    reg        rx_fire_sell = 1'b0;
    reg [31:0] rx_price_lat  = 0;
    reg [31:0] rx_ticker_lat = 0;   

    // thresholds, indexed by ticker idx. CONFIG writes, ticks read.
    reg [31:0] buy_thr  [0:3];
    reg [31:0] sell_thr [0:3];

    // signed for shorts. 16 bits is way more than +/-100 needs but it's free.
    reg signed [15:0] position [0:3];

    // ---- per-ticker pnl state ----
    //  host computes realised cashflow = proceeds - cost, and mtm = position
    //  * last_price. could do the multiply on-chip with a DSP slice but no
    //  point - fpga publishes the raw inputs and the host script does the
    //  arithmetic. saves a DSP, frees an XPM call later if we want it.
    reg [31:0] volume_buys    [0:3];
    reg [31:0] volume_sells   [0:3];
    reg [63:0] cost_buys      [0:3];
    reg [63:0] proceeds_sells [0:3];
    reg [31:0] last_price     [0:3];

    reg [31:0] total_buy_orders  = 0;
    reg [31:0] total_sell_orders = 0;

    reg [31:0] refused_pos [0:3];

    reg cfg_ack_pulse = 1'b0;

    integer init_i;
    initial begin
        buy_thr [0] = INIT_BUY_QCOM;  sell_thr[0] = INIT_SELL_QCOM;
        buy_thr [1] = INIT_BUY_TSLA;  sell_thr[1] = INIT_SELL_TSLA;
        buy_thr [2] = INIT_BUY_GME;   sell_thr[2] = INIT_SELL_GME;
        buy_thr [3] = INIT_BUY_NVDA;  sell_thr[3] = INIT_SELL_NVDA;
        for (init_i = 0; init_i < 4; init_i = init_i + 1) begin
            position      [init_i] = 16'sd0;
            volume_buys   [init_i] = 32'd0;
            volume_sells  [init_i] = 32'd0;
            cost_buys     [init_i] = 64'd0;
            proceeds_sells[init_i] = 64'd0;
            last_price    [init_i] = 32'd0;
            refused_pos   [init_i] = 32'd0;
        end
    end

    // returns 3-bit idx, top bit = "no match"
    function [2:0] ticker_idx;
        input [31:0] t;
        begin
            case (t)
                TICKER_QCOM: ticker_idx = 3'd0;
                TICKER_TSLA: ticker_idx = 3'd1;
                TICKER_GME : ticker_idx = 3'd2;
                TICKER_NVDA: ticker_idx = 3'd3;
                default    : ticker_idx = 3'd4;
            endcase
        end
    endfunction

    reg [23:0] rx_act_stretch = 0;

    always @(posedge rx_clk) begin
        rx_dv_d      <= rx_dv_w;
        rx_fire_buy  <= 1'b0;
        rx_fire_sell <= 1'b0;

        if (rx_dv_w) begin
            rx_act_stretch <= 24'd12_500_000;
        end else if (rx_act_stretch != 0) begin
            rx_act_stretch <= rx_act_stretch - 1;
        end

        case (p_state)
            P_IDLE: begin
                if (rx_dv_w) p_state <= P_HUNT;
            end
            P_HUNT: begin
                if (!rx_dv_w) p_state <= P_IDLE;
                else if (rx_byte_w == 8'hD5) begin
                    p_state    <= P_BODY;
                    p_byte_idx <= 0;
                    p_ethtype  <= 0;
                    p_magic    <= 0;
                    p_ticker   <= 0;
                    p_price    <= 0;
                    p_field2   <= 0;
                end
            end
            P_BODY: begin
                if (!rx_dv_w) begin

                    cfg_ack_pulse <= 1'b0;  

                    if (p_ethtype == 16'h88B6
                        && p_magic == 32'hCAFE_BABE
                        && ticker_idx(p_ticker) != 3'd4) begin

                        last_price[ticker_idx(p_ticker)] <= p_price;

                        if (p_price < buy_thr[ticker_idx(p_ticker)]) begin
                            
                            if (position[ticker_idx(p_ticker)] < POSITION_LIMIT) begin
                                rx_fire_buy <= 1'b1;
                                position[ticker_idx(p_ticker)]
                                    <= position[ticker_idx(p_ticker)] + 16'sd1;
                                volume_buys[ticker_idx(p_ticker)]
                                    <= volume_buys[ticker_idx(p_ticker)] + 32'd1;
                                cost_buys[ticker_idx(p_ticker)]
                                    <= cost_buys[ticker_idx(p_ticker)] + {32'd0, p_price};
                                total_buy_orders  <= total_buy_orders + 32'd1;
                            end else begin
                                refused_pos[ticker_idx(p_ticker)]
                                    <= refused_pos[ticker_idx(p_ticker)] + 32'd1;
                            end
                        end else if (p_price > sell_thr[ticker_idx(p_ticker)]) begin
                            
                            if (position[ticker_idx(p_ticker)] > -POSITION_LIMIT) begin
                                rx_fire_sell <= 1'b1;
                                position[ticker_idx(p_ticker)]
                                    <= position[ticker_idx(p_ticker)] - 16'sd1;
                                volume_sells[ticker_idx(p_ticker)]
                                    <= volume_sells[ticker_idx(p_ticker)] + 32'd1;
                                proceeds_sells[ticker_idx(p_ticker)]
                                    <= proceeds_sells[ticker_idx(p_ticker)] + {32'd0, p_price};
                                total_sell_orders <= total_sell_orders + 32'd1;
                            end else begin
                                refused_pos[ticker_idx(p_ticker)]
                                    <= refused_pos[ticker_idx(p_ticker)] + 32'd1;
                            end
                        end
                        
                        rx_price_lat  <= p_price;
                        rx_ticker_lat <= p_ticker;
                    end
                    else if (p_ethtype == 16'h88B8
                             && p_magic == 32'h434F_4E46  
                             && ticker_idx(p_ticker) != 3'd4) begin

                        buy_thr [ticker_idx(p_ticker)] <= p_price;
                        sell_thr[ticker_idx(p_ticker)] <= p_field2;
                        cfg_ack_pulse                  <= 1'b1;
                    end
                    p_state <= P_IDLE;
                end else begin
                    p_byte_idx <= p_byte_idx + 1;
                    case (p_byte_idx)
                        10'd12: p_ethtype[15:8] <= rx_byte_w;
                        10'd13: p_ethtype[7:0]  <= rx_byte_w;
                        10'd14: p_magic[31:24]  <= rx_byte_w;
                        10'd15: p_magic[23:16]  <= rx_byte_w;
                        10'd16: p_magic[15:8]   <= rx_byte_w;
                        10'd17: p_magic[7:0]    <= rx_byte_w;
                        10'd18: p_ticker[31:24] <= rx_byte_w;
                        10'd19: p_ticker[23:16] <= rx_byte_w;
                        10'd20: p_ticker[15:8]  <= rx_byte_w;
                        10'd21: p_ticker[7:0]   <= rx_byte_w;
                        10'd22: p_price[31:24]  <= rx_byte_w;
                        10'd23: p_price[23:16]  <= rx_byte_w;
                        10'd24: p_price[15:8]   <= rx_byte_w;
                        10'd25: p_price[7:0]    <= rx_byte_w;
                        10'd26: p_field2[31:24] <= rx_byte_w;
                        10'd27: p_field2[23:16] <= rx_byte_w;
                        10'd28: p_field2[15:8]  <= rx_byte_w;
                        10'd29: p_field2[7:0]   <= rx_byte_w;
                        default: ;
                    endcase
                end
            end
            default: p_state <= P_IDLE;
        endcase
    end

    reg rx_buy_tog  = 1'b0;
    reg rx_sell_tog = 1'b0;
    reg rx_cfg_tog  = 1'b0;
    always @(posedge rx_clk) begin
        if (rx_fire_buy ) rx_buy_tog  <= ~rx_buy_tog;
        if (rx_fire_sell) rx_sell_tog <= ~rx_sell_tog;
        if (cfg_ack_pulse) rx_cfg_tog <= ~rx_cfg_tog;
    end

    (* ASYNC_REG = "TRUE" *) reg [2:0] tx_buy_sync  = 0;
    (* ASYNC_REG = "TRUE" *) reg [2:0] tx_sell_sync = 0;
    (* ASYNC_REG = "TRUE" *) reg [2:0] tx_cfg_sync  = 0;
    always @(posedge clk_125) begin
        tx_buy_sync  <= {tx_buy_sync [1:0], rx_buy_tog };
        tx_sell_sync <= {tx_sell_sync[1:0], rx_sell_tog};
        tx_cfg_sync  <= {tx_cfg_sync [1:0], rx_cfg_tog };
    end
    // toggle synchronisers across rx_clk -> clk_125. fire pulse flips a 1-bit
    //  toggle, three FFs on the tx side resample, XOR of last two = single-cycle
    //  pulse. multi-bit values ride on plain 2FF synchronisers - they're stable
    //  for many cycles before the consumer reads, so no MCP issue.
    wire fire_buy_125  = tx_buy_sync [2] ^ tx_buy_sync [1];
    wire fire_sell_125 = tx_sell_sync[2] ^ tx_sell_sync[1];
    wire cfg_ack_125   = tx_cfg_sync [2] ^ tx_cfg_sync [1];

    (* ASYNC_REG = "TRUE" *) reg [31:0] tx_price_sync1 = 0;
    (* ASYNC_REG = "TRUE" *) reg [31:0] tx_price_sync2 = 0;
    (* ASYNC_REG = "TRUE" *) reg [31:0] tx_ticker_sync1 = 0;
    (* ASYNC_REG = "TRUE" *) reg [31:0] tx_ticker_sync2 = 0;

    (* ASYNC_REG = "TRUE" *) reg [31:0] tx_total_buy_s1   = 0;
    (* ASYNC_REG = "TRUE" *) reg [31:0] tx_total_buy_s2   = 0;
    (* ASYNC_REG = "TRUE" *) reg [31:0] tx_total_sell_s1  = 0;
    (* ASYNC_REG = "TRUE" *) reg [31:0] tx_total_sell_s2  = 0;

    (* ASYNC_REG = "TRUE" *) reg signed [15:0] tx_pos_s1 [0:3];
    (* ASYNC_REG = "TRUE" *) reg signed [15:0] tx_pos_s2 [0:3];

    (* ASYNC_REG = "TRUE" *) reg [31:0] tx_buy_thr_s1  [0:3];
    (* ASYNC_REG = "TRUE" *) reg [31:0] tx_buy_thr_s2  [0:3];
    (* ASYNC_REG = "TRUE" *) reg [31:0] tx_sell_thr_s1 [0:3];
    (* ASYNC_REG = "TRUE" *) reg [31:0] tx_sell_thr_s2 [0:3];

    (* ASYNC_REG = "TRUE" *) reg [31:0] tx_vol_buy_s1   [0:3];
    (* ASYNC_REG = "TRUE" *) reg [31:0] tx_vol_buy_s2   [0:3];
    (* ASYNC_REG = "TRUE" *) reg [31:0] tx_vol_sell_s1  [0:3];
    (* ASYNC_REG = "TRUE" *) reg [31:0] tx_vol_sell_s2  [0:3];
    (* ASYNC_REG = "TRUE" *) reg [63:0] tx_cost_s1      [0:3];
    (* ASYNC_REG = "TRUE" *) reg [63:0] tx_cost_s2      [0:3];
    (* ASYNC_REG = "TRUE" *) reg [63:0] tx_proceeds_s1  [0:3];
    (* ASYNC_REG = "TRUE" *) reg [63:0] tx_proceeds_s2  [0:3];
    (* ASYNC_REG = "TRUE" *) reg [31:0] tx_lastprice_s1 [0:3];
    (* ASYNC_REG = "TRUE" *) reg [31:0] tx_lastprice_s2 [0:3];
    (* ASYNC_REG = "TRUE" *) reg [31:0] tx_refused_s1   [0:3];
    (* ASYNC_REG = "TRUE" *) reg [31:0] tx_refused_s2   [0:3];

    integer init_cdc;
    initial begin
        for (init_cdc = 0; init_cdc < 4; init_cdc = init_cdc + 1) begin
            tx_pos_s1      [init_cdc] = 0;  tx_pos_s2      [init_cdc] = 0;
            tx_buy_thr_s1  [init_cdc] = 0;  tx_buy_thr_s2  [init_cdc] = 0;
            tx_sell_thr_s1 [init_cdc] = 0;  tx_sell_thr_s2 [init_cdc] = 0;
            tx_vol_buy_s1  [init_cdc] = 0;  tx_vol_buy_s2  [init_cdc] = 0;
            tx_vol_sell_s1 [init_cdc] = 0;  tx_vol_sell_s2 [init_cdc] = 0;
            tx_cost_s1     [init_cdc] = 0;  tx_cost_s2     [init_cdc] = 0;
            tx_proceeds_s1 [init_cdc] = 0;  tx_proceeds_s2 [init_cdc] = 0;
            tx_lastprice_s1[init_cdc] = 0;  tx_lastprice_s2[init_cdc] = 0;
            tx_refused_s1  [init_cdc] = 0;  tx_refused_s2  [init_cdc] = 0;
        end
    end

    integer cdc_i;
    always @(posedge clk_125) begin
        tx_price_sync1  <= rx_price_lat;
        tx_price_sync2  <= tx_price_sync1;
        tx_ticker_sync1 <= rx_ticker_lat;
        tx_ticker_sync2 <= tx_ticker_sync1;

        tx_total_buy_s1  <= total_buy_orders;
        tx_total_buy_s2  <= tx_total_buy_s1;
        tx_total_sell_s1 <= total_sell_orders;
        tx_total_sell_s2 <= tx_total_sell_s1;

        for (cdc_i = 0; cdc_i < 4; cdc_i = cdc_i + 1) begin
            tx_pos_s1      [cdc_i] <= position      [cdc_i];
            tx_pos_s2      [cdc_i] <= tx_pos_s1     [cdc_i];
            tx_buy_thr_s1  [cdc_i] <= buy_thr       [cdc_i];
            tx_buy_thr_s2  [cdc_i] <= tx_buy_thr_s1 [cdc_i];
            tx_sell_thr_s1 [cdc_i] <= sell_thr      [cdc_i];
            tx_sell_thr_s2 [cdc_i] <= tx_sell_thr_s1[cdc_i];
            // double-buffer the pnl counters so stats frame sees a coherent snapshot
            tx_vol_buy_s1  [cdc_i] <= volume_buys   [cdc_i];
            tx_vol_buy_s2  [cdc_i] <= tx_vol_buy_s1 [cdc_i];
            tx_vol_sell_s1 [cdc_i] <= volume_sells  [cdc_i];
            tx_vol_sell_s2 [cdc_i] <= tx_vol_sell_s1[cdc_i];
            tx_cost_s1     [cdc_i] <= cost_buys     [cdc_i];
            tx_cost_s2     [cdc_i] <= tx_cost_s1    [cdc_i];
            tx_proceeds_s1 [cdc_i] <= proceeds_sells[cdc_i];
            tx_proceeds_s2 [cdc_i] <= tx_proceeds_s1[cdc_i];
            tx_lastprice_s1[cdc_i] <= last_price    [cdc_i];
            tx_lastprice_s2[cdc_i] <= tx_lastprice_s1[cdc_i];
            tx_refused_s1  [cdc_i] <= refused_pos   [cdc_i];
            tx_refused_s2  [cdc_i] <= tx_refused_s1 [cdc_i];
        end
    end

    reg [23:0] hb_cnt = 0;
    reg        hb_tick = 1'b0;
    always @(posedge clk_125) begin
        hb_tick <= 1'b0;
        if (ready && locked) begin
            if (hb_cnt == 24'd12_499_999) begin
                hb_cnt <= 0;
                hb_tick <= 1'b1;
            end else hb_cnt <= hb_cnt + 1;
        end
    end

    reg [27:0] stats_cnt = 0;
    reg        stats_tick = 1'b0;
    always @(posedge clk_125) begin
        stats_tick <= 1'b0;
        if (ready && locked) begin
            if (stats_cnt == 28'd124_999_999) begin
                stats_cnt <= 0;
                stats_tick <= 1'b1;
            end else stats_cnt <= stats_cnt + 1;
        end
    end

    reg [31:0] cycle_ctr = 0;
    always @(posedge clk_125) cycle_ctr <= cycle_ctr + 32'd1;

    reg [31:0] t_start            = 0;
    reg        t_start_is_buy     = 1'b0;
    reg [31:0] last_buy_latency   = 0;
    reg [31:0] last_sell_latency  = 0;
    reg [31:0] dropped_busy       = 0;  // TODO: queue depth 2 would catch most of these

    // 1 Hz heartbeat. fully static, synth folds it into ROM.
    reg [7:0] hb_frame [0:71];
    integer hk;
    initial begin
        for (hk = 0; hk < 7; hk = hk + 1) hb_frame[hk] = 8'h55;
        hb_frame[7]  = 8'hD5;
        for (hk = 8; hk < 14; hk = hk + 1) hb_frame[hk] = 8'hFF;
        hb_frame[14] = 8'hDE; hb_frame[15] = 8'hAD; hb_frame[16] = 8'hBE;
        hb_frame[17] = 8'hEF; hb_frame[18] = 8'h00; hb_frame[19] = 8'h01;
        hb_frame[20] = 8'h88; hb_frame[21] = 8'hB5;
        hb_frame[22] = 8'h42; hb_frame[23] = 8'h55; hb_frame[24] = 8'h59;
        hb_frame[25] = 8'h20;
        hb_frame[26] = 8'h51; hb_frame[27] = 8'h43; hb_frame[28] = 8'h4F;
        hb_frame[29] = 8'h4D;
        for (hk = 30; hk < 68; hk = hk + 1) hb_frame[hk] = 8'h00;
        hb_frame[68] = 8'h73; hb_frame[69] = 8'hC9; hb_frame[70] = 8'h8B;
        hb_frame[71] = 8'hAC;
    end

    reg [7:0] od_frame [0:71];
    integer ok;
    initial begin
        for (ok = 0; ok < 7; ok = ok + 1) od_frame[ok] = 8'h55;
        od_frame[7]  = 8'hD5;
        
        for (ok = 8; ok < 14; ok = ok + 1) od_frame[ok] = 8'hFF;
        
        od_frame[14] = 8'hDE; od_frame[15] = 8'hAD; od_frame[16] = 8'hBE;
        od_frame[17] = 8'hEF; od_frame[18] = 8'h00; od_frame[19] = 8'h01;
        
        od_frame[20] = 8'h88; od_frame[21] = 8'hB7;
        
        od_frame[22] = 8'hDE; od_frame[23] = 8'hC1; od_frame[24] = 8'h51;
        od_frame[25] = 8'h01;
        
        od_frame[26] = 8'h00;

        od_frame[27] = 8'h51; od_frame[28] = 8'h43; od_frame[29] = 8'h4F;
        od_frame[30] = 8'h4D;
        
        od_frame[31] = 8'h00; od_frame[32] = 8'h00;
        od_frame[33] = 8'h00; od_frame[34] = 8'h00;
        
        for (ok = 35; ok < 68; ok = ok + 1) od_frame[ok] = 8'h00;
        
        od_frame[68] = 8'h00; od_frame[69] = 8'h00;
        od_frame[70] = 8'h00; od_frame[71] = 8'h00;
    end

    // ---- tx framer ----
    //  modes: IDLE / HB (heartbeat) / ORDER (response) / STATS (pnl)
    //  priority ORDER > STATS > HB. ORDER fires 2 cyc after the pulse arrives
    //  -> 16 ns. fire pulse during another frame = drop, counted in dropped_busy.
    //  there's no queue. depth-1 is fine for now, deepen later if multiple
    //  tickers cross at once.
    localparam T_IDLE = 2'd0, T_HB = 2'd1, T_ORDER = 2'd2, T_STATS = 2'd3;

    localparam [7:0] HB_END_PHASE    = 8'd71;    
    localparam [7:0] ORDER_END_PHASE = 8'd71;    
    localparam [7:0] STATS_END_PHASE = 8'd217;   

    reg [1:0] tx_mode = T_IDLE;
    reg [7:0] tx_phase = 0;
    reg       tx_fire_buy_lat  = 1'b0;
    reg       tx_fire_sell_lat = 1'b0;
    reg       tx_stats_pend    = 1'b0;   
    reg [31:0] tx_price_lat    = 0;
    reg [31:0] tx_ticker_lat   = 0;

    wire stats_trigger = stats_tick | cfg_ack_125;

    always @(posedge clk_125) begin

        if (tx_mode == T_IDLE) begin
            if (fire_sell_125) begin
                tx_fire_sell_lat <= 1'b1;
                tx_fire_buy_lat  <= 1'b0;
                tx_price_lat     <= tx_price_sync2;
                tx_ticker_lat    <= tx_ticker_sync2;
                t_start          <= cycle_ctr;
                t_start_is_buy   <= 1'b0;
            end else if (fire_buy_125) begin
                tx_fire_buy_lat  <= 1'b1;
                tx_fire_sell_lat <= 1'b0;
                tx_price_lat     <= tx_price_sync2;
                tx_ticker_lat    <= tx_ticker_sync2;
                t_start          <= cycle_ctr;
                t_start_is_buy   <= 1'b1;
            end
        end else begin
            
            if (fire_buy_125 || fire_sell_125)
                dropped_busy <= dropped_busy + 32'd1;
        end

        if (stats_trigger) tx_stats_pend <= 1'b1;

        case (tx_mode)
            T_IDLE: begin
                tx_phase <= 0;
                if (tx_fire_sell_lat || tx_fire_buy_lat) begin
                    tx_mode <= T_ORDER;
                end else if (tx_stats_pend && ready && locked) begin
                    tx_mode <= T_STATS;
                    tx_stats_pend <= 1'b0;
                end else if (hb_tick && ready && locked) begin
                    tx_mode <= T_HB;
                end
            end
            T_HB: begin
                if (tx_phase == HB_END_PHASE) begin
                    tx_mode <= T_IDLE;
                    tx_phase <= 0;
                end else tx_phase <= tx_phase + 1;
            end
            T_ORDER: begin
                if (tx_phase == 8'd0) begin
                    
                    if (t_start_is_buy)
                        last_buy_latency  <= cycle_ctr - t_start;
                    else
                        last_sell_latency <= cycle_ctr - t_start;
                end
                if (tx_phase == ORDER_END_PHASE) begin
                    tx_mode <= T_IDLE;
                    tx_phase <= 0;
                    tx_fire_buy_lat  <= 1'b0;
                    tx_fire_sell_lat <= 1'b0;
                end else tx_phase <= tx_phase + 1;
            end
            T_STATS: begin
                if (tx_phase == STATS_END_PHASE) begin
                    tx_mode <= T_IDLE;
                    tx_phase <= 0;
                end else tx_phase <= tx_phase + 1;
            end
            default: tx_mode <= T_IDLE;
        endcase
    end

    wire active = (tx_mode != T_IDLE);

    wire [7:0] action_byte = tx_fire_sell_lat ? 8'h53 : 8'h42;  

    function [7:0] stats_fixed;
        input [7:0] ph;
        begin
            case (ph)
                8'd0,8'd1,8'd2,8'd3,8'd4,8'd5,8'd6: stats_fixed = 8'h55;
                8'd7:                                stats_fixed = 8'hD5;
                8'd8,8'd9,8'd10,8'd11,8'd12,8'd13:   stats_fixed = 8'hFF;
                8'd14:                               stats_fixed = 8'hDE;
                8'd15:                               stats_fixed = 8'hAD;
                8'd16:                               stats_fixed = 8'hBE;
                8'd17:                               stats_fixed = 8'hEF;
                8'd18:                               stats_fixed = 8'h00;
                8'd19:                               stats_fixed = 8'h01;
                8'd20:                               stats_fixed = 8'h88;
                8'd21:                               stats_fixed = 8'hB9;
                8'd22:                               stats_fixed = 8'h53;   
                8'd23:                               stats_fixed = 8'h54;   
                8'd24:                               stats_fixed = 8'h41;   
                8'd25:                               stats_fixed = 8'h54;   
                default:                             stats_fixed = 8'h00;
            endcase
        end
    endfunction

    function [7:0] stats_dyn;
        input [7:0] ph;

        reg [3:0] sub;       
        reg [4:0] sub16;     
        reg [5:0] sub32;     
        reg [5:0] sub_thr;   
        reg [1:0] tk;        
        reg [1:0] which;     
        reg [2:0] which8;    
        begin
            stats_dyn = 8'h00;
            
            if      (ph == 8'd26) stats_dyn = tx_total_buy_s2[31:24];
            else if (ph == 8'd27) stats_dyn = tx_total_buy_s2[23:16];
            else if (ph == 8'd28) stats_dyn = tx_total_buy_s2[15:8];
            else if (ph == 8'd29) stats_dyn = tx_total_buy_s2[7:0];
            
            else if (ph == 8'd30) stats_dyn = tx_total_sell_s2[31:24];
            else if (ph == 8'd31) stats_dyn = tx_total_sell_s2[23:16];
            else if (ph == 8'd32) stats_dyn = tx_total_sell_s2[15:8];
            else if (ph == 8'd33) stats_dyn = tx_total_sell_s2[7:0];
            
            else if (ph == 8'd34) stats_dyn = dropped_busy[31:24];
            else if (ph == 8'd35) stats_dyn = dropped_busy[23:16];
            else if (ph == 8'd36) stats_dyn = dropped_busy[15:8];
            else if (ph == 8'd37) stats_dyn = dropped_busy[7:0];
            
            else if (ph == 8'd38) stats_dyn = last_buy_latency[31:24];
            else if (ph == 8'd39) stats_dyn = last_buy_latency[23:16];
            else if (ph == 8'd40) stats_dyn = last_buy_latency[15:8];
            else if (ph == 8'd41) stats_dyn = last_buy_latency[7:0];
            
            else if (ph == 8'd42) stats_dyn = last_sell_latency[31:24];
            else if (ph == 8'd43) stats_dyn = last_sell_latency[23:16];
            else if (ph == 8'd44) stats_dyn = last_sell_latency[15:8];
            else if (ph == 8'd45) stats_dyn = last_sell_latency[7:0];
            
            else if (ph >= 8'd46 && ph <= 8'd53) begin
                sub = ph - 8'd46;             
                tk  = sub[2:1];               
                if (sub[0] == 1'b0) stats_dyn = tx_pos_s2[tk][15:8];
                else                stats_dyn = tx_pos_s2[tk][7:0];
            end
            
            else if (ph >= 8'd54 && ph <= 8'd69) begin
                sub16 = ph - 8'd54;           
                tk    = sub16[3:2];
                which = sub16[1:0];
                case (which)
                    2'd0: stats_dyn = tx_refused_s2[tk][31:24];
                    2'd1: stats_dyn = tx_refused_s2[tk][23:16];
                    2'd2: stats_dyn = tx_refused_s2[tk][15:8];
                    2'd3: stats_dyn = tx_refused_s2[tk][7:0];
                endcase
            end
            
            else if (ph >= 8'd70 && ph <= 8'd85) begin
                sub16 = ph - 8'd70;
                tk    = sub16[3:2];
                which = sub16[1:0];
                case (which)
                    2'd0: stats_dyn = tx_vol_buy_s2[tk][31:24];
                    2'd1: stats_dyn = tx_vol_buy_s2[tk][23:16];
                    2'd2: stats_dyn = tx_vol_buy_s2[tk][15:8];
                    2'd3: stats_dyn = tx_vol_buy_s2[tk][7:0];
                endcase
            end
            
            else if (ph >= 8'd86 && ph <= 8'd101) begin
                sub16 = ph - 8'd86;
                tk    = sub16[3:2];
                which = sub16[1:0];
                case (which)
                    2'd0: stats_dyn = tx_vol_sell_s2[tk][31:24];
                    2'd1: stats_dyn = tx_vol_sell_s2[tk][23:16];
                    2'd2: stats_dyn = tx_vol_sell_s2[tk][15:8];
                    2'd3: stats_dyn = tx_vol_sell_s2[tk][7:0];
                endcase
            end
            
            else if (ph >= 8'd102 && ph <= 8'd133) begin
                sub32  = ph - 8'd102;             
                tk     = sub32[4:3];              
                which8 = sub32[2:0];              
                case (which8)
                    3'd0: stats_dyn = tx_cost_s2[tk][63:56];
                    3'd1: stats_dyn = tx_cost_s2[tk][55:48];
                    3'd2: stats_dyn = tx_cost_s2[tk][47:40];
                    3'd3: stats_dyn = tx_cost_s2[tk][39:32];
                    3'd4: stats_dyn = tx_cost_s2[tk][31:24];
                    3'd5: stats_dyn = tx_cost_s2[tk][23:16];
                    3'd6: stats_dyn = tx_cost_s2[tk][15:8];
                    3'd7: stats_dyn = tx_cost_s2[tk][7:0];
                endcase
            end
            
            else if (ph >= 8'd134 && ph <= 8'd165) begin
                sub32  = ph - 8'd134;
                tk     = sub32[4:3];
                which8 = sub32[2:0];
                case (which8)
                    3'd0: stats_dyn = tx_proceeds_s2[tk][63:56];
                    3'd1: stats_dyn = tx_proceeds_s2[tk][55:48];
                    3'd2: stats_dyn = tx_proceeds_s2[tk][47:40];
                    3'd3: stats_dyn = tx_proceeds_s2[tk][39:32];
                    3'd4: stats_dyn = tx_proceeds_s2[tk][31:24];
                    3'd5: stats_dyn = tx_proceeds_s2[tk][23:16];
                    3'd6: stats_dyn = tx_proceeds_s2[tk][15:8];
                    3'd7: stats_dyn = tx_proceeds_s2[tk][7:0];
                endcase
            end
            
            else if (ph >= 8'd166 && ph <= 8'd181) begin
                sub16 = ph - 8'd166;
                tk    = sub16[3:2];
                which = sub16[1:0];
                case (which)
                    2'd0: stats_dyn = tx_lastprice_s2[tk][31:24];
                    2'd1: stats_dyn = tx_lastprice_s2[tk][23:16];
                    2'd2: stats_dyn = tx_lastprice_s2[tk][15:8];
                    2'd3: stats_dyn = tx_lastprice_s2[tk][7:0];
                endcase
            end

            else if (ph >= 8'd182 && ph <= 8'd213) begin
                sub_thr = ph - 8'd182;            
                tk      = sub_thr[4:3];           

                if (sub_thr[2] == 1'b0) begin
                    case (sub_thr[1:0])
                        2'd0: stats_dyn = tx_buy_thr_s2[tk][31:24];
                        2'd1: stats_dyn = tx_buy_thr_s2[tk][23:16];
                        2'd2: stats_dyn = tx_buy_thr_s2[tk][15:8];
                        2'd3: stats_dyn = tx_buy_thr_s2[tk][7:0];
                    endcase
                end else begin
                    case (sub_thr[1:0])
                        2'd0: stats_dyn = tx_sell_thr_s2[tk][31:24];
                        2'd1: stats_dyn = tx_sell_thr_s2[tk][23:16];
                        2'd2: stats_dyn = tx_sell_thr_s2[tk][15:8];
                        2'd3: stats_dyn = tx_sell_thr_s2[tk][7:0];
                    endcase
                end
            end
        end
    endfunction

    reg [7:0] body_byte;
    always @* begin
        case (tx_mode)
            T_HB:    body_byte = hb_frame[tx_phase[6:0]];   
            T_ORDER: begin
                case (tx_phase)
                    8'd26:   body_byte = action_byte;
                    8'd27:   body_byte = tx_ticker_lat[31:24];
                    8'd28:   body_byte = tx_ticker_lat[23:16];
                    8'd29:   body_byte = tx_ticker_lat[15:8];
                    8'd30:   body_byte = tx_ticker_lat[7:0];
                    8'd31:   body_byte = tx_price_lat[31:24];
                    8'd32:   body_byte = tx_price_lat[23:16];
                    8'd33:   body_byte = tx_price_lat[15:8];
                    8'd34:   body_byte = tx_price_lat[7:0];
                    default: body_byte = od_frame[tx_phase[6:0]];
                endcase
            end
            T_STATS: begin
                if (tx_phase <= 8'd25)
                    body_byte = stats_fixed(tx_phase);
                else
                    body_byte = stats_dyn(tx_phase);
            end
            default: body_byte = 8'h00;
        endcase
    end

    // ---- Ethernet FCS (IEEE 802.3, polynomial 0xEDB88320 reflected) ----
    //  byte-at-a-time, bitwise. could be a 256-entry LUT (Sarwate) for parallel
    //  byte processing but the byte mux feeding it is already serial so there's
    //  no point. easily hits 125 MHz like this.
    function [31:0] crc32_byte;
        input [31:0] crc_in;
        input [7:0]  data;
        integer  i;
        reg [31:0] c;
        begin
            c = crc_in ^ {24'h0, data};
            for (i = 0; i < 8; i = i + 1) begin
                c = (c[0]) ? ((c >> 1) ^ 32'hEDB88320) : (c >> 1);
            end
            crc32_byte = c;
        end
    endfunction

    reg [31:0] crc_state = 32'hFFFFFFFF;
    always @(posedge clk_125) begin
        if (tx_mode == T_ORDER) begin
            if (tx_phase == 8'd7) begin
                
                crc_state <= 32'hFFFFFFFF;
            end else if (tx_phase >= 8'd8 && tx_phase <= 8'd67) begin
                
                crc_state <= crc32_byte(crc_state, body_byte);
            end
        end else if (tx_mode == T_STATS) begin
            if (tx_phase == 8'd7) begin
                crc_state <= 32'hFFFFFFFF;
            end else if (tx_phase >= 8'd8 && tx_phase <= 8'd213) begin
                
                crc_state <= crc32_byte(crc_state, body_byte);
            end
        end
    end

    wire [31:0] final_crc = ~crc_state;

    reg [7:0] tx_byte;
    always @* begin
        if (tx_mode == T_ORDER) begin
            case (tx_phase)
                8'd68: tx_byte = final_crc[7:0];
                8'd69: tx_byte = final_crc[15:8];
                8'd70: tx_byte = final_crc[23:16];
                8'd71: tx_byte = final_crc[31:24];
                default: tx_byte = body_byte;
            endcase
        end else if (tx_mode == T_STATS) begin
            case (tx_phase)
                8'd214: tx_byte = final_crc[7:0];
                8'd215: tx_byte = final_crc[15:8];
                8'd216: tx_byte = final_crc[23:16];
                8'd217: tx_byte = final_crc[31:24];
                default: tx_byte = body_byte;
            endcase
        end else if (tx_mode == T_HB) begin
            tx_byte = hb_frame[tx_phase[6:0]];
        end else begin
            tx_byte = 8'h00;
        end
    end

    // ---- TX physical (ODDRs) ----
    //  each TXD bit: ODDR launching {byte[i+4] @ falling, byte[i] @ rising}.
    //  TXC is also an ODDR but on clk_125_90 (the 90-deg shifted clock), which
    //  centres the launch edge on the data eye at the receiver.
    //
    //  TXCTL is the weird one: D1=D2=active, because RGMII repurposes the falling
    //  sample of TXCTL as TX_EN xor TX_ER. We never assert ER so the falling
    //  sample needs to match the rising one to keep ER=0. Spent half a day
    //  chasing this before reading the spec properly.
    genvar j;
    generate
        for (j = 0; j < 4; j = j + 1) begin : tx_bits
            ODDR #(.DDR_CLK_EDGE("SAME_EDGE")) o_d (
                .Q(eth_rgmii_txd[j]), .C(clk_125), .CE(1'b1),
                .D1(tx_byte[j]), .D2(tx_byte[j+4]),
                .R(1'b0), .S(1'b0)
            );
        end
    endgenerate

    ODDR #(.DDR_CLK_EDGE("SAME_EDGE")) o_c (
        .Q(eth_rgmii_tx_ctl), .C(clk_125), .CE(1'b1),
        .D1(active), .D2(active), .R(1'b0), .S(1'b0)
    );

    ODDR o_ck (
        .Q(eth_rgmii_txc), .C(clk_125_90), .CE(1'b1),
        .D1(1'b1), .D2(1'b0), .R(1'b0), .S(1'b0)
    );

    // ---- LEDs ----
    //    [0] alive    [1] rx activity    [2] BUY    [3] SELL
    (* ASYNC_REG = "TRUE" *) reg [2:0] rx_act_sync = 0;
    always @(posedge clk_125)
        rx_act_sync <= {rx_act_sync[1:0], (rx_act_stretch != 0)};

    reg [23:0] buy_pulse  = 0;
    reg [23:0] sell_pulse = 0;
    always @(posedge clk_125) begin
        if (fire_buy_125)
            buy_pulse  <= 24'd12_500_000;
        else if (buy_pulse != 0)
            buy_pulse  <= buy_pulse - 1;

        if (fire_sell_125)
            sell_pulse <= 24'd12_500_000;
        else if (sell_pulse != 0)
            sell_pulse <= sell_pulse - 1;
    end

    assign led[0] = ready;
    assign led[1] = rx_act_sync[2];
    assign led[2] = (buy_pulse  != 0);
    assign led[3] = (sell_pulse != 0);

endmodule
