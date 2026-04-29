
"""
send_ticks.py - send tick frames to the FPGA's multi-ticker trader.

At startup, listens for one STATS frame to learn the current thresholds
(so its "expected action" hints reflect any CONFIG changes that have
happened). Falls back to v2 defaults if no STATS frame is received within
~1.5 seconds.

Usage:
    sudo python3 send_ticks.py <iface> <ticker> <price1_cents> [price2 ...]
    sudo python3 send_ticks.py <iface> mixed                         # demo mode

Examples:
    sudo python3 send_ticks.py enp4s0 QCOM 15000 15800 16100 14900
    sudo python3 send_ticks.py enp4s0 mixed

The FPGA recognizes 4 tickers, each with its own buy-below / sell-above
pair. Defaults shown below; current values printed at startup:

    QCOM   buy <$155.00   sell >$160.00
    TSLA   buy <$400.00   sell >$450.00
    GME    buy <$20.00    sell >$30.00
    NVDA   buy <$130.00   sell >$150.00
"""

import socket
import struct
import sys
import time
import select

ETHER_TYPE_TICK  = 0x88B6
ETHER_TYPE_STATS = 0x88B9
MAGIC            = bytes.fromhex('CAFEBABE')
DST_MAC          = b'\xff' * 6

TICKERS = {
    'QCOM': {'wire': b'QCOM'},
    'TSLA': {'wire': b'TSLA'},
    'GME':  {'wire': b'GME '},
    'NVDA': {'wire': b'NVDA'},
}
TICKER_ORDER = ['QCOM', 'TSLA', 'GME', 'NVDA']

DEFAULT_THRESHOLDS = {
    'QCOM': (15500, 16000),
    'TSLA': (40000, 45000),
    'GME':  ( 2000,  3000),
    'NVDA': (13000, 15000),
}

def get_iface_mac(iface):
    with open(f'/sys/class/net/{iface}/address') as f:
        return bytes.fromhex(f.read().strip().replace(':', ''))

def make_tick_frame(src_mac, ticker_wire, price_cents):
    eth_hdr = DST_MAC + src_mac + ETHER_TYPE_TICK.to_bytes(2, 'big')
    payload = MAGIC + ticker_wire + price_cents.to_bytes(4, 'big')
    body = eth_hdr + payload
    pad_len = 60 - len(body)
    if pad_len > 0:
        body += b'\x00' * pad_len
    return body

def learn_thresholds(iface, timeout_s=1.5):
    """Listen for one STATS frame; extract current thresholds.

    Returns a dict of {ticker_name: (buy_thr_cents, sell_thr_cents)}
    or DEFAULT_THRESHOLDS if no STATS frame arrives in time.
    """
    sock = socket.socket(socket.AF_PACKET, socket.SOCK_RAW,
                         socket.htons(ETHER_TYPE_STATS))
    sock.bind((iface, 0))
    sock.settimeout(0.1)

    deadline = time.time() + timeout_s
    while time.time() < deadline:
        try:
            r, _, _ = select.select([sock], [], [], 0.2)
            if not r:
                continue
            payload = sock.recv(2048)
            if len(payload) >= 206 \
               and payload[12:14] == bytes.fromhex('88B9') \
               and payload[14:18] == b'STAT':
                thr = {}
                # threshold pairs at payload offset 174 (= frame offset 182
                # minus 8-byte preamble+SFD that the kernel strips for us).
                # 4 x (uint32 buy, uint32 sell).
                for i, name in enumerate(TICKER_ORDER):
                    off = 174 + 8 * i
                    bt = int.from_bytes(payload[off  :off+4], 'big')
                    st = int.from_bytes(payload[off+4:off+8], 'big')
                    thr[name] = (bt, st)
                return thr
        except (socket.timeout, OSError):
            continue
    return None

def expected_action(ticker_name, price_cents, thresholds):
    bt, st = thresholds[ticker_name]
    if price_cents < bt:
        return 'BUY'
    if price_cents > st:
        return 'SELL'
    return f"hold (${bt/100:.2f} - ${st/100:.2f} band)"

def main():
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(1)

    iface = sys.argv[1]
    src_mac = get_iface_mac(iface)
    print(f"Interface: {iface}  src MAC = {src_mac.hex(':')}")

    print("Listening for one STATS frame to learn current thresholds...",
          end=' ', flush=True)
    thr = learn_thresholds(iface)
    if thr is None:
        print("timeout, using defaults.")
        thr = DEFAULT_THRESHOLDS
    else:
        print("got it.")
        for name in TICKER_ORDER:
            bt, st = thr[name]
            print(f"    {name:5s}  buy<${bt/100:>8.2f}  sell>${st/100:>8.2f}")

    sock = socket.socket(socket.AF_PACKET, socket.SOCK_RAW,
                         socket.htons(ETHER_TYPE_TICK))
    sock.bind((iface, 0))

    if sys.argv[2].lower() == 'mixed':
        sequence = [
            ('QCOM', 15000), ('QCOM', 15800), ('QCOM', 16100),
            ('TSLA', 39500), ('TSLA', 42500), ('TSLA', 45500),
            ('GME',   1850), ('GME',   2500), ('GME',   3200),
            ('NVDA', 12500), ('NVDA', 14000), ('NVDA', 15500),
        ]
    else:
        ticker_name = sys.argv[2].upper()
        if ticker_name not in TICKERS:
            print(f"unknown ticker {ticker_name!r}; "
                  f"choices: {list(TICKERS.keys())}")
            sys.exit(1)
        try:
            prices = [int(p) for p in sys.argv[3:]]
        except ValueError:
            print("prices must be integer cents (e.g. 15842 for $158.42)")
            sys.exit(1)
        if not prices:
            print("at least one price required")
            sys.exit(1)
        sequence = [(ticker_name, p) for p in prices]

    print()
    for i, (ticker_name, price) in enumerate(sequence):
        wire = TICKERS[ticker_name]['wire']
        frame = make_tick_frame(src_mac, wire, price)
        sock.send(frame)
        action = expected_action(ticker_name, price, thr)
        print(f"  [{i:2d}] {ticker_name:5s} @ ${price/100:>9.2f}   "
              f"expect: {action}")
        time.sleep(0.2)

    print("done.")

if __name__ == '__main__':
    main()
