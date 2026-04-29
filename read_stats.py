
"""
read_stats.py - listen for and decode the FPGA's stats frames.

The FPGA emits a STATS frame (EtherType 0x88B9) every 1 second and also
immediately after accepting a CONFIG frame.

Usage:
    sudo python3 read_stats.py <iface>

Press Ctrl-C to stop.

Frame layout (218 bytes total, kernel strips the 4-byte FCS):
    [00:06]  dst MAC
    [06:12]  src MAC
    [12:14]  ethertype 0x88B9
    [14:18]  magic 'STAT'
    [18:22]  total_buy_orders          uint32 BE
    [22:26]  total_sell_orders         uint32 BE
    [26:30]  dropped_busy              uint32 BE
    [30:34]  last_buy_latency_cycles   uint32 BE  (1 cyc = 8 ns)
    [34:38]  last_sell_latency_cycles  uint32 BE
    [38:46]  position[QCOM,TSLA,GME,NVDA]  4 x int16 BE
    [46:62]  refused_pos[0..3]         4 x uint32 BE
    [62:78]  volume_buys[0..3]         4 x uint32 BE
    [78:94]  volume_sells[0..3]        4 x uint32 BE
    [94:126] cost_buys[0..3]           4 x uint64 BE
    [126:158] proceeds_sells[0..3]     4 x uint64 BE
    [158:174] last_price[0..3]         4 x uint32 BE
    [174:206] (buy_thr, sell_thr)[0..3] 4 x (u32+u32) BE
"""

import socket
import struct
import sys
import time

ETHER_TYPE_STATS = 0x88B9
TICKERS = ['QCOM', 'TSLA', 'GME', 'NVDA']

# offsets below are post-preamble (kernel strips the 8-byte preamble+SFD
# before AF_PACKET hands us the frame). offset 0 = first dst MAC byte.
def parse_stats(payload):
    if len(payload) < 206:
        return None
    if payload[12:14] != bytes.fromhex('88B9'):
        return None
    if payload[14:18] != b'STAT':
        return None

    s = {}
    s['total_buy']        = int.from_bytes(payload[18:22], 'big')
    s['total_sell']       = int.from_bytes(payload[22:26], 'big')
    s['dropped_busy']     = int.from_bytes(payload[26:30], 'big')
    s['last_buy_cycles']  = int.from_bytes(payload[30:34], 'big')
    s['last_sell_cycles'] = int.from_bytes(payload[34:38], 'big')

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

    for i, name in enumerate(TICKERS):
        s['refused'][name] = int.from_bytes(
            payload[46 + 4*i : 50 + 4*i], 'big')

    for i, name in enumerate(TICKERS):
        s['vol_buys'][name] = int.from_bytes(
            payload[62 + 4*i : 66 + 4*i], 'big')
        s['vol_sells'][name] = int.from_bytes(
            payload[78 + 4*i : 82 + 4*i], 'big')

    for i, name in enumerate(TICKERS):
        s['cost_buys'][name] = int.from_bytes(
            payload[94 + 8*i : 102 + 8*i], 'big')
        s['proceeds_sells'][name] = int.from_bytes(
            payload[126 + 8*i : 134 + 8*i], 'big')

    for i, name in enumerate(TICKERS):
        s['last_price'][name] = int.from_bytes(
            payload[158 + 4*i : 162 + 4*i], 'big')

    for i, name in enumerate(TICKERS):
        off = 174 + 8 * i
        s['buy_thr' ][name] = int.from_bytes(payload[off  :off+4], 'big')
        s['sell_thr'][name] = int.from_bytes(payload[off+4:off+8], 'big')

    return s

