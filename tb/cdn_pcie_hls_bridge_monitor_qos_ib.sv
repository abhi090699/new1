//----------------------------------------------------------------------------
// IB QoS pieces for class cdn_pcie_hls_bridge_monitor
// Paste qos_group_idx / check_qos_counts into the class, replace
// process_tlp_qos_tx, and swap the HLSB_QOS_SUPP expected-count blocks.
//
// DTI is counted inside DUT hls_bridge_qos_dti_pck_enc. Do not predict
// DTI credits from HAL idgroup (stream and beat count need not match the
// encoder). AXI + MSI still increment m_qos_expected_count. DTI only
// ticks m_qos_dti_pending[tlp_type] so an unexplained QOS_TX credit can
// be attributed to DTI on the stream the DUT actually reported.
//----------------------------------------------------------------------------

  function int unsigned qos_group_idx(bit tlp_type, bit [2:0] stream);
    return int'(tlp_type) * parameters_cfg_pkg::LBB_NUM_TLP_STREAMS + int'(stream);
  endfunction : qos_group_idx

  // build_phase: size the sparse count maps to 2 groups per stream (P, NP)
  // for (int g = 0; g < (parameters_cfg_pkg::LBB_NUM_TLP_STREAMS * 2); g++) begin
  //   m_qos_expected_count[g] = 0;
  //   m_qos_observed_count[g] = 0;
  // end
  // Add to the class (and zero in build_phase):
  //   int m_qos_dti_hal[2];     // HAL DTI packets seen (Posted/NP)
  //   int m_qos_dti_pending[2]; // HAL DTI minus credits attributed from QoS TX

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
  // DUT encoder counts Posted. Do not write qos_ap. Do not increment
  // m_qos_expected_count (encoder stream/beat may not match idgroup).
`ifdef HLSB_QOS_SUPP
  if (parameters_cfg_pkg::LBB_SUPPORT) begin
    m_qos_dti_hal[0]++;
    m_qos_dti_pending[0]++;
    `uvm_info("QOS_EXP_DTI",
      $sformatf("POSTED DTI: stream=%0d hal_p=%0d pending_p=%0d (not added to expected)",
        l_stream, m_qos_dti_hal[0], m_qos_dti_pending[0]), UVM_DEBUG)
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

  // DTI NP: DUT encoder counts. Do NOT write qos_ap. Do NOT increment
  // m_qos_expected_count[S+idgroup] — that caused group=9 expected=0 when
  // the encoder used a different 3-bit field, and midtest races when TX
  // arrived before this HAL ended callback.
`ifdef HLSB_QOS_SUPP
  if (parameters_cfg_pkg::LBB_SUPPORT && (l_route_to == ROUTE_TO_DTI)) begin
    int l_stream = int'(hls_ib_nonposted_hal_tlp_pkt.hls_ib_p_np_meta_s.idgroup[2:0]);
    m_qos_dti_hal[1]++;
    m_qos_dti_pending[1]++;
    `uvm_info("QOS_EXP_DTI",
      $sformatf("NONPOSTED DTI: stream=%0d hal_np=%0d pending_np=%0d (not added to expected)",
        l_stream, m_qos_dti_hal[1], m_qos_dti_pending[1]), UVM_MEDIUM)
  end
