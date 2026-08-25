//----------------------------------------------------------------------------
// Exact monitor QoS fix (keep QOS_MIDTEST_ERR).
//
// tdata: COUNT[12:0] TLP_TYPE[13] TLP_STREAM[14+:3]
// group = tlp_type * S + stream
//
// AXI: qos_ap + expected++. MSI: no qos_ap, expected++ Posted only.
// DTI: no qos_ap, KEEP expected++. Put DTI QoS AFTER the AXI/DTI scoreboard
// if/else, not only inside `ifdef DTI_TB_IN_PASSIVE_MODE / else if DTI.
// 2 NP DTI idgroup 0 in tlp2cxs vs 1 QOS_EXP_DTI was group 8 observed=11
// expected=10.
//----------------------------------------------------------------------------

  function int unsigned qos_group_idx(bit tlp_type, bit [2:0] stream);
    return int'(tlp_type) * parameters_cfg_pkg::LBB_NUM_TLP_STREAMS + int'(stream);
  endfunction : qos_group_idx

  //----- process_hls_ib_posted_hal_pkt_ended --------------------------------
  // ROUTE_TO_MSI: no qos_ap
`ifdef HLSB_QOS_SUPP
  if (parameters_cfg_pkg::LBB_SUPPORT) begin
    int l_group = l_stream;
    m_qos_expected_count[l_group]++;
    `uvm_info("QOS_EXP_MSI",
      $sformatf("MSI -> P group=%0d (stream=%0d); expected=%0d",
        l_group, l_stream, m_qos_expected_count[l_group]), UVM_MEDIUM)
  end
`endif

  // ROUTE_TO_DTI scoreboard stays in DTI_TB_IN_PASSIVE_MODE else-if.
  // QoS expected for Posted DTI: AFTER that if/else, still ROUTE_TO_DTI.
  // no qos_ap.write
`ifdef HLSB_QOS_SUPP
  if (parameters_cfg_pkg::LBB_SUPPORT && (l_route_to == ROUTE_TO_DTI)) begin
    int l_group = l_stream;
    m_qos_expected_count[l_group]++;
    `uvm_info("QOS_EXP_DTI",
      $sformatf("POSTED DTI: stream=%0d P group=%0d expected=%0d",
        l_stream, l_group, m_qos_expected_count[l_group]), UVM_DEBUG)
  end
`endif

  // ROUTE_TO_AXI:
`ifdef HLSB_QOS_SUPP
  if (parameters_cfg_pkg::LBB_SUPPORT) begin
    int l_group = l_stream;
    m_hls_ib_posted_qos_ap[l_hls_port_num].write(hls_ib_posted_hal_tlp_pkt);
    m_qos_expected_count[l_group]++;
    `uvm_info("QOS_EXP_AXI",
      $sformatf("POSTED: port=%0d stream=%0d P group=%0d expected=%0d",
        l_hls_port_num, l_stream, l_group, m_qos_expected_count[l_group]), UVM_DEBUG)
  end
`endif

  //----- process_hls_ib_nonposted_hal_pkt_ended -----------------------------
  // AXI (inside if (l_route_to == ROUTE_TO_AXI)):
`ifdef HLSB_QOS_SUPP
  if (parameters_cfg_pkg::LBB_SUPPORT) begin
    int l_stream = int'(hls_ib_nonposted_hal_tlp_pkt.hls_ib_p_np_meta_s.idgroup[2:0]);
    int l_group  = parameters_cfg_pkg::LBB_NUM_TLP_STREAMS + l_stream;
    m_hls_ib_nonposted_qos_ap[l_hls_port_num].write(hls_ib_nonposted_hal_tlp_pkt);
    m_qos_expected_count[l_group]++;
    `uvm_info("QOS_EXP_AXI",
      $sformatf("NONPOSTED AXI: port=%0d stream=%0d NP group=%0d expected=%0d",
        l_hls_port_num, l_stream, l_group, m_qos_expected_count[l_group]), UVM_DEBUG)
  end
`endif

  // DTI scoreboard: keep write_expected_tr in the existing
  // `ifdef DTI_TB_IN_PASSIVE_MODE else if (ROUTE_TO_DTI) begin ... end
  // REMOVE QoS from inside that else-if.
  //
  // PASTE THIS AFTER the AXI if and the DTI else-if (outside DTI_TB_IN_PASSIVE_MODE):
`ifdef HLSB_QOS_SUPP
  if (parameters_cfg_pkg::LBB_SUPPORT && (l_route_to == ROUTE_TO_DTI)) begin
    int l_stream = int'(hls_ib_nonposted_hal_tlp_pkt.hls_ib_p_np_meta_s.idgroup[2:0]);
    int l_group  = parameters_cfg_pkg::LBB_NUM_TLP_STREAMS + l_stream;
    m_qos_expected_count[l_group]++;
    `uvm_info("QOS_EXP_DTI",
      $sformatf("NONPOSTED DTI: stream=%0d NP group=%0d expected=%0d",
        l_stream, l_group, m_qos_expected_count[l_group]), UVM_DEBUG)
  end
`endif

  // Completions: no HLSB_QOS_SUPP block.
  // process_tlp_qos_tx: keep decode [13] / [14+:3] and KEEP QOS_MIDTEST_ERR.
