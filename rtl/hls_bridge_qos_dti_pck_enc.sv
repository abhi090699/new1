module hls_bridge_qos_dti_pck_enc #(

  /////////////////////////////////////////////////////////////////////////////
  //                                Parameters                               //
  /////////////////////////////////////////////////////////////////////////////
  /*BSF:doc=Maximum number of TLPs supported per clock;*/
  parameter KMAX_NUM_TLPS_PER_CLK      = 4,
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
  // 10-bit DTI metadata: [2:0] VC, [5:3] stream/idgroup
  localparam METADATA_STREAM_ID_LSB    = 3,
  localparam LBB_NUM_TLP_STREAMS_MAX   = 8,
  localparam HLS_HAL_STR_PTR_WD        = $clog2(KMAX_DATAPATH_WD/HLS_DW_ALIGNMENT/32),
  localparam HLS_HAL_END_PTR_WD        = $clog2(KMAX_DATAPATH_WD/32),
  localparam HLS_HAL_PKT_CNTL_WD       = KMAX_NUM_TLPS_PER_CLK*(3+HLS_HAL_STR_PTR_WD+HLS_HAL_END_PTR_WD)
)(
  /*BSF:isClock=1,clock_group="CORE",doc=Core clock;*/
  input  wire                                               core_clk,
  /*BSF:isReset=1,clock=core_clk,doc=Core active-low reset;*/

  input  wire                                               hls_rx_dti_valid,
  input  wire [HLS_DTI_CNTL_WD-1:0]                         hls_rx_dti_cntl,

  // Flat [slot*(COUNT_NUMBER) +: COUNT_NUMBER], slot = 0..K (slot K unused)
  output wire [(KMAX_NUM_TLPS_PER_CLK+1)*COUNT_NUMBER-1:0]  dti_num_en_out
);

  /////////////////////////////////////////////////////////////////////////////
  // In-order slot walk (not SOP<<1 spill, not per-slot armed flags).
  //
  // DTI packs TLPs left-to-right in the K slots. A packet may SOP in slot i
  // and EOP in slot j on a later cycle (possibly a different slot index).
  // Per-slot tracking misses that and the old global spill retired on |eop,
  // which stamped extra NP stream-0 credits.
  //
  // Walk slots 0..K-1:
  //   SOP &  EOP  -> 1 credit, stream from this slot's metadata [5:3]
  //   SOP & ~EOP  -> arm one in-flight packet, latch stream
  //  ~SOP &  EOP  -> if armed, 1 credit with latched stream, then disarm
  //  ~SOP & ~EOP  -> hold (mid-packet beat)
  // Hold arm/stream across valid=0. Do not use slot K.
  /////////////////////////////////////////////////////////////////////////////

  reg                                          spilled_pck_next;
  reg [METADATA_STREAM_ID_WD-1:0]              spilled_pck_stream_id;
  reg                                          spilled_pck_reg;
  reg [METADATA_STREAM_ID_WD-1:0]              spilled_pck_stream_id_reg;
  reg [METADATA_STREAM_ID_WD-1:0]              cntl_metadata_stream_id [KMAX_NUM_TLPS_PER_CLK-1:0];
  reg [METADATA_STREAM_ID_WD-1:0]              dti_stream     [KMAX_NUM_TLPS_PER_CLK-1:0];
  reg [METADATA_STREAM_ID_WD-1:0]              dti_stream_reg [KMAX_NUM_TLPS_PER_CLK:0];
  reg [KMAX_NUM_TLPS_PER_CLK-1:0]              pck_ended_slots;
  reg [KMAX_NUM_TLPS_PER_CLK:0]                pck_ended_reg;
  reg [LBB_NUM_TLP_STREAMS_MAX-1:0]            qos_stream_en  [KMAX_NUM_TLPS_PER_CLK:0];
  reg [COUNT_NUMBER-1:0]                       dti_num_en     [KMAX_NUM_TLPS_PER_CLK:0];

  wire [KMAX_NUM_TLPS_PER_CLK:0]               pck_ended;
  wire [KMAX_NUM_TLPS_PER_CLK-1:0]             cntl_sop;
  wire [KMAX_NUM_TLPS_PER_CLK-1:0]             cntl_eop;
  wire [KMAX_NUM_TLPS_PER_CLK-1:0]             cntl_enderror;
  wire [HLS_HAL_STR_PTR_WD-1:0]                cntl_strptr   [KMAX_NUM_TLPS_PER_CLK-1:0];
  wire [HLS_HAL_END_PTR_WD-1:0]                cntl_endptr   [KMAX_NUM_TLPS_PER_CLK-1:0];
  wire [HLS_METADATA_WD-1:0]                   cntl_metadata [KMAX_NUM_TLPS_PER_CLK-1:0];

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

  generate
    for (gv_x = 0; gv_x < KMAX_NUM_TLPS_PER_CLK; gv_x = gv_x + 1) begin : gen_stream_id
      always @(*) begin : process_cntl_metadata
        if (hls_rx_dti_valid)
          cntl_metadata_stream_id[gv_x] =
              cntl_metadata[gv_x][METADATA_STREAM_ID_LSB +: METADATA_STREAM_ID_WD];
        else
          cntl_metadata_stream_id[gv_x] = {METADATA_STREAM_ID_WD{1'b0}};
      end
    end
  endgenerate

  always @(*) begin : slot_walk
    integer i;
    reg     armed;
    reg [METADATA_STREAM_ID_WD-1:0] armed_sid;

    armed     = spilled_pck_reg;
    armed_sid = spilled_pck_stream_id_reg;

    for (i = 0; i < KMAX_NUM_TLPS_PER_CLK; i = i + 1) begin
      pck_ended_slots[i] = 1'b0;
      dti_stream[i]      = {METADATA_STREAM_ID_WD{1'b0}};
    end

    if (hls_rx_dti_valid) begin
      for (i = 0; i < KMAX_NUM_TLPS_PER_CLK; i = i + 1) begin
        if (cntl_sop[i] && cntl_eop[i]) begin
          pck_ended_slots[i] = 1'b1;
          dti_stream[i]      = cntl_metadata_stream_id[i];
        end
        else if (cntl_sop[i] && !cntl_eop[i]) begin
          armed     = 1'b1;
          armed_sid = cntl_metadata_stream_id[i];
        end
        else if (!cntl_sop[i] && cntl_eop[i] && armed) begin
          pck_ended_slots[i] = 1'b1;
          dti_stream[i]      = armed_sid;
          armed              = 1'b0;
        end
      end
    end

    spilled_pck_next      = armed;
    spilled_pck_stream_id = armed_sid;
  end

  assign pck_ended[KMAX_NUM_TLPS_PER_CLK-1:0] = pck_ended_slots;
  assign pck_ended[KMAX_NUM_TLPS_PER_CLK]     = 1'b0;

  always @(posedge core_clk or negedge core_rst_n) begin : process_seq
    integer i;
    if (core_rst_n == 1'b0) begin
      pck_ended_reg             <= {KMAX_NUM_TLPS_PER_CLK+1{1'b0}};
      spilled_pck_reg           <= 1'b0;
      spilled_pck_stream_id_reg <= {METADATA_STREAM_ID_WD{1'b0}};
      for (i = 0; i <= KMAX_NUM_TLPS_PER_CLK; i = i + 1)
        dti_stream_reg[i]       <= {METADATA_STREAM_ID_WD{1'b0}};
    end
    else if (hls_rx_dti_valid) begin
      pck_ended_reg             <= pck_ended;
      spilled_pck_reg           <= spilled_pck_next;
      spilled_pck_stream_id_reg <= spilled_pck_stream_id;
      for (i = 0; i < KMAX_NUM_TLPS_PER_CLK; i = i + 1)
        dti_stream_reg[i]       <= dti_stream[i];
      dti_stream_reg[KMAX_NUM_TLPS_PER_CLK] <= {METADATA_STREAM_ID_WD{1'b0}};
    end
    else begin
      pck_ended_reg <= {KMAX_NUM_TLPS_PER_CLK+1{1'b0}};
      for (i = 0; i <= KMAX_NUM_TLPS_PER_CLK; i = i + 1)
        dti_stream_reg[i] <= {METADATA_STREAM_ID_WD{1'b0}};
      // Hold spilled_pck_reg / spilled_pck_stream_id_reg across valid=0
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
            dti_num_en[i] = {{LBB_NUM_TLP_STREAMS{1'b0}}, qos_stream_en[i][LBB_NUM_TLP_STREAMS-1:0]};
          else
            dti_num_en[i] = {2*LBB_NUM_TLP_STREAMS{1'b0}};
        end
      end
    end
    else begin : gen_nonposted_encode
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

  generate
    `HLSB_2D_TO_WIDE(dti_num_en_flat, dti_num_en, gen_num_en_flat,
                     (KMAX_NUM_TLPS_PER_CLK+1), COUNT_NUMBER)
  endgenerate

  assign dti_num_en_out = dti_num_en_flat;

endmodule
