"""Payout optimizer — LLM for interviews, OR-tools for the CSP.

Members state when they *would prefer* to receive the pot (month index 1..N).
We solve the assignment so each member gets a unique month and the sum of
|assigned - preferred| is minimized (members without a preference are free).
"""
from __future__ import annotations

from dataclasses import dataclass


@dataclass
class MemberPreference:
    user_id: str
    preferred_month: int | None  # 1..N or None for flexible
    urgency: int = 1              # higher weight => stronger preference


@dataclass
class PayoutAssignment:
    user_id: str
    assigned_month: int


def solve_payout_order(
    prefs: list[MemberPreference], *, n_cycles: int
) -> list[PayoutAssignment]:
    """OR-tools CP-SAT: assign each member to a unique 1..N slot, minimizing
    weighted |assigned - preferred| for members that expressed a preference."""
    from ortools.sat.python import cp_model

    if len(prefs) != n_cycles:
        raise ValueError(
            f"payout slots ({n_cycles}) must equal member count ({len(prefs)})"
        )

    model = cp_model.CpModel()
    assign = {
        p.user_id: model.NewIntVar(1, n_cycles, f"m_{p.user_id[:6]}") for p in prefs
    }
    model.AddAllDifferent(list(assign.values()))

    # Minimize weighted deviation for members with a stated preference.
    deviations = []
    for p in prefs:
        if p.preferred_month is None:
            continue
        dev = model.NewIntVar(0, n_cycles, f"dev_{p.user_id[:6]}")
        diff = model.NewIntVar(-n_cycles, n_cycles, f"diff_{p.user_id[:6]}")
        model.Add(diff == assign[p.user_id] - p.preferred_month)
        model.AddAbsEquality(dev, diff)
        deviations.append(dev * max(1, p.urgency))
    if deviations:
        model.Minimize(sum(deviations))

    solver = cp_model.CpSolver()
    solver.parameters.max_time_in_seconds = 3.0
    status = solver.Solve(model)
    if status not in (cp_model.OPTIMAL, cp_model.FEASIBLE):
        raise RuntimeError("no feasible payout assignment")

    return [
        PayoutAssignment(user_id=p.user_id, assigned_month=int(solver.Value(assign[p.user_id])))
        for p in prefs
    ]
