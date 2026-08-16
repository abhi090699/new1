# DENALI_CXS_ERR018: `CXS_ACTIVE_ACK_TX` asserted in STOP

## Observed error

```
UVM_ERROR .../ddvapi/sv/uvm/cxs/cdnCxsUvmMonitor.sv(548) @ 502500:
uvm_test_top.sve.m_hls_ib_nonposted_hal_env.cxs_env.act_agent.monitor
[DENALI_CXS_ERR018_WRONG_ACK_RX_ASSERTION_WHILE_IN_STOP_STATE]
The CXS_ACTIVE_ACK_TX signal was asserted while the interface is in the STOP state.
DEBUG_HINT: The CXS_ACTIVE_ACK_TX signal must be deasserted when the interface is in the STOP state.
[direction: TRX][spec: CXS bus specification]
```

| Field | Value |
| --- | --- |
| Checker | Cadence Denali CXS UVM monitor (`cdnCxsUvmMonitor.sv`, line 548) |
| ID | `DENALI_CXS_ERR018_WRONG_ACK_RX_ASSERTION_WHILE_IN_STOP_STATE` |
| Time | `502500` (not reset/time-0; mid-sim after traffic) |
| Env | `m_hls_ib_nonposted_hal_env.cxs_env.act_agent` |
| Direction | `TRX` (VIP TX channel; DUT is the receiver of that channel) |

The ID says `ACK_RX` because the monitor is checking the **ACK received from the RX side**. The message names `CXS_ACTIVE_ACK_TX` because that is the TX-channel ACK pin (`*_ACK_TX` is driven **by the DUT**, not by the VIP).

This is a **DUT / HAL protocol violation**, not a VIP CAT install-path issue. The VIP already believes the TX link is in **STOP**. On that cycle it sampled `CXS_ACTIVE_ACK_TX == 1`.

## Protocol rule (AMBA CXS link control)

`CXSACTIVEREQ` / `CXSACTIVEACK` are a four-phase handshake. Legal states:

| State | REQ | ACK | Who initiates |
| --- | --- | --- | --- |
| STOP | 0 | 0 | stable idle; all credits at the receiver |
| ACTIVATE | 1 | 0 | transmitter raises REQ |
| RUN | 1 | 1 | receiver raises ACK |
| DEACTIVATE | 0 | 1 | transmitter drops REQ; receiver holds ACK until credits are back |

The transmitter **always** starts STOP↔RUN. The receiver must **not** raise ACK while the local view of the link is STOP (`REQ==0` and ACK already 0).

Legal edges:

```
STOP --REQ↑--> ACTIVATE --ACK↑--> RUN --REQ↓--> DEACTIVATE --ACK↓--> STOP
```

Illegal (this checker):

```
STOP --ACK↑-->  (receiver-initiated; there is no STOP → DEACTIVATE path)
```

Also illegal: ACK glitch HIGH for one cycle after DEACTIVATE has already completed (`ACK` already fallen).

STOP constraints that usually fail together with this check:

- `CXSVALID` / flits must be quiet
- `CXSCRDGNT` must be quiet (receiver holds all credits)
- `CXSACTIVEACK` must stay 0 until the next `CXSACTIVEREQ` rise

## What the hierarchy tells you

`m_hls_ib_nonposted_hal_env` is the VIPCAT HLS inbound non-posted HAL wrapping a CXS active agent. For `direction: TRX`:

- VIP drives `CXS_ACTIVE_REQ_TX`, `CXSVALID_TX`, data/cntl
- DUT/HAL drives `CXS_ACTIVE_ACK_TX`, `CXSCRDGNT_TX`

So at `502500` the **DUT (or HAL glue)** drove ACK high while the VIP TX FSM was already in STOP.

Inbound non-posted traffic is often bursty: the VIP TX path goes RUN → DEACTIVATE → STOP when there are no more NP flits, then later re-activates. The failure is almost always on **that deactivate/idle window**, not on first bring-up.

## Most likely causes (ranked)

1. **ACK re-asserted after STOP was reached**  
   DUT drops ACK (credits look returned), VIP enters STOP, then a late credit/flit/sideband event raises ACK again while REQ is still 0.

