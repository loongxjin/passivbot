import math
from typing import Iterator, Tuple

from config.access import require_config_value, require_live_value


def _to_float(value) -> float:
    try:
        return float(value)
    except (TypeError, ValueError):
        return 0.0


def _require_max_warmup_minutes(config: dict) -> float:
    return _to_float(require_live_value(config, "max_warmup_minutes"))


def _iter_param_sets(config: dict) -> Iterator[Tuple[str, dict, dict]]:
    bot_cfg = config.get("bot", {})
    base_long = dict(bot_cfg.get("long", {}) or {})
    base_short = dict(bot_cfg.get("short", {}) or {})
    yield "__default__", base_long, base_short

    coin_overrides = config.get("coin_overrides", {})
    for coin, overrides in coin_overrides.items():
        bot_overrides = overrides.get("bot", {})
        long_params = dict(base_long)
        short_params = dict(base_short)
        long_params.update(bot_overrides.get("long", {}) or {})
        short_params.update(bot_overrides.get("short", {}) or {})
        yield coin, long_params, short_params


def _extract_bound_max(bounds: dict, key: str) -> float:
    """Extract the maximum value from an optimize bound entry."""
    if not isinstance(bounds, dict) or key not in bounds:
        return 0.0
    entry = bounds[key]
    candidates = [entry] if isinstance(entry, (list, tuple)) else [[entry]]
    max_val = 0.0
    for candidate in candidates:
        for val in candidate:
            max_val = max(max_val, _to_float(val))
    return max_val


def _side_may_be_enabled(config: dict, pside: str) -> bool:
    """Check whether the given pside is or could be enabled.

    Considers both the base bot config and optimize bounds upper limits.
    A side is "enabled" when TWEL > 0 and n_positions > 0.
    """
    bot_cfg = config.get("bot", {}).get(pside, {})
    bounds = config.get("optimize", {}).get("bounds", {})

    twel_base = _to_float(bot_cfg.get("total_wallet_exposure_limit", 0))
    npos_base = int(round(_to_float(bot_cfg.get("n_positions", 0))))

    twel_bound = _extract_bound_max(bounds, f"{pside}_total_wallet_exposure_limit")
    npos_bound = _extract_bound_max(bounds, f"{pside}_n_positions")

    twel = max(twel_base, twel_bound)
    npos = max(npos_base, int(round(npos_bound)))
    return twel > 0.0 and npos > 0


def compute_backtest_warmup_minutes(config: dict) -> int:
    """Mirror Rust warmup span calculation (see calc_warmup_bars)."""

    max_minutes = 0.0
    minute_fields = [
        "ema_span_0",
        "ema_span_1",
        "forager_volume_ema_span",
        "forager_volatility_ema_span",
    ]

    for _, long_params, short_params in _iter_param_sets(config):
        for params in (long_params, short_params):
            for field in minute_fields:
                max_minutes = max(max_minutes, _to_float(params.get(field)))
            log_span_minutes = _to_float(params.get("entry_volatility_ema_span_hours")) * 60.0
            max_minutes = max(max_minutes, log_span_minutes)

    bounds = config.get("optimize", {}).get("bounds", {})
    # Only consider optimize bounds for sides that are actually enabled.
    # Bounds for disabled sides may hold large placeholder values that would
    # inflate the warmup beyond the available data window.
    enabled_sides = [pside for pside in ("long", "short") if _side_may_be_enabled(config, pside)]
    bound_keys_minutes = []
    bound_keys_hours = []
    for pside in enabled_sides:
        for field in minute_fields:
            bound_keys_minutes.append(f"{pside}_{field}")
        bound_keys_hours.append(f"{pside}_entry_volatility_ema_span_hours")

    for key in bound_keys_minutes:
        max_minutes = max(max_minutes, _extract_bound_max(bounds, key))
    for key in bound_keys_hours:
        max_minutes = max(max_minutes, _extract_bound_max(bounds, key) * 60.0)

    warmup_ratio = float(require_config_value(config, "live.warmup_ratio"))
    limit = _require_max_warmup_minutes(config)

    if not math.isfinite(max_minutes):
        return 0
    warmup_minutes = max_minutes * max(0.0, warmup_ratio)
    if limit > 0:
        warmup_minutes = min(warmup_minutes, limit)
    return int(math.ceil(warmup_minutes)) if warmup_minutes > 0.0 else 0


def compute_per_coin_warmup_minutes(config: dict) -> dict:
    warmup_ratio = float(require_config_value(config, "live.warmup_ratio"))
    limit = _require_max_warmup_minutes(config)
    per_coin = {}
    minute_fields = [
        "ema_span_0",
        "ema_span_1",
        "forager_volume_ema_span",
        "forager_volatility_ema_span",
    ]
    for coin, long_params, short_params in _iter_param_sets(config):
        max_minutes = 0.0
        for params in (long_params, short_params):
            for field in minute_fields:
                max_minutes = max(max_minutes, _to_float(params.get(field)))
            max_minutes = max(
                max_minutes,
                _to_float(params.get("entry_volatility_ema_span_hours")) * 60.0,
            )
        if not math.isfinite(max_minutes):
            per_coin[coin] = 0
            continue
        warmup_minutes = max_minutes * max(0.0, warmup_ratio)
        if limit > 0:
            warmup_minutes = min(warmup_minutes, limit)
        per_coin[coin] = int(math.ceil(warmup_minutes)) if warmup_minutes > 0.0 else 0
    return per_coin


__all__ = [
    "compute_backtest_warmup_minutes",
    "compute_per_coin_warmup_minutes",
]
