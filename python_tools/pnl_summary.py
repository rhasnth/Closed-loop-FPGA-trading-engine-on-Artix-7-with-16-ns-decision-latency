#!/usr/bin/env python3
"""
pnl_summary.py - one-shot P&L summary, formatted for screenshots.

Captures one STATS frame from the FPGA and prints a clean,
bank-statement-style P&L report with totals, then exits. Designed
specifically to look good in a dissertation screenshot.

Usage:
    sudo python3 pnl_summary.py <iface>

If no STATS frame is received within ~2 seconds, exits with an error.
"""

import socket
import struct
import sys
import time
import select
from datetime import datetime

ETHER_TYPE_STATS = 0x88B9
TICKERS = ['QCOM', 'TSLA', 'GME', 'NVDA']


def parse_stats(payload):
    if len(payload) < 206 \
       or payload[12:14] != bytes.fromhex('88B9') \
       or payload[14:18] != b'STAT':
        return None
    s = {}
    s['total_buy']    = int.from_bytes(payload[18:22], 'big')
    s['total_sell']   = int.from_bytes(payload[22:26], 'big')
    s['dropped_busy'] = int.from_bytes(payload[26:30], 'big')
    s['lat_buy_ns']   = int.from_bytes(payload[30:34], 'big') * 8
    s['lat_sell_ns']  = int.from_bytes(payload[34:38], 'big') * 8
    s['positions']      = {}
    s['refused']        = {}
    s['vol_buys']       = {}
    s['vol_sells']      = {}
    s['cost_buys']      = {}
    s['proceeds_sells'] = {}
    s['last_price']     = {}
    s['buy_thr']        = {}
    s['sell_thr']       = {}
    for i, name in enumerate(TICKERS):
        s['positions'][name] = struct.unpack('>h',
            payload[38 + 2*i : 40 + 2*i])[0]
        s['refused'][name] = int.from_bytes(payload[46+4*i:50+4*i], 'big')
        s['vol_buys'][name]  = int.from_bytes(payload[62+4*i:66+4*i], 'big')
        s['vol_sells'][name] = int.from_bytes(payload[78+4*i:82+4*i], 'big')
        s['cost_buys'][name]      = int.from_bytes(payload[ 94+8*i:102+8*i], 'big')
        s['proceeds_sells'][name] = int.from_bytes(payload[126+8*i:134+8*i], 'big')
        s['last_price'][name] = int.from_bytes(payload[158+4*i:162+4*i], 'big')
        s['buy_thr'][name]    = int.from_bytes(payload[174+8*i:178+8*i], 'big')
        s['sell_thr'][name]   = int.from_bytes(payload[178+8*i:182+8*i], 'big')
    return s


def main():
    if len(sys.argv) != 2:
        print(__doc__)
        sys.exit(1)
    iface = sys.argv[1]

    sock = socket.socket(socket.AF_PACKET, socket.SOCK_RAW,
                         socket.htons(ETHER_TYPE_STATS))
    sock.bind((iface, 0))
    sock.settimeout(0.5)

    deadline = time.time() + 2.0
    s = None
    while time.time() < deadline:
        try:
            r, _, _ = select.select([sock], [], [], 0.5)
            if not r:
                continue
            payload = sock.recv(2048)
            s = parse_stats(payload)
            if s is not None:
                break
        except (socket.timeout, OSError):
            continue
    if s is None:
        print("no STATS frame received in 2 s - is the FPGA running?")
        sys.exit(1)

    # ----- pretty-print -----
    now = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
    line = '=' * 78
    sub  = '-' * 78

    print()
    print(line)
    print(f"  FPGA TRADING SIMULATOR - P&L SUMMARY".center(78))
    print(f"  generated {now}".center(78))
    print(line)
    print()

    print(f"  EXECUTION STATISTICS")
    print(sub)
    print(f"    total BUY orders executed       {s['total_buy']:>10}")
    print(f"    total SELL orders executed      {s['total_sell']:>10}")
    print(f"    orders dropped (TX busy)        {s['dropped_busy']:>10}")
    refused_total = sum(s['refused'].values())
    print(f"    orders refused (position limit) {refused_total:>10}")
    print(f"    last BUY  decision latency      {s['lat_buy_ns']:>7} ns")
    print(f"    last SELL decision latency      {s['lat_sell_ns']:>7} ns")
    print()

    print(f"  POSITIONS AND P&L PER TICKER")
    print(sub)
    print(f"    {'sym':<6}{'pos':>6}{'  buys  ':>10}{' sells  ':>10}"
          f"{'  last $':>11}{'  realized $':>14}{'  mtm $':>12}{'  total $':>12}")
    print(sub)

    grand_realized = 0
    grand_mtm      = 0
    inv_signed     = 0
    inv_abs        = 0
    for name in TICKERS:
        realized = s['proceeds_sells'][name] - s['cost_buys'][name]
        pos      = s['positions'][name]
        lp       = s['last_price'][name]
        mtm      = pos * lp
        total    = realized + mtm

        grand_realized += realized
        grand_mtm      += mtm
        inv_signed     += pos
        inv_abs        += abs(pos)

        print(f"    {name:<6}{pos:>6}{s['vol_buys'][name]:>10}"
              f"{s['vol_sells'][name]:>10}"
              f"  ${lp/100:>8.2f}"
              f"  ${realized/100:>11,.2f}"
              f"  ${mtm/100:>9,.2f}"
              f"  ${total/100:>9,.2f}")

    grand_total = grand_realized + grand_mtm
    print(sub)
    print(f"    {'TOTAL':<6}{inv_signed:>6}{sum(s['vol_buys'].values()):>10}"
          f"{sum(s['vol_sells'].values()):>10}"
          f"            "
          f"  ${grand_realized/100:>11,.2f}"
          f"  ${grand_mtm/100:>9,.2f}"
          f"  ${grand_total/100:>9,.2f}")
    print()

    print(f"  INVENTORY")
    print(sub)
    print(f"    net delta (longs - shorts)      {inv_signed:>4} units")
    print(f"    total stock held (|long|+|short|) {inv_abs:>4} units")
    print()

    print(f"  ACTIVE THRESHOLDS")
    print(sub)
    print(f"    {'ticker':<8}{'buy below':>13}{'sell above':>14}")
    for name in TICKERS:
        bt = s['buy_thr' ][name]
        st = s['sell_thr'][name]
        print(f"    {name:<8}  ${bt/100:>9.2f}  ${st/100:>9.2f}")
    print()

    print(line)
    pnl_color = "PROFIT" if grand_total > 0 else \
                "LOSS"   if grand_total < 0 else \
                "FLAT"
    print(f"  GRAND TOTAL P&L:  ${grand_total/100:>+12,.2f}   ({pnl_color})".center(78))
    print(line)
    print()


if __name__ == '__main__':
    main()
