module hls_bridge_qos_dti_pck_enc #(

  /////////////////////////////////////////////////////////////////////////////
  //                                Parameters                               //
  /////////////////////////////////////////////////////////////////////////////
  /*BSF:doc=Maximum number of TLPs supported per clock;*/
  parameter KMAX_NUM_TLPS_PER_CLK      = 4,
  /*BSF:doc=Number of HLS ports on AXI-Bridge side;*/
  /*BSF:doc=DTI HLS control bus width (calculated at top level);*/
  parameter HLS_DTI_CNTL_WD            = 1024,
  /*BSF:doc=Maximum data path width supported in the design;*/
  parameter KMAX_DATAPATH_WD           = 1024,
  /*BSF:doc=Start pointer alignment: 2=64-bit (2 DWORDs), 4=128-bit (4 DWORDs);*/
  parameter HLS_DW_ALIGNMENT           = 2,
  /*BSF:doc=HLS metadata width per TLP slot;*/
  parameter HLS_METADATA_WD            = 10,
  /*BSF:doc=Number of supported TLP ID streams;*/
  parameter NUM_TLP_STREAMS            = 8,
  /*BSF:doc=Number of QoS counter groups (NUM_TLP_STREAMS x 4: P-REQ, NP-REQ, P-RESP, NP-RESP);*/
  parameter COUNT_NUMBER               = 32,
  /*BSF:doc=Channel type: 1=Posted (enables P&REQ + P&RESP), 0=Non-Posted (enables NP&REQ + NP&RESP);*/
  parameter IS_POSTED                  = 1,

  localparam METADATA_STREAM_ID_WD     = 3,
  localparam METADATA_STREAM_ID_OFFSET = 48,
  localparam NUM_TLP_STREAMS_MAX       = 8,
  localparam HLS_HAL_STR_PTR_WD        = $clog2(KMAX_DATAPATH_WD/HLS_DW_ALIGNMENT/32),
  localparam HLS_HAL_END_PTR_WD        = $clog2(KMAX_DATAPATH_WD/32),
  localparam HLS_HAL_PKT_CNTL_WD       = KMAX_NUM_TLPS_PER_CLK*(3+HLS_HAL_STR_PTR_WD+HLS_HAL_END_PTR_WD)
)(
  /*BSF:isClock=1,clock_group="CORE",doc=Core clock;*/
  input  wire                                               core_clk,
  /*BSF:isReset=1,clock=core_clk,doc=Core active-low reset;*/
  input  wire                                               core_rst_n,

  //----------------------------------------------------------------------------
  // DTI HLS RX control interface (Posted or Non-Posted channel)
  //----------------------------------------------------------------------------
  /*BSF_IF:dti_pck_enc_rx_if,core_clk,core_rst_n,nipio=0
  ,dis=DTI HLS RX interface (Posted or Non-Posted channel)
  ;*/
  input  wire                                               hls_rx_dti_valid,
  input  wire [HLS_DTI_CNTL_WD-1:0]                        hls_rx_dti_cntl,
  //BSF_IF_END:dti_pck_enc_rx_if;

  //----------------------------------------------------------------------------
  // QoS counter-enable output (flattened 2D array)
  //   Flat layout: [cnt*(K+1) +: (K+1)] = counter group 'cnt', K+1 slots
  //   (slots 0..K-1 = normal TLP slots, slot K = legacy spill slot — unused)
  //----------------------------------------------------------------------------
  /*BSF_IF:dti_pck_enc_tx_if,core_clk,core_rst_n,ipio=0
  ,dis=Per-slot counter-group enable flat output (before transpose)
  ;*/
  output wire [(KMAX_NUM_TLPS_PER_CLK+1)*COUNT_NUMBER-1:0] dti_num_en_out
  //BSF_IF_END:dti_pck_enc_tx_if;
);

  reg                                          dti_valid;
  reg [2:0]                                    dti_stream         [KMAX_NUM_TLPS_PER_CLK-1:0];
  reg [2:0]                                    dti_stream_reg     [KMAX_NUM_TLPS_PER_CLK:0];
  reg [METADATA_STREAM_ID_WD-1:0]              cntl_metadata_stream_id [KMAX_NUM_TLPS_PER_CLK-1:0];

  reg [KMAX_NUM_TLPS_PER_CLK-1:0]              slot_armed_reg;
  reg [METADATA_STREAM_ID_WD-1:0]              slot_stream_reg    [KMAX_NUM_TLPS_PER_CLK-1:0];

  reg [KMAX_NUM_TLPS_PER_CLK:0]               pck_ended_reg;

  reg [NUM_TLP_STREAMS_MAX-1:0]               qos_stream_en [KMAX_NUM_TLPS_PER_CLK:0];
  reg [COUNT_NUMBER-1:0]                      dti_num_en    [KMAX_NUM_TLPS_PER_CLK:0];

  wire [KMAX_NUM_TLPS_PER_CLK-1:0]            slot_same_cycle;
  wire [KMAX_NUM_TLPS_PER_CLK-1:0]            slot_cont_eop;
  wire [KMAX_NUM_TLPS_PER_CLK-1:0]            slot_arm_new;

  wire [KMAX_NUM_TLPS_PER_CLK:0]              pck_ended;

  wire [KMAX_NUM_TLPS_PER_CLK-1:0]            cntl_sop;
  wire [KMAX_NUM_TLPS_PER_CLK-1:0]            cntl_eop;
  wire [KMAX_NUM_TLPS_PER_CLK-1:0]            cntl_enderror;
  wire [HLS_HAL_STR_PTR_WD-1:0]               cntl_strptr  [KMAX_NUM_TLPS_PER_CLK-1:0];
  wire [HLS_HAL_END_PTR_WD-1:0]               cntl_endptr  [KMAX_NUM_TLPS_PER_CLK-1:0];
  wire [HLS_METADATA_WD-1:0]                  cntl_metadata[KMAX_NUM_TLPS_PER_CLK-1:0];

  genvar gv_x;

  generate
    `HLSB_HLS_UNPACK_CNTL(hls_rx_dti_cntl,
                           cntl_sop,
                           cntl_strptr,
                           cntl_eop,
                           cntl_enderror,
                           cntl_endptr,
                           cntl_metadata,
                           KMAX_NUM_TLPS_PER_CLK,
                           KMAX_NUM_TLPS_PER_CLK,
                           HLS_HAL_STR_PTR_WD,
                           HLS_HAL_END_PTR_WD,
                           HLS_METADATA_WD,
                           HLS_HAL_PKT_CNTL_WD,
                           gen_unpack_cntl)
  endgenerate

  // idgroup[2:0] is LSB of per-slot unpacked metadata (bus bit 48 = meta[0] for slot 0).
  generate
    for (gv_x = 0; gv_x < KMAX_NUM_TLPS_PER_CLK; gv_x = gv_x + 1) begin : gen_stream_id
      always @(*) begin : process_cntl_metadata
        if (hls_rx_dti_valid)
          cntl_metadata_stream_id[gv_x] = cntl_metadata[gv_x][0 +: METADATA_STREAM_ID_WD];
        else
          cntl_metadata_stream_id[gv_x] = {METADATA_STREAM_ID_WD{1'b0}};
      end
    end
  endgenerate

  // Per-slot packet tracking — no global spill slot.
  // Each slot scores only in that slot (same-cycle SOP+EOP or continuation EOP).
  // Avoids cross-slot phantom counts (stream-3 stale spill closed by stream-0 EOP).
  assign slot_same_cycle = hls_rx_dti_valid & cntl_sop & cntl_eop;
  assign slot_cont_eop   = hls_rx_dti_valid & ~cntl_sop & cntl_eop & slot_armed_reg;
  assign slot_arm_new    = hls_rx_dti_valid & cntl_sop & ~cntl_eop & ~slot_armed_reg;

  assign pck_ended[KMAX_NUM_TLPS_PER_CLK-1:0] =
      slot_same_cycle | slot_cont_eop;
  assign pck_ended[KMAX_NUM_TLPS_PER_CLK] = 1'b0;

  always @(*) begin : full_pck_detection
    integer i;
    for (i = 0; i < KMAX_NUM_TLPS_PER_CLK; i = i + 1) begin
      if (slot_same_cycle[i])
        dti_stream[i] = cntl_metadata_stream_id[i];
      else if (slot_cont_eop[i])
        dti_stream[i] = slot_stream_reg[i];
      else
        dti_stream[i] = {METADATA_STREAM_ID_WD{1'b0}};
    end
  end

  always @(posedge core_clk or negedge core_rst_n) begin : process_seq
    integer i;
    if (core_rst_n == 1'b0) begin
      dti_valid          <= 1'b0;
      pck_ended_reg      <= {KMAX_NUM_TLPS_PER_CLK+1{1'b0}};
      slot_armed_reg     <= {KMAX_NUM_TLPS_PER_CLK{1'b0}};
      for (i = 0; i < KMAX_NUM_TLPS_PER_CLK; i = i + 1) begin
        slot_stream_reg[i] <= {METADATA_STREAM_ID_WD{1'b0}};
        dti_stream_reg[i]  <= {METADATA_STREAM_ID_WD{1'b0}};
      end
      dti_stream_reg[KMAX_NUM_TLPS_PER_CLK] <= {METADATA_STREAM_ID_WD{1'b0}};
    end
    else if (hls_rx_dti_valid) begin
      dti_valid      <= 1'b1;
      pck_ended_reg  <= pck_ended;
      for (i = 0; i < KMAX_NUM_TLPS_PER_CLK; i = i + 1) begin
        dti_stream_reg[i] <= dti_stream[i];
        if (slot_same_cycle[i] || slot_cont_eop[i])
          slot_armed_reg[i] <= 1'b0;
        else if (slot_arm_new[i]) begin
          slot_armed_reg[i]  <= 1'b1;
          slot_stream_reg[i] <= cntl_metadata_stream_id[i];
        end
      end
      dti_stream_reg[KMAX_NUM_TLPS_PER_CLK] <= {METADATA_STREAM_ID_WD{1'b0}};
    end
    else begin
      dti_valid     <= 1'b0;
      pck_ended_reg <= {KMAX_NUM_TLPS_PER_CLK+1{1'b0}};
      for (i = 0; i < KMAX_NUM_TLPS_PER_CLK; i = i + 1)
        dti_stream_reg[i] <= {METADATA_STREAM_ID_WD{1'b0}};
      // Hold slot_armed_reg / slot_stream_reg across valid bubbles (multi-beat TLP)
    end
  end

  always @(*) begin : stream_en_decode
    integer i;
    for (i = 0; i <= KMAX_NUM_TLPS_PER_CLK; i = i + 1) begin
      if (pck_ended_reg[i]) begin
        case (dti_stream_reg[i])
          3'b000 : qos_stream_en[i] = 8'b00000001;
          3'b001 : qos_stream_en[i] = 8'b00000010;
          3'b010 : qos_stream_en[i] = 8'b00000100;
          3'b011 : qos_stream_en[i] = 8'b00001000;
          3'b100 : qos_stream_en[i] = 8'b00010000;
          3'b101 : qos_stream_en[i] = 8'b00100000;
          3'b110 : qos_stream_en[i] = 8'b01000000;
          3'b111 : qos_stream_en[i] = 8'b10000000;
          default: qos_stream_en[i] = 8'h00;
        endcase
      end
      else
        qos_stream_en[i] = 8'h00;
    end
  end

  generate
    if (IS_POSTED) begin : gen_posted_encode
      always @(*) begin : counter_en_encode
        integer i;
        for (i = 0; i <= KMAX_NUM_TLPS_PER_CLK; i = i + 1) begin
          if (pck_ended_reg[i])
            dti_num_en[i] = {{NUM_TLP_STREAMS{1'b0}}, qos_stream_en[i][NUM_TLP_STREAMS-1:0],
                             {NUM_TLP_STREAMS{1'b0}}, qos_stream_en[i][NUM_TLP_STREAMS-1:0]};
          else
            dti_num_en[i] = {4*NUM_TLP_STREAMS{1'b0}};
        end
      end
    end
    else begin : gen_nonposted_encode
      always @(*) begin : counter_en_encode
        integer i;
        for (i = 0; i <= KMAX_NUM_TLPS_PER_CLK; i = i + 1) begin
          if (pck_ended_reg[i])
            dti_num_en[i] = {qos_stream_en[i][NUM_TLP_STREAMS-1:0], {NUM_TLP_STREAMS{1'b0}},
                             qos_stream_en[i][NUM_TLP_STREAMS-1:0], {NUM_TLP_STREAMS{1'b0}}};
          else
            dti_num_en[i] = {4*NUM_TLP_STREAMS{1'b0}};
        end
      end
    end
  endgenerate

  generate
    `HLSB_2D_TO_WIDE(dti_num_en_flat, dti_num_en, gen_num_en_flat,
                     (KMAX_NUM_TLPS_PER_CLK+1), COUNT_NUMBER)
  endgenerate

  assign dti_num_en_out = dti_num_en_flat;

endmodule
