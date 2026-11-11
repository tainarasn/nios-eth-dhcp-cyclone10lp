vlib work
vlog -quiet ../ip/eth_rgmii_mac/eth_rgmii_mac.v ../ip/user_hw/user_hw.v tb_eth.v
vsim -quiet -L altera_mf_ver -L altera_ver tb_eth
run -all
quit -f
