//----------------------------------------------------------------------------
// Sequence: cdn_pcie_hls_bridge_qos_stream_seq
//
// Drives AXI QoS RX credits to match hls_bridge_qos / hls_bridge_qos_counter.
//
// DUT tdata (TLP_QOS_TDATA_WIDTH = 24):
//   [12:0]  COUNT
//   [13]    TLP_TYPE  0 = Posted, 1 = Non-Posted
//   [16:14] TLP_STREAM (idgroup[2:0])
//   [23:17] unused (tied 0)
//
// There is no qos_type / REQ vs RESP bit. Completions are not a QoS
// source on this interface (DUT groups are only P and NP).
//----------------------------------------------------------------------------
class cdn_pcie_hls_bridge_qos_stream_seq extends cdn_axi_stream_vip_base_seq;

  int unsigned                   hls_port_num;
  cdn_pcie_hls_bridge_vsequencer m_top_vsqr;

  `uvm_object_utils(cdn_pcie_hls_bridge_qos_stream_seq)

  function new(string name = "cdn_pcie_hls_bridge_qos_stream_seq");
    super.new(name);
  endfunction : new

  virtual task body();
    `uvm_info(get_type_name(), $sformatf("Starting QOS Stream Seq for port %0d", hls_port_num), UVM_DEBUG)
    fork
      send_posted_qos();
      send_nonposted_qos();
    join
    `uvm_info(get_type_name(), $sformatf("Ending QOS Stream Seq for port %0d", hls_port_num), UVM_DEBUG)
  endtask : body

  //--------------------------------------------------------------------
  // Posted QOS — TLP_TYPE = 0
  //--------------------------------------------------------------------
  virtual task send_posted_qos();
    cdn_hpa_pcie_tlp tlp_pkt;
    forever begin
      m_top_vsqr.m_hls_ib_posted_qos_tlp_af[hls_port_num].get(tlp_pkt);

      `uvm_info(get_type_name(),
        $sformatf("QOS Posted: port=%0d stream=%0d",
          hls_port_num, tlp_pkt.hls_ib_p_np_meta_s.idgroup[2:0]),
        UVM_DEBUG)

      send_qos_packet(.tlp_type(1'b0),
                      .stream  (tlp_pkt.hls_ib_p_np_meta_s.idgroup[2:0]),
                      .count   (13'h1));
    end
  endtask : send_posted_qos

  //--------------------------------------------------------------------
  // NonPosted QOS — TLP_TYPE = 1
  //--------------------------------------------------------------------
  virtual task send_nonposted_qos();
    cdn_hpa_pcie_tlp tlp_pkt;
    forever begin
      m_top_vsqr.m_hls_ib_nonposted_qos_tlp_af[hls_port_num].get(tlp_pkt);

      `uvm_info(get_type_name(),
        $sformatf("QOS NonPosted: port=%0d stream=%0d",
          hls_port_num, tlp_pkt.hls_ib_p_np_meta_s.idgroup[2:0]),
        UVM_DEBUG)

      send_qos_packet(.tlp_type(1'b1),
                      .stream  (tlp_pkt.hls_ib_p_np_meta_s.idgroup[2:0]),
                      .count   (13'h1));
    end
  endtask : send_nonposted_qos

  //--------------------------------------------------------------------
  // send_qos_packet — packs AXI QoS RX tdata to match hls_bridge_qos
  //   [16:14]=stream  [13]=tlp_type  [12:0]=count
  //--------------------------------------------------------------------
  virtual task send_qos_packet(
    input bit        tlp_type,
    input bit [2:0]  stream,
    input bit [12:0] count = 13'h1
  );
    bit [23:0] l_tdata;

    l_tdata         = '0;
    l_tdata[12:0]   = count;
    l_tdata[13]     = tlp_type;
    l_tdata[16:14]  = stream;

    `uvm_info(get_type_name(),
      $sformatf("Sending QOS packet: tlp_type=%0b stream=%0d count=0x%0h tdata=0x%06h",
        tlp_type, stream, count, l_tdata),
      UVM_DEBUG)

    fork
      begin
        stream_trans = denaliStreamTransaction::type_id::create("stream_trans");
        start_item(.item(stream_trans), .sequencer(p_sequencer));
        if (!stream_trans.randomize() with {
          stream_trans.StreamKind   == DENALI_STREAM_KIND_BYTE;
          stream_trans.DataBusSize  == databus_size_bytes;
          stream_trans.Length       == 1;
          stream_trans.ChannelDelay == 'd0;
          stream_trans.TransfersChannelDelay.size() == stream_trans.Length;
          foreach (stream_trans.TransfersChannelDelay[i]) {
            stream_trans.TransfersChannelDelay[i] == 0;
          }
          stream_trans.PacketData[2][7:0] == l_tdata[23:16];
          stream_trans.PacketData[1][7:0] == l_tdata[15:8];
          stream_trans.PacketData[0][7:0] == l_tdata[7:0];
        }) begin
          `uvm_fatal(get_type_name(), "QOS Stream Transaction Randomization failed...")
        end
        finish_item(stream_trans);
      end
      begin
        get_response(stream_trans);
      end
    join
  endtask : send_qos_packet

endclass : cdn_pcie_hls_bridge_qos_stream_seq
