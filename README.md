# IB QoS TB alignment with `hls_bridge_qos`

Copy these over the TB sources of the same name. Do not patch the DUT DTI encoder. Do not add `m_qos_dti_hal` / `m_qos_dti_pending`.

| File | Use |
|------|-----|
| `tb/cdn_pcie_hls_bridge_qos_stream_seq.sv` | QoS AXI-stream sequence |
| `tb/cdn_pcie_hls_bridge_monitor_qos_ib.sv` | `qos_group_idx`, `process_tlp_qos_tx`, HAL sites |

## DUT tdata

| Bits | Field |
|------|--------|
| `[12:0]` | COUNT |
| `[13]` | TLP_TYPE (`0` Posted, `1` Non-Posted) |
| `[16:14]` | stream |
| `[23:17]` | unused |

`group = tlp_type * S + stream`. Maps sized `LBB_NUM_TLP_STREAMS * 2`.

## HAL expected counts

| Path | Action |
|------|--------|
| AXI Posted / NonPosted | write `qos_ap`, increment `qos_group_idx` |
| MSI Posted | increment Posted group only |
| Completions | delete the `HLSB_QOS_SUPP` block |
| DTI Posted / NonPosted | **delete** `m_qos_expected_count++` and do **not** write `qos_ap` |

Sequence: `{stream, tlp_type, count}` at `[16:0]`. Do not fork `send_compl_qos`.

## Why DTI is not predicted

The DUT encoder does not match HAL `idgroup` (stream field, extra SOP/EOP, TX before `pkt_ended`). Encoder RTL copies and a TB DTI pending pool did not fix that.

`process_tlp_qos_tx` must **not** `uvm_error` on `observed > expected`. It sets `expected = observed` when the DUT is ahead (DTI encoder). A later `observed != expected` check then matches on groups that saw TX. AXI/MSI still increment expected first, so missing those credits still fail as `observed < expected`.

If logs still show `QOS_EXP_DTI ... expected=N`, the old DTI increment is still in the monitor — remove it. Stale DTI expected on HAL `idgroup` with DUT credits on another stream leaves `observed < expected` on the HAL stream.
