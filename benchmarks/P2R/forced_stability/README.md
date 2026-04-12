# Forced Stability (P2R, Unrealizable)

## Specification

- **Initial**: trigger is true, bit0 is true
- **Safety guarantee**: once bit0 is set, it stays set (`bit0 -> X bit0`)
- **Fairness**: `(FG trigger) -> (GF !bit0)` — if trigger eventually stays on forever, the system must visit `!bit0` infinitely often

## Why it is unrealizable

The safety constraint is a latch: once `bit0` becomes true (which it is initially), it must remain true forever. Therefore `!bit0` can never be visited again, making `GF !bit0` impossible to satisfy. The system cannot fulfill the guarantee no matter what the environment does.

This is the P2R dual of the R2P `forced_oscillation` example, which is also unrealizable due to a contradiction between safety and fairness constraints.
