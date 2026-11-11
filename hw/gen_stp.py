# Gera o arquivo Signal Tap (nios_eth.stp) com os sinais relevantes do MAC
# Ethernet e do USER HW.  Uso:  python gen_stp.py
E = "soc:u_soc|eth_rgmii_mac:eth_mac|"
U = "soc:u_soc|user_hw:user_hw|"

# (nome, largura) - largura 0 = sinal de 1 bit
SIGNALS = [
    # --- chegada de pacote (RX) ---
    (E + "rgmii_rx_ctl", 0),
    (E + "rx_dv", 0),
    (E + "rx_nib", 4),
    (E + "rx_state", 2),
    (E + "rx_sof", 0),          # SFD detectado = inicio de um quadro
    (E + "rx_byte", 8),
    (E + "rx_cnt_b", 12),
    (E + "rx_is_uc", 0),
    (E + "rx_is_bc", 0),
    (E + "rx_commit", 0),       # quadro aceito e entregue ao Nios
    (E + "irq", 0),
    (E + "rx_pop_p", 0),        # Nios liberou o buffer
    # --- transmissao de pacote (TX) ---
    (E + "tx_start_p", 0),      # Nios disparou a transmissao
    (E + "tx_state", 3),
    (E + "tx_en", 0),           # = RGMII TX_CTL
    (E + "rgmii_txd", 4),
    (E + "tx_done_p", 0),
    # --- USER HW ---
    (U + "start_p", 0),
    (U + "busy", 0),
    (U + "done", 0),
    (U + "idx", 8),
    (U + "cur_in", 8),
    (U + "cur_out", 8),
]
CLOCK = E + "clk"
DEPTH = 1024
TRIGGER = E + "rx_sof"          # condicao padrao: chegada de um quadro

def expand():
    bits = []
    for name, w in SIGNALS:
        if w == 0:
            bits.append(name)
        else:
            bits += ["%s[%d]" % (name, i) for i in range(w)]
    return bits

bits = expand()
idx = {b: i for i, b in enumerate(bits)}

def node(tag, b, level="dont_care"):
    i = idx[b]
    return ('<%s data_index="%d" duplicate_name_allowed="false" is_data_input="true" '
            'is_node_valid="true" is_selected="false" is_storage_input="true" '
            'is_trigger_input="true" level-0="%s" name="%s" pwr_level-0="dont_care" '
            'storage-0="dont_care" storage_index="%d" tap_mode="classic" '
            'trigger_index="%d" type="unknown"/>' % (tag, i, level, b, i, i))

def view(container, leaf):
    out = []
    for name, w in SIGNALS:
        if w == 0:
            lvl = "high" if name == TRIGGER else "dont_care"
            out.append("          " + node(leaf, name, lvl))
        else:
            out.append('          <%s is_selected="false" level-0="alt_or" name="%s[%d..0]" '
                       'order="msb_to_lsb" state="collapse" storage-0="alt_or" type="unknown">'
                       % (container, name, w - 1))
            for i in reversed(range(w)):
                out.append("            " + node(leaf, "%s[%d]" % (name, i)))
            out.append("          </%s>" % container)
    return "\n".join(out)

wires = "\n".join('          <wire name="%s" tap_mode="classic"/>' % b for b in bits)
ones = "1" * len(bits)

stp = f'''<session jtag_chain="Cyclone 10 LP Evaluation Kit [USB-1]" jtag_device="@1: 10CL025(Y|Z)/EP3C25/EP4CE22 (0x020F30DD)" sof_file="output_files/nios_eth.sof">
  <display_tree gui_logging_enabled="0">
    <display_branch instance="auto_signaltap_0" log="USE_GLOBAL_TEMP" signal_set="USE_GLOBAL_TEMP" trigger="USE_GLOBAL_TEMP"/>
  </display_tree>
  <instance enabled="true" entity_name="sld_signaltap" is_auto_node="yes" is_expanded="true" name="auto_signaltap_0" source_file="sld_signaltap.vhd">
    <node_ip_info instance_id="0" mfg_id="110" node_id="0" version="6"/>
    <signal_set global_temp="1" is_expanded="true" name="signal_set: ethernet_userhw">
      <clock name="{CLOCK}" polarity="posedge" tap_mode="classic"/>
      <config pipeline_level="0" ram_type="AUTO" reserved_data_nodes="0" reserved_storage_qualifier_nodes="0" reserved_trigger_nodes="0" sample_depth="{DEPTH}" trigger_in_enable="no" trigger_out_enable="no"/>
      <top_entity/>
      <signal_vec>
        <trigger_input_vec>
{wires}
        </trigger_input_vec>
        <data_input_vec>
{wires}
        </data_input_vec>
        <storage_qualifier_input_vec>
{wires}
        </storage_qualifier_input_vec>
      </signal_vec>
      <presentation>
        <unified_setup_data_view>
{view("node", "node")}
        </unified_setup_data_view>
        <data_view>
{view("bus", "net")}
        </data_view>
        <setup_view>
{view("bus", "net")}
        </setup_view>
        <trigger_in_editor/>
        <trigger_out_editor/>
      </presentation>
      <trigger attribute_mem_mode="false" gap_record="true" global_temp="1" is_expanded="true" name="trigger: chegada_de_quadro" position="pre" power_up_trigger_mode="false" record_data_gap="true" segment_size="1" storage_mode="off" storage_qualifier_disabled="no" storage_qualifier_port_is_pin="false" storage_qualifier_port_name="auto_stp_external_storage_qualifier" storage_qualifier_port_tap_mode="classic" trigger_type="circular">
        <power_up_trigger position="pre" storage_qualifier_disabled="no"/>
        <events use_custom_flow_control="no">
          <level enabled="yes" name="condition1" type="basic">'{TRIGGER}' == high
            <power_up enabled="yes">
            </power_up><op_node/>
          </level>
        </events>
        <storage_qualifier_events>
          <transitional>{ones}
            <pwr_up_transitional>{ones}</pwr_up_transitional>
          </transitional>
          <storage_qualifier_level type="basic">
            <power_up>
            </power_up>
            <op_node/>
          </storage_qualifier_level>
        </storage_qualifier_events>
      </trigger>
    </signal_set>
    <position_info>
      <single attribute="active tab" value="0"/>
      <single attribute="data horizontal scroll position" value="0"/>
      <single attribute="data vertical scroll position" value="0"/>
      <single attribute="setup horizontal scroll position" value="0"/>
      <single attribute="setup vertical scroll position" value="0"/>
      <single attribute="zoom level denominator" value="1"/>
      <single attribute="zoom level numerator" value="1"/>
      <single attribute="zoom offset denominator" value="1"/>
      <single attribute="zoom offset numerator" value="0"/>
    </position_info>
  </instance>
  <mnemonics/>
  <static_plugin_mnemonics/>
  <global_info>
    <single attribute="active instance" value="0"/>
    <single attribute="config widget visible" value="1"/>
    <single attribute="data log widget visible" value="1"/>
    <single attribute="hierarchy widget visible" value="1"/>
    <single attribute="instance widget visible" value="1"/>
    <single attribute="jtag widget visible" value="1"/>
    <single attribute="lock mode" value="0"/>
  </global_info>
</session>
'''
with open("nios_eth.stp", "w", newline="\n") as f:
    f.write(stp)
print("nios_eth.stp: %d bits, depth %d" % (len(bits), DEPTH))
