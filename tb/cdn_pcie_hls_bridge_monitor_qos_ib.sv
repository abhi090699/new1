//----------------------------------------------------------------------------
// IB QoS pieces for class cdn_pcie_hls_bridge_monitor
// Paste qos_group_idx into the class, replace process_tlp_qos_tx, and
// swap the HLSB_QOS_SUPP expected-count blocks as shown below.
//----------------------------------------------------------------------------

  function int unsigned qos_group_idx(bit tlp_type, bit [2:0] stream);
    return int'(tlp_type) * parameters_cfg_pkg::LBB_NUM_TLP_STREAMS + int'(stream);
  endfunction : qos_group_idx

  // build_phase: size the sparse count maps to 2 groups per stream (P, NP)
  // for (int g = 0; g < (parameters_cfg_pkg::LBB_NUM_TLP_STREAMS * 2); g++) begin
  //   m_qos_expected_count[g] = 0;
  //   m_qos_observed_count[g] = 0;
  // end

  //----- process_hls_ib_posted_hal_pkt_ended --------------------------------
  // MSI (`ifdef HLSB_QOS_SUPP` inside ROUTE_TO_MSI):
`ifdef HLSB_QOS_SUPP
  if (parameters_cfg_pkg::LBB_SUPPORT) begin
    int l_p_group = qos_group_idx(1'b0, 3'(l_stream));
    m_qos_expected_count[l_p_group]++;
    `uvm_info("QOS_EXP_MSI",
      $sformatf("MSI Posted -> group=%0d stream=%0d expected=%0d",
        l_p_group, l_stream, m_qos_expected_count[l_p_group]), UVM_MEDIUM)
  end
`endif

  // DTI (`ifdef HLSB_QOS_SUPP` inside ROUTE_TO_DTI):
  // DUT hls_bridge_qos_dti_pck_enc counts Posted internally — do not write qos_ap.
`ifdef HLSB_QOS_SUPP
  if (parameters_cfg_pkg::LBB_SUPPORT) begin
    int l_p_group = qos_group_idx(1'b0, 3'(l_stream));
    m_qos_expected_count[l_p_group]++;
    `uvm_info("QOS_EXP_DTI",
      $sformatf("POSTED DTI: stream=%0d P group=%0d expected=%0d",
        l_stream, l_p_group, m_qos_expected_count[l_p_group]), UVM_DEBUG)
  end
`endif

  // AXI (`ifdef HLSB_QOS_SUPP` inside ROUTE_TO_AXI):
`ifdef HLSB_QOS_SUPP
  if (parameters_cfg_pkg::LBB_SUPPORT) begin
    int l_p_group = qos_group_idx(1'b0, 3'(l_stream));
    m_hls_ib_posted_qos_ap[l_hls_port_num].write(hls_ib_posted_hal_tlp_pkt);
    m_qos_expected_count[l_p_group]++;
    `uvm_info("QOS_EXP_AXI",
      $sformatf("POSTED AXI: port=%0d stream=%0d group=%0d expected=%0d",
        l_hls_port_num, l_stream, l_p_group, m_qos_expected_count[l_p_group]), UVM_DEBUG)
  end
`endif

  //----- process_hls_ib_nonposted_hal_pkt_ended -----------------------------
  //
  // group=9 stream=1 expected=0 is this block. DUT NP DTI counts internally
  // (IS_POSTED=0 -> group S+stream). The old TB did:
  //   m_qos_expected_count[1*S + stream]++;  // NP&REQ  == 2-group NP (KEEP)
  //   m_qos_expected_count[3*S + stream]++;  // NP&RESP == unused now (DELETE)
  // If you deleted the first line or left only 3*S, QOS_TX group 9 sees expected=0.
  //
  // Put DTI QoS *after* the scoreboard if/else, not only inside
  // `ifdef DTI_TB_IN_PASSIVE_MODE / else if (ROUTE_TO_DTI).

  // AXI NP (sequence drives AXI QoS RX):
