#!/usr/bin/env python3
"""
send_config.py - send a CONFIG frame to update thresholds for one ticker.

Usage:
    sudo python3 send_config.py <iface> <ticker> <buy_below_cents> <sell_above_cents>

Example:
    # Update QCOM thresholds to BUY <$140, SELL >$170
    sudo python3 send_config.py enp4s0 QCOM 14000 17000

The FPGA accepts the new thresholds, immediately emits a STATS frame as
acknowledgment, and from then on uses the new thresholds for all incoming
QCOM ticks.

Frame format:
    Dst MAC      FF:FF:FF:FF:FF:FF (broadcast)
    Src MAC      this NIC's MAC
    EtherType    0x88B8
    Magic        43 4F 4E 46  ("CONF" ASCII)
    Ticker       4 ASCII bytes
    buy_below    uint32 BE, in cents
    sell_above   uint32 BE, in cents
    pad          to 60-byte body
    FCS          appended by kernel

Run alongside read_stats.py to see ACKs:
    sudo python3 read_stats.py enp4s0
"""

import socket
import sys

ETHER_TYPE_CONFIG = 0x88B8
MAGIC             = b'CONF'
DST_MAC           = b'\xff' * 6

TICKERS = {
    'QCOM': b'QCOM',
    'TSLA': b'TSLA',
    'GME':  b'GME ',   # space-padded
    'NVDA': b'NVDA',
}


def get_iface_mac(iface):
    with open(f'/sys/class/net/{iface}/address') as f:
        return bytes.fromhex(f.read().strip().replace(':', ''))


def main():
    if len(sys.argv) != 5:
        print(__doc__)
        sys.exit(1)
    iface = sys.argv[1]
    ticker_name = sys.argv[2].upper()
    if ticker_name not in TICKERS:
        print(f"unknown ticker {ticker_name!r}; choices: {list(TICKERS)}")
        sys.exit(1)
    try:
        buy_below  = int(sys.argv[3])
        sell_above = int(sys.argv[4])
    except ValueError:
        print("buy_below and sell_above must be integer cents")
        sys.exit(1)
    if buy_below >= sell_above:
        print(f"WARNING: buy_below (${buy_below/100:.2f}) >= "
              f"sell_above (${sell_above/100:.2f}) - the FPGA will accept "
              f"this but no price can ever fire BUY without ALSO firing SELL "
              f"on the next tick. You probably want buy_below < sell_above.")

    src_mac = get_iface_mac(iface)
    eth_hdr = DST_MAC + src_mac + ETHER_TYPE_CONFIG.to_bytes(2, 'big')
    payload = (MAGIC
               + TICKERS[ticker_name]
               + buy_below.to_bytes(4, 'big')
               + sell_above.to_bytes(4, 'big'))
    body = eth_hdr + payload
    pad_len = 60 - len(body)
    if pad_len > 0:
        body += b'\x00' * pad_len

    sock = socket.socket(socket.AF_PACKET, socket.SOCK_RAW,
                         socket.htons(ETHER_TYPE_CONFIG))
    sock.bind((iface, 0))
    sock.send(body)

    print(f"Sent CONFIG: {ticker_name}  "
          f"buy_below=${buy_below/100:.2f}  "
          f"sell_above=${sell_above/100:.2f}")
    print("Watch read_stats.py output - the FPGA should emit a STATS "
          "frame within a few ms with the updated thresholds.")


if __name__ == '__main__':
    main()