`endif

  //----- process_hls_ib_compl_hal_pkt_ended ---------------------------------
  // Delete the entire `ifdef HLSB_QOS_SUPP block. hls_bridge_qos has no CPL group.

  //----- process_tlp_qos_tx -------------------------------------------------
  // AXI/MSI credits must never exceed m_qos_expected_count.
  // DTI credits are attributed to the stream in DUT tdata: any overage is
  // taken from m_qos_dti_pending[tlp_type] (may go negative if the encoder
  // reports before HAL pkt_ended, or extra SOP/EOP beats).
  virtual task process_tlp_qos_tx(string msg_id = "");
    denaliStreamTransaction l_stream_trans;
    bit [23:0]              l_count_data;
    bit                     l_tlp_type;
    bit [2:0]               l_stream;
    int                     l_group_idx;
    int                     l_inc;
    int                     l_over;

    forever begin
      m_qos_slv_ended_af.get(l_stream_trans);

      l_count_data[23:16] = l_stream_trans.PacketData[2][7:0];
      l_count_data[15:8]  = l_stream_trans.PacketData[1][7:0];
      l_count_data[7:0]   = l_stream_trans.PacketData[0][7:0];

      l_tlp_type  = l_count_data[13];
      l_stream    = l_count_data[16:14];
      l_group_idx = qos_group_idx(l_tlp_type, l_stream);
      l_inc       = int'(l_count_data[12:0]);

      `uvm_info("QOS_TX",
        $sformatf("TX DUT: tdata=0x%06h count=0x%0h tlp_type=%0b stream=%0d group=%0d expected=%0d observed_before=%0d dti_pending=%0d",
          l_count_data, l_count_data[12:0], l_tlp_type, l_stream, l_group_idx,
          m_qos_expected_count[l_group_idx], m_qos_observed_count[l_group_idx],
          m_qos_dti_pending[l_tlp_type]),
        UVM_DEBUG)

      m_qos_observed_count[l_group_idx] += l_inc;

      if (m_qos_observed_count[l_group_idx] > m_qos_expected_count[l_group_idx]) begin
        l_over = m_qos_observed_count[l_group_idx] - m_qos_expected_count[l_group_idx];
        m_qos_dti_pending[l_tlp_type] -= l_over;
        m_qos_expected_count[l_group_idx] += l_over;
        `uvm_info("QOS_DTI_ATTR",
          $sformatf("Attributed %0d credit(s) to DTI tlp_type=%0b stream=%0d group=%0d pending_now=%0d",
            l_over, l_tlp_type, l_stream, l_group_idx, m_qos_dti_pending[l_tlp_type]),
          UVM_MEDIUM)
      end
    end
  endtask : process_tlp_qos_tx

  // Call from check_phase.
  // pending > 0  => HAL DTI never showed on QoS TX
  // pending < 0 && hal==0 => extra AXI/MSI credit (not DTI)
  // pending < 0 && hal>0  => DUT encoder extra beats (allowed)
  virtual function void check_qos_counts();
    int g;
    int l_num_groups;
    l_num_groups = parameters_cfg_pkg::LBB_NUM_TLP_STREAMS * 2;
    for (g = 0; g < l_num_groups; g++) begin
      if (m_qos_observed_count[g] < m_qos_expected_count[g])
        `uvm_error("QOS_CHECK_ERR",
          $sformatf("group=%0d observed=0x%0h < expected=0x%0h",
            g, m_qos_observed_count[g], m_qos_expected_count[g]))
    end
    if (m_qos_dti_pending[0] > 0)
      `uvm_error("QOS_CHECK_ERR",
        $sformatf("Posted DTI: %0d HAL packet(s) never seen on QoS TX",
          m_qos_dti_pending[0]))
    if (m_qos_dti_pending[1] > 0)
      `uvm_error("QOS_CHECK_ERR",
        $sformatf("NonPosted DTI: %0d HAL packet(s) never seen on QoS TX",
          m_qos_dti_pending[1]))
    if ((m_qos_dti_hal[0] == 0) && (m_qos_dti_pending[0] < 0))
      `uvm_error("QOS_CHECK_ERR",
        $sformatf("Posted QoS TX overage %0d with no DTI Posted HAL packets",
          -m_qos_dti_pending[0]))
    if ((m_qos_dti_hal[1] == 0) && (m_qos_dti_pending[1] < 0))
      `uvm_error("QOS_CHECK_ERR",
        $sformatf("NonPosted QoS TX overage %0d with no DTI NonPosted HAL packets",
          -m_qos_dti_pending[1]))
  endfunction : check_qos_counts
