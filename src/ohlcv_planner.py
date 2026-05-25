from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

from ohlcv_catalog import GapRecord, OhlcvCatalog
from ohlcv_legacy_import import LegacyRangeInspection, inspect_legacy_range


@dataclass(frozen=True)
class SymbolRangePlan:
    exchange: str
    timeframe: str
    symbol: str
    start_ts: int
    end_ts: int
    status: str
    bounds: tuple[int | None, int | None]
    legacy_inspection: LegacyRangeInspection | None
    persistent_gaps: tuple[GapRecord, ...]

    @property
    def local_store_complete(self) -> bool:
        return self.status == "store_complete"

    @property
    def should_try_legacy_import(self) -> bool:
        return self.status == "legacy_importable"

    @property
    def blocked_by_persistent_gap(self) -> bool:
        return self.status == "blocked_by_persistent_gap"

    @property
    def requires_remote_fetch(self) -> bool:
        return self.status == "missing_local"


def plan_local_symbol_range(
    *,
    catalog: OhlcvCatalog,
    legacy_root: str | Path | None,
    exchange: str,
    timeframe: str,
    symbol: str,
    start_ts: int,
    end_ts: int,
) -> SymbolRangePlan:
    if end_ts < start_ts:
        raise ValueError("end_ts must be >= start_ts")
    bounds = catalog.get_symbol_bounds(exchange, timeframe, symbol)
    store_complete = (
        bounds[0] is not None
        and bounds[1] is not None
        and int(bounds[0]) <= int(start_ts)
        and int(bounds[1]) >= int(end_ts)
    )
    # When end_ts is clamped to "now", the v2 store will always be a few
    # minutes/hours behind.  Treat the store as complete if the start is
    # fully covered and the end gap is within tolerance (1 day).  This
    # avoids a full legacy re-import when only a small incremental fetch
    # is needed.
    _ONE_DAY_MS = 86_400_000
    near_complete = False
    if not store_complete and bounds[0] is not None and bounds[1] is not None:
        start_ok = int(bounds[0]) <= int(start_ts)
        end_gap = int(end_ts) - int(bounds[1])
        if start_ok and 0 < end_gap <= _ONE_DAY_MS:
            near_complete = True
    persistent_gaps = tuple(
        catalog.get_persistent_gaps(exchange, timeframe, symbol, start_ts, end_ts)
    )
    # Only promote to store_complete if there are no persistent gaps that
    # need legacy import to fill.
    if near_complete and not persistent_gaps:
        store_complete = True
    legacy_inspection = None
    if (
        (not store_complete or persistent_gaps)
        and legacy_root is not None
        and Path(legacy_root).exists()
    ):
        legacy_inspection = inspect_legacy_range(
            legacy_root=legacy_root,
            exchange=exchange,
            timeframe=timeframe,
            symbol=symbol,
            start_ts=start_ts,
            end_ts=end_ts,
        )
    if persistent_gaps and not (
        legacy_inspection is not None and legacy_inspection.all_days_present
    ):
        status = "blocked_by_persistent_gap"
    elif legacy_inspection is not None and legacy_inspection.all_days_present:
        status = "legacy_importable"
    elif store_complete:
        status = "store_complete"
    else:
        status = "missing_local"
    return SymbolRangePlan(
        exchange=str(exchange),
        timeframe=str(timeframe),
        symbol=str(symbol),
        start_ts=int(start_ts),
        end_ts=int(end_ts),
        status=status,
        bounds=bounds,
        legacy_inspection=legacy_inspection,
        persistent_gaps=persistent_gaps,
    )