def render(s, last):
    def chg(cur, old, fmt='{}', cents=False):
        if cents:
            text = f"${cur/100:>10.2f}"
        else:
            text = fmt.format(cur)
        if old is not None and old != cur:
            return f"\033[1m{text}\033[0m"
        return text

    print('=' * 78)
    last_buy_ns  = s['last_buy_cycles']  * 8
    last_sell_ns = s['last_sell_cycles'] * 8

    print("Counters")
    print(f"  total buys = {chg(s['total_buy'], last and last['total_buy']):>10}"
          f"   total sells = {chg(s['total_sell'], last and last['total_sell']):>10}"
          f"   dropped(busy) = {chg(s['dropped_busy'], last and last['dropped_busy']):>10}")
    print(f"\nLatency (cycle = 8 ns)")
    print(f"  last buy  = {chg(s['last_buy_cycles'],  last and last['last_buy_cycles' ]):>5} cyc "
          f"({last_buy_ns:>5} ns)")
    print(f"  last sell = {chg(s['last_sell_cycles'], last and last['last_sell_cycles']):>5} cyc "
          f"({last_sell_ns:>5} ns)")

    print(f"\nPer-ticker state")
    print(f"  {'sym':<5} {'pos':>5} {'vol_buy':>8} {'vol_sell':>9}"
          f"  {'last_px':>10}  {'buy_thr':>10}  {'sell_thr':>10}  {'refused':>7}")
    for name in TICKERS:
        old_pos  = (last or {}).get('positions', {}).get(name)
        old_vb   = (last or {}).get('vol_buys', {}).get(name)
        old_vs   = (last or {}).get('vol_sells', {}).get(name)
        old_lp   = (last or {}).get('last_price', {}).get(name)
        old_bt   = (last or {}).get('buy_thr', {}).get(name)
        old_st   = (last or {}).get('sell_thr', {}).get(name)
        old_rf   = (last or {}).get('refused', {}).get(name)
        print(f"  {name:<5} "
              f"{chg(s['positions'][name], old_pos):>5} "
              f"{chg(s['vol_buys'][name], old_vb):>8} "
              f"{chg(s['vol_sells'][name], old_vs):>9}  "
              f"{chg(s['last_price'][name], old_lp, cents=True)}  "
              f"{chg(s['buy_thr'][name], old_bt, cents=True)}  "
              f"{chg(s['sell_thr'][name], old_st, cents=True)}  "
              f"{chg(s['refused'][name], old_rf):>7}")

    print(f"\nP&L (in cents and dollars)")
    print(f"  {'sym':<5}  {'realized $':>12}  {'mark-to-mkt $':>15}  {'total $':>12}")
    grand_realized = 0
    grand_mtm      = 0
    inventory_signed_units = 0
    inventory_abs_units    = 0
    for name in TICKERS:
        realized = s['proceeds_sells'][name] - s['cost_buys'][name]
        pos      = s['positions'][name]
        lp       = s['last_price'][name]
        mtm      = pos * lp
        total    = realized + mtm

        grand_realized += realized
        grand_mtm      += mtm
        inventory_signed_units += pos
        inventory_abs_units    += abs(pos)

        print(f"  {name:<5}  ${realized/100:>12,.2f}  ${mtm/100:>15,.2f}  ${total/100:>12,.2f}")

    grand_total = grand_realized + grand_mtm
    print(f"  {'-'*5}  {'-'*12}  {'-'*15}  {'-'*12}")
    print(f"  {'TOTAL':<5}  ${grand_realized/100:>12,.2f}  ${grand_mtm/100:>15,.2f}"
          f"  ${grand_total/100:>12,.2f}")

    print(f"\nInventory")
    print(f"  signed sum:    {inventory_signed_units:>4} units (longs - shorts; "
          "useful for net delta)")
    print(f"  absolute sum:  {inventory_abs_units:>4} units (total stock held; "
          "real exposure)")
    print()

def main():
    if len(sys.argv) != 2:
        print(__doc__)
        sys.exit(1)
    iface = sys.argv[1]

    sock = socket.socket(socket.AF_PACKET, socket.SOCK_RAW,
                         socket.htons(ETHER_TYPE_STATS))
    sock.bind((iface, 0))

    print(f"Listening for STATS frames on {iface} (Ctrl-C to stop)")
    last = None
    try:
        while True:
            payload = sock.recv(2048)
            s = parse_stats(payload)
            if s is None:
                continue
            print(f"\n[{time.strftime('%H:%M:%S')}]")
            render(s, last)
            last = s
    except KeyboardInterrupt:
        print("\ndone.")

if __name__ == '__main__':
    main()
