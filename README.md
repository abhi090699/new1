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

| Path | `qos_ap` | `expected++` |
|------|----------|----------------|
| AXI Posted / NonPosted | write | yes, `type*S+idgroup` |
| MSI Posted | **none** | yes, Posted `stream` only |
| DTI Posted / NonPosted | **none** | **no** (encoder ≠ HAL) |
| Completions | **none** | **no** |

Sequence: build a 24-bit `l_tdata` with those fields, then copy bytes:

```systemverilog
l_tdata = '0;
l_tdata[12:0]  = count;
l_tdata[13]    = tlp_type;
l_tdata[16:14] = stream;
PacketData[2] == l_tdata[23:16];
PacketData[1] == l_tdata[15:8];
PacketData[0] == l_tdata[7:0];
```

Do not use `l_tdata = {stream, tlp_type, count}` with the old `PacketData[1][0] == l_tdata[17]` constraints. That is this error:

`QOS_MIDTEST_ERR group=15 stream=3 tlp_type=1 qos_type=1 observed=0x1 > expected=0x0`

Old layout NP RESP stream 3 is `{[17:15]=3,[14]=1,[13]=1}`. New decode uses `[16:14]`, which becomes `7`, group `S+7=15`. Also delete DTI `m_qos_expected_count++` and delete `QOS_MIDTEST_ERR` (raise expected to observed). Do not fork `send_compl_qos`.

## Why DTI is not predicted

The DUT encoder does not match HAL `idgroup` (stream field, extra SOP/EOP, TX before `pkt_ended`). Encoder RTL copies and a TB DTI pending pool did not fix that.

`process_tlp_qos_tx` must **not** `uvm_error` on `observed > expected`. It sets `expected = observed` when the DUT is ahead (DTI encoder). A later `observed != expected` check then matches on groups that saw TX. AXI/MSI still increment expected first, so missing those credits still fail as `observed < expected`.

If logs still show `QOS_EXP_DTI ... expected=N`, the old DTI increment is still in the monitor — remove it.

## Monitor-only options if encoder RTL is left alone

Do not predict DTI from HAL. Pick one TX decode, absorb extras, only check AXI/MSI undercount.

| Fix | When to use |
|-----|-------------|
| 1. Delete DTI `expected++`, no `qos_ap` | Encoder stream/beats ≠ HAL `idgroup` |
| 2. Delete `QOS_MIDTEST_ERR`; `expected = observed` on overage | Encoder extras or TX before HAL ended |
| 3. `check_phase`: fail only `observed < expected` | Leftover completion/DTI expected (`QOS_TX_NEVER_FIRED group=8`) |
| 4. Alt TX decode: `tlp_type=[14]`, `stream=[17:15]`, ignore `qos_type` | DUT TX still old 18-bit layout (`group=15` for NP stream 3) |
| 5. Do **not** `qos_ap.write` for DTI | That doubles DUT count (AXI slave + encoder) |

Do not fork `send_compl_qos`. Completions have no DUT group.

## `QOS_TX_NEVER_FIRED group=8 expected=0x805`

Group 8 is NP stream 0 (`S+0`). `check_phase` fires this when `expected != 0` and the DUT never sent QoS TX for that group.

That expected is leftover, not a missing DUT report:

- Completions used to increment `S+port` (NP&REQ). Port 0 is group 8. Removing `send_compl_qos` is not enough — **delete the whole `HLSB_QOS_SUPP` block in `process_hls_ib_compl_hal_pkt_ended`**.
- DTI used to increment `S+idgroup`. Stream 0 is also group 8. **Delete that increment.**

Then change the `check_phase` QoS loop: **do not** `QOS_TX_NEVER_FIRED` when `observed == 0`. Skip those groups. Only compare groups the DUT actually reported. See the snippet in `tb/cdn_pcie_hls_bridge_monitor_qos_ib.sv`.
