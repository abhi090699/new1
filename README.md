# IB QoS TB alignment with `hls_bridge_qos`

The DUT QoS block no longer uses a 4-way {P/NP} x {REQ/RESP} map or a `qos_type` bit.
Copy these files over the TB sources of the same name. **Do not patch the DUT DTI encoder.**

| File | Use |
|------|-----|
| `tb/cdn_pcie_hls_bridge_qos_stream_seq.sv` | Drop-in replacement for the QoS AXI-stream sequence |
| `tb/cdn_pcie_hls_bridge_monitor_qos_ib.sv` | IB QoS helper + `process_tlp_qos_tx` + HAL sites |

## DUT tdata (`TLP_QOS_TDATA_WIDTH = 24`)

| Bits | Field | Meaning |
|------|--------|---------|
| `[12:0]` | COUNT | number of TLPs in this report |
| `[13]` | TLP_TYPE | `0` Posted, `1` Non-Posted |
| `[16:14]` | TLP_STREAM | stream |
| `[23:17]` | unused | 0 |

Counter layout (`COUNT_NUMBER = LBB_NUM_TLP_STREAMS * 2`):

- `[0 .. S-1]` Posted
- `[S .. 2S-1]` Non-Posted
- `group = tlp_type * S + stream`

## What changed vs the old TB

| Path | Old expected groups | New expected group |
|------|---------------------|--------------------|
| AXI Posted | `2S + stream` (P&RESP) | `stream` (Posted); write `qos_ap` |
| AXI NonPosted | `3S + stream` (NP&RESP) | `S + stream`; write `qos_ap` |
| AXI Completion | `S + port` (NP&REQ) | **none** |
| MSI Posted | `stream` **and** `2S + stream` | `stream` only |
| DTI Posted / NonPosted | per-stream expected from HAL idgroup | **do not** write `qos_ap`; **do not** increment `m_qos_expected_count` |

Sequence: pack `{stream, tlp_type, count}` at `[16:0]`. No `qos_type`. No `send_compl_qos`.

Monitor `build_phase`: maps `* 2` (was `* 4`). Also zero `m_qos_dti_hal[2]` and `m_qos_dti_pending[2]`.

## DTI is scoreboarded in the TB, not by patching the encoder

`hls_bridge_qos_dti_pck_enc` reports on its own stream/beat rules. Predicting `S+idgroup` at HAL `pkt_ended` missed those reports (`group=9 expected=0`) and extra SOP/EOP beats (`group=8 observed=6 expected=1`), and raced when QoS TX arrived first.

Instead:

1. Add `int m_qos_dti_hal[2]` and `int m_qos_dti_pending[2]` to the monitor class.
2. On HAL `ROUTE_TO_DTI`, increment both for Posted (`[0]`) or NP (`[1]`). Do not touch `m_qos_expected_count`.
3. Replace `process_tlp_qos_tx`: drop `QOS_MIDTEST_ERR`. If observed would exceed AXI/MSI expected, attribute the overage to DTI on the **stream in DUT tdata** (`m_qos_dti_pending[tlp_type] -= over`, fold into `m_qos_expected_count[group]`).
4. Call `check_qos_counts()` from `check_phase` (and remove any `observed != expected` loop, or keep it — after attribution they match per group).
5. Leave the DUT encoder as-is.

`check_qos_counts` still fails if AXI/MSI credits are missing, if HAL DTI never appears on QoS TX (`pending > 0`), or if QoS TX overages occur with **no** DTI HAL packets of that type (`hal==0 && pending<0`). Extra encoder beats with real DTI traffic (`hal>0 && pending<0`) are allowed.

Completions: delete the `HLSB_QOS_SUPP` block in `process_hls_ib_compl_hal_pkt_ended`.
