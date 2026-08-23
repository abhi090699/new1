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
  parameter LBB_NUM_TLP_STREAMS        = 8,
  /*BSF:doc=Number of QoS counter groups (LBB_NUM_TLP_STREAMS x 2: P, NP);*/
  parameter COUNT_NUMBER               = 16,
  /*BSF:doc=Channel type: 1=Posted (enables P group), 0=Non-Posted (enables NP group);*/
  parameter IS_POSTED                  = 1,

  localparam METADATA_STREAM_ID_WD     = 3,
  localparam METADATA_STREAM_ID_OFFSET = 48,
  localparam LBB_NUM_TLP_STREAMS_MAX   = 8,
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
  //   (slots 0..K-1 = normal TLP slots, slot K = spilled-packet slot)
  //----------------------------------------------------------------------------
  /*BSF_IF:dti_pck_enc_tx_if,core_clk,core_rst_n,ipio=0
  ,dis=Per-slot counter-group enable flat output (before transpose)
  ;*/
  output wire [(KMAX_NUM_TLPS_PER_CLK+1)*COUNT_NUMBER-1:0] dti_num_en_out
  //BSF_IF_END:dti_pck_enc_tx_if;
);

  /////////////////////////////////////////////////////////////////////////////
  // localparam declarations
  /////////////////////////////////////////////////////////////////////////////

  // (all localparams are in the parameter list above)

  /////////////////////////////////////////////////////////////////////////////
  // reg declarations
  /////////////////////////////////////////////////////////////////////////////

  reg                                          spilled_pck_next;
  reg [2:0]                                    spilled_pck_stream_id;
  reg [2:0]                                    dti_stream         [KMAX_NUM_TLPS_PER_CLK-1:0];

  reg                                          dti_valid;
  reg                                          spilled_pck_reg;
  reg [2:0]                                    spilled_pck_stream_id_reg;
  reg [2:0]                                    dti_stream_reg     [KMAX_NUM_TLPS_PER_CLK:0];
  reg [METADATA_STREAM_ID_WD-1:0]              cntl_metadata_stream_id [KMAX_NUM_TLPS_PER_CLK-1:0];

  reg [KMAX_NUM_TLPS_PER_CLK:0]               pck_ended_reg;

  reg [LBB_NUM_TLP_STREAMS_MAX-1:0]           qos_stream_en [KMAX_NUM_TLPS_PER_CLK:0];
  reg [COUNT_NUMBER-1:0]                      dti_num_en    [KMAX_NUM_TLPS_PER_CLK:0];

  /////////////////////////////////////////////////////////////////////////////
  // wire declarations
  /////////////////////////////////////////////////////////////////////////////

  wire [KMAX_NUM_TLPS_PER_CLK-1:0]            sop_shift;
  wire                                         eop_detection;
  wire                                         spilled_pck;

  wire [KMAX_NUM_TLPS_PER_CLK:0]              pck_ended;

  wire [KMAX_NUM_TLPS_PER_CLK-1:0]            cntl_sop;
  wire [KMAX_NUM_TLPS_PER_CLK-1:0]            cntl_eop;
  wire [KMAX_NUM_TLPS_PER_CLK-1:0]            cntl_enderror;
  wire [HLS_HAL_STR_PTR_WD-1:0]               cntl_strptr  [KMAX_NUM_TLPS_PER_CLK-1:0];
  wire [HLS_HAL_END_PTR_WD-1:0]               cntl_endptr  [KMAX_NUM_TLPS_PER_CLK-1:0];
  wire [HLS_METADATA_WD-1:0]                  cntl_metadata[KMAX_NUM_TLPS_PER_CLK-1:0];

  /////////////////////////////////////////////////////////////////////////////
  // Logic
  /////////////////////////////////////////////////////////////////////////////

  genvar gv_x;

  // Unpack HLS control bus into SOP / EOP / STRPTR / ENDPTR / METADATA vectors
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

  // Extract stream ID from per-slot metadata
  // 10-bit DTI metadata: [2:0] VC, [5:3] stream/idgroup (same order as MSI)
  generate
    for (gv_x = 0; gv_x < KMAX_NUM_TLPS_PER_CLK; gv_x = gv_x + 1) begin
      always @(*) begin : process_cntl_metadata
        if (hls_rx_dti_valid)
          cntl_metadata_stream_id[gv_x] = cntl_metadata[gv_x][3 +: METADATA_STREAM_ID_WD];
        else
          cntl_metadata_stream_id[gv_x] = {METADATA_STREAM_ID_WD{1'b0}};
      end
    end

  // SOP shift: when a spill is active, shift SOPs left by 1 to reserve slot 0
  // for the spilled packet's EOP; for KMAX=1 there is no room to shift so
  // suppress all SOPs instead (a new SOP cannot arrive while spill is pending).
    if (KMAX_NUM_TLPS_PER_CLK == 1) begin : gen_no_sop_shift
      assign sop_shift = spilled_pck_reg ? 1'b0 : cntl_sop;
    end else begin : gen_sop_shift
      assign sop_shift = spilled_pck_reg ? cntl_sop << 1 : cntl_sop;
    end
  endgenerate

  // EOP detection: any EOP flag set while valid
  assign eop_detection = (|cntl_eop) & hls_rx_dti_valid;
  // Spilled packet: a shifted SOP slot has no matching EOP this cycle
  assign spilled_pck   = |(sop_shift & ~cntl_eop);

  // Per-slot packet-ended flags (K+1 bits: K normal slots + 1 spill slot)
  assign pck_ended[KMAX_NUM_TLPS_PER_CLK-1:0] =
      hls_rx_dti_valid ? (sop_shift & cntl_eop) : {KMAX_NUM_TLPS_PER_CLK{1'b0}};
  assign pck_ended[KMAX_NUM_TLPS_PER_CLK] = spilled_pck_reg & eop_detection;

  // Spill state: set on spill detected, cleared when the deferred EOP arrives
  always @(*) begin : process_spilled_pck_comb
    if (spilled_pck)
      spilled_pck_next = 1'b1;
    else if (eop_detection && spilled_pck_reg)
      spilled_pck_next = 1'b0;
    else
      spilled_pck_next = spilled_pck_reg;
  end

  // Spilled-packet stream ID: latch the stream ID of the spilling SOP
  always @(*) begin : spilled_stream_id
    integer i;
    for (i = 0; i < KMAX_NUM_TLPS_PER_CLK; i = i + 1) begin
      if (spilled_pck) begin
        if (cntl_sop[i] & ~cntl_eop[i])
          spilled_pck_stream_id = cntl_metadata_stream_id[i];
        else if (eop_detection)
          spilled_pck_stream_id = 3'b000;
        else
          spilled_pck_stream_id = spilled_pck_stream_id_reg;
      end
      else
        spilled_pck_stream_id = 3'b000;
    end
  end

  // Full-packet stream ID: capture stream ID for slots where SOP and EOP coincide
  always @(*) begin : full_pck_detection
    integer i;
    for (i = 0; i < KMAX_NUM_TLPS_PER_CLK; i = i + 1) begin
      if (sop_shift[i] & cntl_eop[i] & hls_rx_dti_valid)
        dti_stream[i] = cntl_metadata_stream_id[i];
      else
        dti_stream[i] = 3'b000;
    end
  end

  // Sequential: register all state
  always @(posedge core_clk or negedge core_rst_n) begin : process_seq
    integer i;
    if (core_rst_n == 1'b0) begin
      dti_valid                 <= 1'b0;
      pck_ended_reg             <= {KMAX_NUM_TLPS_PER_CLK+1{1'b0}};
      spilled_pck_reg           <= 1'b0;
      spilled_pck_stream_id_reg <= 3'b000;
      for (i = 0; i <= KMAX_NUM_TLPS_PER_CLK; i = i + 1)
        dti_stream_reg[i]       <= 3'b000;
    end
    else if (hls_rx_dti_valid) begin
      dti_valid                 <= hls_rx_dti_valid;
      pck_ended_reg             <= pck_ended;
      spilled_pck_reg           <= spilled_pck_next;
      spilled_pck_stream_id_reg <= spilled_pck_stream_id;
      for (i = 0; i < KMAX_NUM_TLPS_PER_CLK; i = i + 1)
        dti_stream_reg[i]                     <= dti_stream[i];
      dti_stream_reg[KMAX_NUM_TLPS_PER_CLK]   <= spilled_pck_stream_id;
    end
    else begin
      dti_valid                 <= 1'b0;
      pck_ended_reg             <= {KMAX_NUM_TLPS_PER_CLK+1{1'b0}};
      spilled_pck_reg           <= 1'b0;
      spilled_pck_stream_id_reg <= 3'b000;
      for (i = 0; i <= KMAX_NUM_TLPS_PER_CLK; i = i + 1)
        dti_stream_reg[i]       <= 3'b000;
    end
  end

  // Decode 3-bit stream ID to one-hot 8-bit vector per slot
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
        endcase
      end
      else
        qos_stream_en[i] = 8'h00;
    end
  end

  // Counter-group encoding — selected by IS_POSTED at elaboration time.
  // Bus layout: {NP[N], P[N]}  (N = LBB_NUM_TLP_STREAMS)
  generate
    if (IS_POSTED) begin : gen_posted_encode
      // Posted: {NP{0}, P{en}}
      always @(*) begin : counter_en_encode
        integer i;
        for (i = 0; i <= KMAX_NUM_TLPS_PER_CLK; i = i + 1) begin
          if (pck_ended_reg[i])
            dti_num_en[i] = {{LBB_NUM_TLP_STREAMS{1'b0}}, qos_stream_en[i][LBB_NUM_TLP_STREAMS-1:0]};
          else
            dti_num_en[i] = {2*LBB_NUM_TLP_STREAMS{1'b0}};
        end
      end
    end
    else begin : gen_nonposted_encode
      // Non-Posted: {NP{en}, P{0}}
      always @(*) begin : counter_en_encode
        integer i;
        for (i = 0; i <= KMAX_NUM_TLPS_PER_CLK; i = i + 1) begin
          if (pck_ended_reg[i])
            dti_num_en[i] = {qos_stream_en[i][LBB_NUM_TLP_STREAMS-1:0], {LBB_NUM_TLP_STREAMS{1'b0}}};
          else
            dti_num_en[i] = {2*LBB_NUM_TLP_STREAMS{1'b0}};
        end
      end
    end
  endgenerate

  // Flatten dti_num_en[slot][count] to output port using HLSB_2D_TO_WIDE
  // Outer dim = KMAX_NUM_TLPS_PER_CLK+1 slots, inner dim = COUNT_NUMBER groups
  // Transpose and OR with NP path is performed in the parent (hls_bridge_qos).
  generate
    `HLSB_2D_TO_WIDE(dti_num_en_flat, dti_num_en, gen_num_en_flat,
                     (KMAX_NUM_TLPS_PER_CLK+1), COUNT_NUMBER)
  endgenerate

  assign dti_num_en_out = dti_num_en_flat;

endmodule
