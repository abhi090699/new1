# IB QoS TB alignment with `hls_bridge_qos`

Copy these over the TB sources of the same name. Do not patch the DUT DTI encoder.

| File | Use |
|------|-----|
| `tb/cdn_pcie_hls_bridge_qos_stream_seq.sv` | QoS AXI-stream sequence |
| `tb/cdn_pcie_hls_bridge_monitor_qos_ib.sv` | HAL expected / `qos_ap` sites |

Keep `QOS_MIDTEST_ERR`. Do not set `expected = observed`. Do not drop DTI `expected++`.

## DUT tdata

| Bits | Field |
|------|--------|
| `[12:0]` | COUNT |
| `[13]` | TLP_TYPE (`0` Posted, `1` Non-Posted) |
| `[16:14]` | stream |
| `[23:17]` | unused |

`group = tlp_type * S + stream`. Maps sized `LBB_NUM_TLP_STREAMS * 2`.

## HAL expected counts

| Path | `qos_ap` | `expected++` |
|------|----------|----------------|
| AXI Posted / NonPosted | write | yes, `type*S+idgroup` (UIOMRd: DUT UIO stream, not HAL idgroup) |
| MSI Posted | **none** | yes, Posted `stream` only |
| DTI Posted / NonPosted | **none** | **yes**, after AXI/DTI scoreboard if/else; **not** gated on `generated_tlp` |
| Completions | **none** | **no** |

NP DTI: paste `expected++` **after** the AXI `if` and the `ROUTE_TO_DTI` else-if (outside `` `ifdef DTI_TB_IN_PASSIVE_MODE ``). Leave `write_expected_tr` in the else-if. Increment when `generated_tlp` is 0 or 1.

Grep check: `NONPOSTED DTI.*stream=0` `QOS_EXP_DTI` count must match tlp2cxs `ROUTE_TO_DTI` / `pkt_route_info:'h3` with `idgroup=0`.

## UIOMRd

DUT AXI QoS RX uses the UIO stream (this fail: **0**, not HAL `idgroup=7`). Override `idgroup[2:0]` to that stream **before** `qos_ap.write` so `send_qos_packet` follows. Replace `is_uio_mrd()` with the local TLP-type check if the packet class uses another name.

## Sequence pack

```systemverilog
l_tdata = '0;
l_tdata[12:0]  = count;
l_tdata[13]    = tlp_type;
l_tdata[16:14] = stream;
PacketData[2] == l_tdata[23:16];
PacketData[1] == l_tdata[15:8];
PacketData[0] == l_tdata[7:0];
```

Do not use `{stream, tlp_type, count}` with old `PacketData[1][0] == l_tdata[17]`. Do not fork `send_compl_qos`.