2. **ACK is not a 4-phase slave of REQ**  
   Combinational or “always ready” logic, for example:
   - `ack <= 1'b1` after reset
   - `ack <= ~reset`
   - `ack <= credit_avail`
   - `ack <= !deact_hint`
   - ACK of the **RX** channel wired onto `CXS_ACTIVE_ACK_TX`

3. **One-cycle late ACK drop (or pulse)**  
   DUT leaves DEACTIVATE one cycle after the VIP has already counted STOP (sampling / extra pipeline on ACK). Less common if clocks are shared; common with extra HAL registering.

4. **Clock-gate / reset on the ACK path**  
   CXS allows the **receiver clock** to stop in STOP; `CXSACTIVEREQ` may be combinational to wake it. `CXSACTIVEACK` must stay a **synchronous** 0 in STOP. Gating, X-prop, or a flop that comes out of gate as 1 will fire ERR018.

5. **Credit-return race treated as “go active”**  
   Spec race: flits/credits in flight during DEACTIVATE. DUT must **keep ACK high** until every credit is back, then drop it **once** and leave it low. Dropping ACK early and then raising it again to “finish” credits is exactly this error.

## Waveform checklist at `502500`

Plot on the **same clock the monitor uses** (`CXSCLK` of this agent):

- `CXS_ACTIVE_REQ_TX`
- `CXS_ACTIVE_ACK_TX`  ← must be 0 for the entire STOP occupancy
- `CXSDEACTHINT` (if present)
- `CXSVALID_TX`, `CXSCNTL_TX`
- `CXSCRDGNT_TX`, `CXSCRDRTN_TX`
- `CXSRESETn`, clock-enable / gate

Confirm the last legal deactivate:

1. `REQ` falls (RUN → DEACTIVATE).
2. Credits return to 0 at the receiver; no `CRDGNT` in flight.
3. `ACK` falls once (DEACTIVATE → STOP).
4. Until the next `REQ` rise, `ACK` stays 0.

If `ACK` rises in step 4, the DUT FSM is wrong. If `REQ` is still 1 in the DUT while the VIP shows STOP, the REQ/ACK pins are misconnected or on different clocks.

## DUT/HAL fix pattern

ACK may rise **only** from ACTIVATE (`REQ==1 && ACK==0`).  
ACK may fall **only** from DEACTIVATE (`REQ==0 && ACK==1`) after all credits are returned.

```systemverilog
// TX-channel ACK is driven by the RX of that channel (DUT/HAL).
always_ff @(posedge cxs_clk or negedge cxs_reset_n) begin
  if (!cxs_reset_n)
    cxs_active_ack_tx <= 1'b0;
  else if (cxs_active_req_tx && !cxs_active_ack_tx)
    cxs_active_ack_tx <= 1'b1;  // ACTIVATE -> RUN
  else if (!cxs_active_req_tx && cxs_active_ack_tx && all_credits_at_rx)
    cxs_active_ack_tx <= 1'b0;  // DEACTIVATE -> STOP
end
```

Do **not** implement `cxs_active_ack_tx <= cxs_active_req_tx` if credits can still be in flight: that drops ACK too early (other Denali credit checks) or, with extra delay, can re-enter ACK=1 after STOP.

Keep TX and RX handshakes independent: `CXS_ACTIVE_ACK_TX` must not follow `CXS_ACTIVE_REQ_RX` / `CXS_ACTIVE_ACK_RX`.

## VIP / TB notes (only if DUT waves are already legal)

- Active-agent monitor is checking the **DUT-driven** ACK. Masking ERR018 hides a spec fail.
- If the HAL is supposed to loop ACK combinationally for a stub, it still must not raise ACK in STOP; use the 4-phase slave above.
- Confirm VIP CAT CXS config `CXSLINKCONTROL` is `Explicit_Credit_Return` to match the DUT (REQ/ACK/CRDRTN present).
- Shared vs gated `CXSCLK` in STOP: ACK flop must remain reset-clear / enabled so it cannot come back as 1 while REQ is 0.

## Suggested sim debug commands

```
# After reproduce, dump around the UVM time
# (tool-specific; Cadence SimVision / Verdi)
# marker: uvm_test_top.sve.m_hls_ib_nonposted_hal_env.cxs_env.act_agent.monitor
```

Search DUT/HAL for drivers of `active_ack_tx` / `cxsactiveack` / `CXSACTIVEACK` and inspect the cycle **after** ACK first goes low following a REQ fall.
