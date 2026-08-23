//----------------------------------------------------------------------------
// Sequence: cdn_pcie_hls_bridge_qos_seq  (svn: sequences/cdn_pcie_hls_bridge_qos_seq.sv)
//
// DUT tdata is 24 bits, not the old 18-bit {stream, tlp_type, qos_type, count}.
//   [12:0]  COUNT
//   [13]    TLP_TYPE  0 = Posted, 1 = Non-Posted
//   [16:14] STREAM    idgroup[2:0]
//   [23:17] 0
//
// Do not fork send_compl_qos. Do not pass qos_type.
//----------------------------------------------------------------------------
class cdn_pcie_hls_bridge_qos_seq extends cdn_axi_stream_vip_base_seq;

  int unsigned                   hls_port_num;
  cdn_pcie_hls_bridge_vsequencer m_top_vsqr;

  `uvm_object_utils(cdn_pcie_hls_bridge_qos_seq)

  function new(string name = "cdn_pcie_hls_bridge_qos_seq");
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

  virtual task send_posted_qos();
    cdn_hpa_pcie_tlp tlp_pkt;
    forever begin
      m_top_vsqr.m_hls_ib_posted_qos_tlp_af[hls_port_num].get(tlp_pkt);
      send_qos_packet(.tlp_type(1'b0),
                      .stream  (tlp_pkt.hls_ib_p_np_meta_s.idgroup[2:0]),
                      .count   (13'h1));
    end
  endtask : send_posted_qos

  virtual task send_nonposted_qos();
    cdn_hpa_pcie_tlp tlp_pkt;
    forever begin
      m_top_vsqr.m_hls_ib_nonposted_qos_tlp_af[hls_port_num].get(tlp_pkt);
      send_qos_packet(.tlp_type(1'b1),
                      .stream  (tlp_pkt.hls_ib_p_np_meta_s.idgroup[2:0]),
                      .count   (13'h1));
    end
  endtask : send_nonposted_qos

  // Map bits into PacketData bytes. Do not concat {stream, tlp_type, count}
  // into 17 bits and then slice with the old qos_type PacketData constraints.
  // That left PacketData[2][0] unset (stream[2]=0) and wrote l_tdata[17] into
  // PacketData[1][0] (count[8]), so DUT TX [16:14] became {stream[1:0], type}
  // and NP stream 3 decoded as group 15.
  virtual task send_qos_packet(
    input bit        tlp_type,
    input bit [2:0]  stream,
    input bit [12:0] count = 13'h1
  );
    bit [23:0] l_tdata;

    l_tdata        = '0;
    l_tdata[12:0]  = count;
    l_tdata[13]    = tlp_type;
    l_tdata[16:14] = stream;

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

endclass : cdn_pcie_hls_bridge_qos_seq