`ifdef HLSB_QOS_SUPP
  if (parameters_cfg_pkg::LBB_SUPPORT && (l_route_to == ROUTE_TO_AXI)) begin
    int l_stream   = int'(hls_ib_nonposted_hal_tlp_pkt.hls_ib_p_np_meta_s.idgroup[2:0]);
    int l_np_group = qos_group_idx(1'b1, 3'(l_stream)); // S + stream  (NOT 3*S)
    m_hls_ib_nonposted_qos_ap[l_hls_port_num].write(hls_ib_nonposted_hal_tlp_pkt);
    m_qos_expected_count[l_np_group]++;
    `uvm_info("QOS_EXP_AXI",
      $sformatf("NONPOSTED AXI: port=%0d stream=%0d group=%0d expected=%0d",
        l_hls_port_num, l_stream, l_np_group, m_qos_expected_count[l_np_group]), UVM_MEDIUM)
  end
`endif

  // DTI NP (DUT encoder counts; do NOT write qos_ap; DO increment expected):
`ifdef HLSB_QOS_SUPP
  if (parameters_cfg_pkg::LBB_SUPPORT && (l_route_to == ROUTE_TO_DTI)) begin
    int l_stream   = int'(hls_ib_nonposted_hal_tlp_pkt.hls_ib_p_np_meta_s.idgroup[2:0]);
    int l_np_group = qos_group_idx(1'b1, 3'(l_stream)); // S + stream  (NOT 3*S)
    m_qos_expected_count[l_np_group]++;
    `uvm_info("QOS_EXP_DTI",
      $sformatf("NONPOSTED DTI: stream=%0d group=%0d expected=%0d",
        l_stream, l_np_group, m_qos_expected_count[l_np_group]), UVM_MEDIUM)
  end
`endif

  //----- process_hls_ib_compl_hal_pkt_ended ---------------------------------
  // Delete the entire `ifdef HLSB_QOS_SUPP block. hls_bridge_qos has no CPL group.

  //----- process_tlp_qos_tx -------------------------------------------------
  virtual task process_tlp_qos_tx(string msg_id = "");
    string                  l_msg_id = {msg_id, "[process_tlp_qos_tx]"};
    denaliStreamTransaction l_stream_trans;
    bit [23:0]              l_count_data;
    bit                     l_tlp_type;
    bit [2:0]               l_stream;
    int                     l_group_idx;

    forever begin
      m_qos_slv_ended_af.get(l_stream_trans);

      l_count_data[23:16] = l_stream_trans.PacketData[2][7:0];
      l_count_data[15:8]  = l_stream_trans.PacketData[1][7:0];
      l_count_data[7:0]   = l_stream_trans.PacketData[0][7:0];

      l_tlp_type  = l_count_data[13];
      l_stream    = l_count_data[16:14];
      l_group_idx = qos_group_idx(l_tlp_type, l_stream);

      `uvm_info("QOS_TX",
        $sformatf("TX DUT: tdata=0x%06h count=0x%0h tlp_type=%0b stream=%0d group=%0d expected=%0d observed_before=%0d",
          l_count_data, l_count_data[12:0], l_tlp_type, l_stream, l_group_idx,
          m_qos_expected_count[l_group_idx], m_qos_observed_count[l_group_idx]),
        UVM_DEBUG)

      m_qos_observed_count[l_group_idx] += int'(l_count_data[12:0]);

      if (m_qos_observed_count[l_group_idx] > m_qos_expected_count[l_group_idx])
        `uvm_error({l_msg_id, "[QOS_MIDTEST_ERR]"},
          $sformatf("group=%0d stream=%0d tlp_type=%0b observed=0x%0h > expected=0x%0h",
            l_group_idx, l_stream, l_tlp_type,
            m_qos_observed_count[l_group_idx], m_qos_expected_count[l_group_idx]))
    end
  endtask : process_tlp_qos_tx
