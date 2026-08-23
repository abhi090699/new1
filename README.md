# IB QoS TB alignment with `hls_bridge_qos`

The DUT QoS block no longer uses a 4-way {P/NP} x {REQ/RESP} map or a `qos_type` bit.
Copy these files over the TB sources of the same name.

| File | Use |
|------|-----|
| `tb/cdn_pcie_hls_bridge_qos_stream_seq.sv` | Drop-in replacement for the QoS AXI-stream sequence |
| `tb/cdn_pcie_hls_bridge_monitor_qos_ib.sv` | IB QoS helper + `process_tlp_qos_tx` + comments for the HAL expected-count sites |

## DUT tdata (`TLP_QOS_TDATA_WIDTH = 24`)

| Bits | Field | Meaning |
|------|--------|---------|
| `[12:0]` | COUNT | number of TLPs in this report |
| `[13]` | TLP_TYPE | `0` Posted, `1` Non-Posted |
| `[16:14]` | TLP_STREAM | `idgroup[2:0]` |
| `[23:17]` | unused | 0 |

Counter layout (`COUNT_NUMBER = LBB_NUM_TLP_STREAMS * 2`):

- `[0 .. S-1]` Posted
- `[S .. 2S-1]` Non-Posted
- `group = tlp_type * S + stream`

## What changed vs the old TB

| Path | Old expected groups | New expected group |
|------|---------------------|--------------------|
| AXI Posted | `2S + stream` (P&RESP) | `stream` (Posted) |
| AXI NonPosted | `3S + stream` (NP&RESP) | `S + stream` (Non-Posted) |
| AXI Completion | `S + port` (NP&REQ) | **none** — DUT has no CPL QoS |
| MSI Posted | `stream` **and** `2S + stream` | `stream` only |
| DTI Posted | `stream` **and** `2S + stream` | `stream` only; **do not** write `qos_ap` |
| DTI NonPosted | `S + stream` **and** `3S + stream` | `S + stream` only |

Sequence:

- Pack `{stream, tlp_type, count}` at `[16:0]`. Drop `qos_type`.
- Drive Posted (`tlp_type=0`) and NonPosted (`tlp_type=1`) only. Do not send completion QoS.

Monitor `build_phase` init: `LBB_NUM_TLP_STREAMS * 2` (was `* 4`).

## HAL expected-count snippets

Posted MSI (`ROUTE_TO_MSI`):

```systemverilog
int l_p_group = qos_group_idx(1'b0, 3'(l_stream));
m_qos_expected_count[l_p_group]++;
```

Posted DTI (`ROUTE_TO_DTI`): increment the same P group; do **not** call `m_hls_ib_posted_qos_ap[0].write()`.

Posted AXI (`ROUTE_TO_AXI`): write `m_hls_ib_posted_qos_ap[l_hls_port_num]` then increment the P group.

NonPosted AXI: write `m_hls_ib_nonposted_qos_ap[l_hls_port_num]` then increment `qos_group_idx(1'b1, 3'(l_stream))`.

NonPosted DTI: increment the NP group only.

Completions: delete the `HLSB_QOS_SUPP` block in `process_hls_ib_compl_hal_pkt_ended`.
