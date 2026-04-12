# Cleaning Robots (P2R, Realizable)

## Specification

This is the P2R adaptation of the R2R cleaning robots benchmark. The initial and safety constraints are identical; only the fairness pattern changes from GF to FG on the assumption side.

- **Parameters**: i = number of rooms (1..10)
- **Fairness**:
  - `(FG in:done & FG !in:clean_j) -> (GF out:clean_j)` — if the environment eventually always signals done and room j eventually always stays dirty, the system must keep cleaning room j infinitely often
  - `(FG in:done & FG in:clean_j) -> (GF !out:clean_j)` — if the environment eventually always signals done and room j eventually always stays clean, the system must eventually always not clean room j

## Why it is realizable

The P2R assumptions (FG) are strictly harder for the environment to satisfy than the R2R assumptions (GF). Since the R2R version is realizable, the P2R version is also realizable — the same system strategy works because the implication is vacuously true in more cases.
