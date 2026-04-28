
set_property CFGBVS VCCO        [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]

create_clock -period 20.000 -name sys_clk [get_ports sys_clk]
set_property PACKAGE_PIN R4      [get_ports sys_clk]
set_property IOSTANDARD LVCMOS33 [get_ports sys_clk]

set_property PACKAGE_PIN V9      [get_ports {led[0]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led[0]}]
set_property PACKAGE_PIN Y8      [get_ports {led[1]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led[1]}]
set_property PACKAGE_PIN Y7      [get_ports {led[2]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led[2]}]
set_property PACKAGE_PIN W7      [get_ports {led[3]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led[3]}]

set_property PACKAGE_PIN N20     [get_ports eth_rst_n]
set_property IOSTANDARD LVCMOS33 [get_ports eth_rst_n]

set_property PACKAGE_PIN M20     [get_ports eth_mdc]
set_property IOSTANDARD LVCMOS33 [get_ports eth_mdc]

set_property PACKAGE_PIN N22     [get_ports eth_mdio]
set_property IOSTANDARD LVCMOS33 [get_ports eth_mdio]
set_property PULLUP    TRUE      [get_ports eth_mdio]

set_property PACKAGE_PIN U20     [get_ports eth_rgmii_rxc]
set_property IOSTANDARD LVCMOS33 [get_ports eth_rgmii_rxc]

set_property PACKAGE_PIN AA20    [get_ports eth_rgmii_rx_ctl]
set_property IOSTANDARD LVCMOS33 [get_ports eth_rgmii_rx_ctl]

set_property PACKAGE_PIN AA21    [get_ports {eth_rgmii_rxd[0]}]
set_property IOSTANDARD LVCMOS33 [get_ports {eth_rgmii_rxd[0]}]
set_property PACKAGE_PIN V20     [get_ports {eth_rgmii_rxd[1]}]
set_property IOSTANDARD LVCMOS33 [get_ports {eth_rgmii_rxd[1]}]
set_property PACKAGE_PIN U22     [get_ports {eth_rgmii_rxd[2]}]
set_property IOSTANDARD LVCMOS33 [get_ports {eth_rgmii_rxd[2]}]
set_property PACKAGE_PIN V22     [get_ports {eth_rgmii_rxd[3]}]
set_property IOSTANDARD LVCMOS33 [get_ports {eth_rgmii_rxd[3]}]

set_property PACKAGE_PIN V18     [get_ports eth_rgmii_txc]
set_property IOSTANDARD LVCMOS33 [get_ports eth_rgmii_txc]
set_property SLEW      FAST      [get_ports eth_rgmii_txc]

set_property PACKAGE_PIN V19     [get_ports eth_rgmii_tx_ctl]
set_property IOSTANDARD LVCMOS33 [get_ports eth_rgmii_tx_ctl]
set_property SLEW      FAST      [get_ports eth_rgmii_tx_ctl]

set_property PACKAGE_PIN T21     [get_ports {eth_rgmii_txd[0]}]
set_property IOSTANDARD LVCMOS33 [get_ports {eth_rgmii_txd[0]}]
set_property SLEW      FAST      [get_ports {eth_rgmii_txd[0]}]

set_property PACKAGE_PIN U21     [get_ports {eth_rgmii_txd[1]}]
set_property IOSTANDARD LVCMOS33 [get_ports {eth_rgmii_txd[1]}]
set_property SLEW      FAST      [get_ports {eth_rgmii_txd[1]}]

set_property PACKAGE_PIN P19     [get_ports {eth_rgmii_txd[2]}]
set_property IOSTANDARD LVCMOS33 [get_ports {eth_rgmii_txd[2]}]
set_property SLEW      FAST      [get_ports {eth_rgmii_txd[2]}]

set_property PACKAGE_PIN R19     [get_ports {eth_rgmii_txd[3]}]
set_property IOSTANDARD LVCMOS33 [get_ports {eth_rgmii_txd[3]}]
set_property SLEW      FAST      [get_ports {eth_rgmii_txd[3]}]

create_clock -period 8.000 -name eth_rgmii_rxc [get_ports eth_rgmii_rxc]
set_clock_groups -asynchronous \
    -group [get_clocks sys_clk] \
    -group [get_clocks eth_rgmii_rxc]
