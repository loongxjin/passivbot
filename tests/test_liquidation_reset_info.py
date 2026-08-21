"""Tests for liquidation reset annotation info (held coins at liquidation)."""

import os
from pathlib import Path
from types import SimpleNamespace

os.environ.setdefault("MPLBACKEND", "Agg")

import numpy as np
import pandas as pd
import pytest

import backtest as bt
from backtest import (
    BacktestPayload,
    BacktestPlotContext,
    compute_liquidation_info,
    execute_backtest,
)
from plotting import create_forager_balance_figures, format_liquidation_positions

try:
    import passivbot_rust as pbr
except Exception:  # pragma: no cover - exercised when the extension is unavailable
    pbr = None

pbr_is_stub = bool(getattr(pbr, "__is_stub__", False)) if pbr is not None else False


MINUTE_MS = 60_000


def _bal_eq(timestamps_ms, balances):
    return pd.DataFrame(
        {"usd_total_balance": balances},
        index=pd.to_datetime(pd.Index(timestamps_ms, dtype=np.int64), unit="ms"),
    )


def test_compute_liquidation_info_attaches_held_coins():
    # NaN marker at 120_001 ms, restored balance at 120_002 ms
    equities = np.array(
        [
            [0.0, 1000.0],
            [60_000.0, 1200.0],
            [120_001.0, np.nan],
            [120_002.0, 1000.0],
            [180_000.0, 1010.0],
        ]
    )
    bal_eq = _bal_eq([0, 60_000, 120_001, 120_002, 180_000], [1000.0, 1200.0, 1200.0, 1000.0, 1010.0])
    events = [
        {
            "timestamp_ms": 120_001,
            "positions": [
                {"coin": "ETH", "pside": "short", "size": 2.0, "price": 50.0},
                {"coin": "BTC", "pside": "long", "size": 0.5, "price": 100.0},
            ],
        }
    ]

    info = compute_liquidation_info(equities, bal_eq, events)

    assert info is not None and len(info) == 1
    ts, peak, coins = info[0]
    assert int(ts.value // 1_000_000) == 120_001
    assert peak == pytest.approx(1200.0)
    assert coins == [
        ("BTC", "long", pytest.approx(0.5), pytest.approx(100.0)),
        ("ETH", "short", pytest.approx(2.0), pytest.approx(50.0)),
    ]


def test_compute_liquidation_info_merges_same_day_and_unions_coins():
    # Two liquidations on the same calendar day
    equities = np.array(
        [
            [0.0, 1000.0],
            [60_000.0, 1300.0],
            [120_001.0, np.nan],
            [120_002.0, 1000.0],
            [240_001.0, np.nan],
            [240_002.0, 1000.0],
        ]
    )
    bal_eq = _bal_eq(
        [0, 60_000, 120_001, 120_002, 240_001, 240_002],
        [1000.0, 1300.0, 1300.0, 1000.0, 1100.0, 1000.0],
    )
    events = [
        {
            "timestamp_ms": 120_001,
            "positions": [{"coin": "BTC", "pside": "long", "size": 0.5, "price": 100.0}],
        },
        {
            "timestamp_ms": 240_001,
            "positions": [
                {"coin": "BTC", "pside": "long", "size": 0.8, "price": 90.0},
                {"coin": "ETH", "pside": "long", "size": 1.0, "price": 20.0},
            ],
        },
    ]

    info = compute_liquidation_info(equities, bal_eq, events)

    assert info is not None and len(info) == 1
    ts, peak, coins = info[0]
    # last timestamp of the merged day, max peak across both lives
    assert int(ts.value // 1_000_000) == 240_001
    assert peak == pytest.approx(1300.0)
    # union per (coin, pside), keeping the max size seen
    assert [(c, p, s) for c, p, s, _ in coins] == [("BTC", "long", 0.8), ("ETH", "long", 1.0)]


def test_compute_liquidation_info_without_events_yields_empty_coins():
    equities = np.array(
        [
            [0.0, 1000.0],
            [60_001.0, np.nan],
            [60_002.0, 1000.0],
        ]
    )
    bal_eq = _bal_eq([0, 60_001, 60_002], [1000.0, 1000.0, 1000.0])

    info = compute_liquidation_info(equities, bal_eq, None)

    assert info is not None and len(info) == 1
    _, peak, coins = info[0]
    assert peak == pytest.approx(1000.0)
    assert coins == []


def test_compute_liquidation_info_returns_none_without_markers():
    equities = np.array([[0.0, 1000.0], [60_000.0, 1010.0]])
    bal_eq = _bal_eq([0, 60_000], [1000.0, 1010.0])

    assert compute_liquidation_info(equities, bal_eq, None) is None


def test_compute_liquidation_info_raises_on_malformed_event():
    equities = np.array(
        [
            [0.0, 1000.0],
            [60_001.0, np.nan],
        ]
    )
    bal_eq = _bal_eq([0, 60_001], [1000.0, 1000.0])

    with pytest.raises(ValueError, match="invalid liquidation event"):
        compute_liquidation_info(equities, bal_eq, [{"positions": []}])


def test_format_liquidation_positions():
    assert (
        format_liquidation_positions(
            [("BTC", "long", 1.0, 2.0), ("ETH", "short", 3.0, 4.0)]
        )
        == "BTC[L] ETH[S]"
    )
    assert format_liquidation_positions([]) == ""
    assert format_liquidation_positions(None) == ""


def test_balance_figure_annotation_includes_held_coins():
    times = pd.to_datetime([0, 60_001, 60_002, 120_000], unit="ms")
    bal_eq = pd.DataFrame(
        {
            "usd_cash_wallet": [1000.0, 1000.0, 1000.0, 1000.0],
            "usd_total_balance": [1000.0, 1000.0, 1000.0, 1000.0],
            "usd_total_equity": [1000.0, np.nan, 1000.0, 1000.0],
            "btc_cash_wallet": [0.0, 0.0, 0.0, 0.0],
            "btc_total_balance": [0.05, 0.05, 0.05, 0.05],
            "btc_total_equity": [0.05, np.nan, 0.05, 0.05],
        },
        index=times,
    )
    liq_ts = times[1]
    liquidation_info = [(liq_ts, 1000.0, [("BTC", "long", 0.5, 100.0), ("ETH", "short", 2.0, 50.0)])]

    figures = create_forager_balance_figures(
        bal_eq,
        include_logy=False,
        autoplot=False,
        return_figures=True,
        liquidation_info=liquidation_info,
    )

    assert "balance_and_equity" in figures
    fig = figures["balance_and_equity"]
    texts = [t.get_text() for t in fig.texts]
    assert any("Liq #1" in t and "pos: BTC[L] ETH[S]" in t for t in texts), texts


def test_execute_backtest_stashes_liquidation_events_from_six_tuple(monkeypatch):
    equities = np.array([[1767225600000, 1000.0]], dtype=np.float64)
    events = [
        {
            "timestamp_ms": 1767225600000,
            "positions": [{"coin": "BTC", "pside": "long", "size": 1.0, "price": 100.0}],
        }
    ]

    def fake_run_backtest_bundle(*_args):
        return np.empty((0, 19)), equities, {}, {}, {}, events

    monkeypatch.setattr(bt.pbr, "run_backtest_bundle", fake_run_backtest_bundle)
    monkeypatch.setattr(bt, "expand_analysis", lambda *args, **kwargs: {})
    bundle = SimpleNamespace(hlcvs=np.zeros((1, 1, 4)), timestamps=np.zeros(1))
    payload = BacktestPayload(
        bundle=bundle,
        bot_params_list=[],
        exchange_params=[],
        backtest_params={},
    )

    assert BacktestPlotContext.from_payload(payload).liquidation_events is None

    _fills, _equities, _analysis = execute_backtest(payload, {"backtest": {}})

    assert payload.liquidation_events == events
    assert BacktestPlotContext.from_payload(payload).liquidation_events == events


@pytest.mark.skipif(pbr is None or pbr_is_stub, reason="passivbot_rust extension not available")
def test_backtest_reset_records_liquidation_events_end_to_end():
    from backtest import build_backtest_payload
    from config_utils import load_config

    root = Path(__file__).resolve().parents[1]
    config = load_config(
        str(root / "configs" / "examples" / "default_trailing_grid_long_npos7.json"),
        verbose=False,
    )
    config["backtest"]["exchanges"] = ["binance"]
    config["backtest"]["coins"] = {"binance": ["BTC"]}
    config["backtest"]["candle_interval_minutes"] = 1
    config["backtest"]["filter_by_min_effective_cost"] = False
    config["backtest"]["start_date"] = "2021-01-01"
    config["backtest"]["end_date"] = "2021-01-02"
    config["backtest"]["allow_liquidation_reset"] = True
    config["backtest"]["liquidation_threshold"] = 0.05
    config["live"]["warmup_ratio"] = 0.0
    config["live"]["max_warmup_minutes"] = 0
    config["live"]["hedge_mode"] = False
    # shrink EMA spans so trading starts within the short synthetic series
    for side in ("long", "short"):
        config["bot"][side]["ema_span_0"] = 2.0
        config["bot"][side]["ema_span_1"] = 4.0
        config["bot"][side]["forager_volume_ema_span"] = 2.0
        config["bot"][side]["forager_volatility_ema_span"] = 2.0
        config["bot"][side]["entry_volatility_ema_span_hours"] = 1.0
        config["bot"][side]["hsl_ema_span_minutes"] = 10.0

    n_minutes = 600
    start_ts = 1609459200000  # 2021-01-01 00:00:00 UTC
    timestamps = np.arange(start_ts, start_ts + n_minutes * MINUTE_MS, MINUTE_MS, dtype=np.int64)
    hlcvs = np.zeros((n_minutes, 1, 4), dtype=np.float64)
    for i in range(n_minutes):
        if i < 60:
            price = 100.0  # flat warmup, allows initial entries
        else:
            # relentless crash to ~zero forces equity below liquidation floor
            price = max(100.0 * (0.97 ** (i - 59)), 0.01)
        hlcvs[i, 0, 0] = price * 1.001
        hlcvs[i, 0, 1] = price * 0.999
        hlcvs[i, 0, 2] = price
        hlcvs[i, 0, 3] = 1.0
    btc_usd_prices = np.full(n_minutes, 20_000.0, dtype=np.float64)
    mss = {
        "BTC": {
            "qty_step": 0.001,
            "price_step": 0.1,
            "min_qty": 0.0,
            "min_cost": 0.0,
            "c_mult": 1.0,
            "maker": 0.0002,
            "taker": 0.0005,
            "exchange": "binance",
        },
        "__meta__": {
            "requested_start_ts": int(timestamps[0]),
            "requested_start_date": "2021-01-01",
            "warmup_minutes_requested": 0,
            "warmup_minutes_provided": 0,
        },
    }

    payload = build_backtest_payload(
        hlcvs,
        mss,
        config,
        "binance",
        btc_usd_prices,
        timestamps,
    )
    _fills, equities_array, analysis = execute_backtest(payload, config)

    assert analysis["n_liquidations"] >= 1
    events = payload.liquidation_events
    assert events, "expected liquidation events to be recorded"
    assert len(events) == analysis["n_liquidations"]
    nan_ts = equities_array[np.isnan(equities_array[:, 1]), 0].astype(np.int64)
    assert [e["timestamp_ms"] for e in events] == nan_ts.tolist()
    for event in events:
        assert event["positions"], "held positions must be captured at liquidation"
        for pos in event["positions"]:
            assert pos["coin"] == "BTC"
            assert pos["pside"] in ("long", "short")
            assert pos["size"] > 0.0
