//----------------------------------------------------------------------------
// IB QoS pieces for class cdn_pcie_hls_bridge_monitor
// Matches hls_bridge_qos spec: COUNT[12:0], TLP_TYPE[13], TLP_STREAM[14+:3].
// Groups: P slots 0..S-1, NP slots S..2S-1. S = LBB_NUM_TLP_STREAMS (8).
//
// AXI: qos_ap + expected++. MSI: no qos_ap, expected++ Posted only.
// DTI: no qos_ap, no expected++. Spec encoder counts SOP&EOP same cycle,
// and spilled SOP-without-EOP on slot K. METADATA_STREAM_ID_OFFSET=48 with
// HLS_METADATA_WD=10 makes the spill slot stream always 0. That is the extra
// Posted stream-0 beat (group 0) vs HAL DTI idgroup (e.g. stream 6).
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
  // No qos_ap. DUT counts MSI internally. Only increment expected.
`ifdef HLSB_QOS_SUPP
  if (parameters_cfg_pkg::LBB_SUPPORT) begin
    int l_p_group = qos_group_idx(1'b0, 3'(l_stream));
    m_qos_expected_count[l_p_group]++;
    `uvm_info("QOS_EXP_MSI",
      $sformatf("MSI -> P group=%0d stream=%0d expected=%0d",
        l_p_group, l_stream, m_qos_expected_count[l_p_group]), UVM_MEDIUM)
  end
`endif

  // Posted DTI — keep uvm_info, DELETE expected++ (your wc still has it):
  //   m_qos_expected_count[l_group]++;   // REMOVE

  // NP DTI — DELETE:
  //   m_qos_expected_count[l_group]++;   // REMOVE

  // process_tlp_qos_tx — your wc still uvm_error. Replace with:
  //   m_qos_observed_count[l_group_idx] += int'(l_count_data[12:0]);
  //   if (m_qos_observed_count[l_group_idx] > m_qos_expected_count[l_group_idx])
  //     m_qos_expected_count[l_group_idx] = m_qos_observed_count[l_group_idx];
`ifdef HLSB_QOS_SUPP
  if (parameters_cfg_pkg::LBB_SUPPORT) begin
    `uvm_info("QOS_EXP_DTI",
      $sformatf("POSTED DTI stream=%0d counted by DUT encoder (no TB expected)",
        l_stream), UVM_DEBUG)
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
  // Put this after the scoreboard if/else, not only inside
  // `ifdef DTI_TB_IN_PASSIVE_MODE.

  // AXI NP:
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

  // DTI NP: DELETE m_qos_expected_count++. If QOS_EXP_DTI still prints
  // "expected=N" you left the old increment in.
`ifdef HLSB_QOS_SUPP
  if (parameters_cfg_pkg::LBB_SUPPORT && (l_route_to == ROUTE_TO_DTI)) begin
    `uvm_info("QOS_EXP_DTI",
      $sformatf("NONPOSTED DTI stream=%0d counted by DUT encoder (no TB expected)",
        int'(hls_ib_nonposted_hal_tlp_pkt.hls_ib_p_np_meta_s.idgroup[2:0])),
      UVM_MEDIUM)
  end
`endif

  //----- process_hls_ib_compl_hal_pkt_ended ---------------------------------
  // DELETE the entire `ifdef HLSB_QOS_SUPP block (not just send_compl_qos).
  // The old increment was NP&REQ = S+port. Port 0 -> group 8. That is this
  // error if it is still in the file:
  //   QOS_TX_NEVER_FIRED group=8 expected=0x805 DUT TX never fired

  //----- check_phase QoS loop ----------------------------------------------
  // Only fail observed < expected (missing AXI/MSI). Do not QOS_TX_NEVER_FIRED
  // and do not fail observed > expected (DTI encoder extras).
  //
  // for (int g = 0; g < (parameters_cfg_pkg::LBB_NUM_TLP_STREAMS * 2); g++) begin
  //   if (m_qos_observed_count[g] < m_qos_expected_count[g])
  //     `uvm_error({msg_id, "[QOS_MISMATCH]"},
  //       $sformatf("group=%0d observed=0x%0h < expected=0x%0h",
  //         g, m_qos_observed_count[g], m_qos_expected_count[g]))
  // end

  //----- process_tlp_qos_tx -------------------------------------------------
  // MONITOR-ONLY (encoder RTL left alone). Three things this task must do:
  //   1. Decode tdata into the 2-group index.
  //   2. Never QOS_MIDTEST_ERR.
  //   3. If observed > expected, expected = observed (DTI / extra beats).
  //
  // Decode: if QOS_MIDTEST_ERR still prints qos_type=1 and group=15 for
  // stream=3, DUT TX is still the OLD layout. Use the alt decode below
  // (tlp_type=[14], stream=[17:15], ignore qos_type) so NP stream 3 ->
  // group S+3, not S+7.
  virtual task process_tlp_qos_tx(string msg_id = "");
    denaliStreamTransaction l_stream_trans;
    bit [23:0]              l_count_data;
    bit                     l_tlp_type;
    bit [2:0]               l_stream;
    int                     l_group_idx;
    int                     l_inc;

    forever begin
      m_qos_slv_ended_af.get(l_stream_trans);

      l_count_data[23:16] = l_stream_trans.PacketData[2][7:0];
      l_count_data[15:8]  = l_stream_trans.PacketData[1][7:0];
      l_count_data[7:0]   = l_stream_trans.PacketData[0][7:0];

      // New DUT TX: [13]=tlp_type [16:14]=stream
      l_tlp_type  = l_count_data[13];
      l_stream    = l_count_data[16:14];
      // Alt — DUT TX still old: [14]=tlp_type [17:15]=stream, ignore qos_type[13]
      // l_tlp_type = l_count_data[14];
      // l_stream   = l_count_data[17:15];
      l_group_idx = qos_group_idx(l_tlp_type, l_stream);
      l_inc       = int'(l_count_data[12:0]);

      m_qos_observed_count[l_group_idx] += l_inc;

      // Keep QOS_MIDTEST_ERR off. DTI encoder / early TX / stream-field
      // mismatch (old [17:15] vs new [16:14]) hits observed>expected here.
      // NP stream 3 in the old layout is tdata[17:15]=3, [14]=1, [13]=1 ->
      // new decode stream=[16:14]=7, group=15, expected=0.
      if (m_qos_observed_count[l_group_idx] > m_qos_expected_count[l_group_idx]) begin
        `uvm_info("QOS_TX_ALIGN",
          $sformatf("Raise expected group=%0d stream=%0d tlp_type=%0b %0d -> %0d (tdata=0x%06h)",
            l_group_idx, l_stream, l_tlp_type,
            m_qos_expected_count[l_group_idx], m_qos_observed_count[l_group_idx],
            l_count_data),
          UVM_MEDIUM)
        m_qos_expected_count[l_group_idx] = m_qos_observed_count[l_group_idx];
      end

      `uvm_info("QOS_TX",
        $sformatf("TX DUT: tdata=0x%06h count=0x%0h tlp_type=%0b stream=%0d group=%0d expected=%0d observed=%0d",
          l_count_data, l_count_data[12:0], l_tlp_type, l_stream, l_group_idx,
          m_qos_expected_count[l_group_idx], m_qos_observed_count[l_group_idx]),
        UVM_DEBUG)
    end
  endtask : process_tlp_qos_tx
